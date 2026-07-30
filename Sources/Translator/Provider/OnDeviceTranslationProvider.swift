import Foundation
import Synchronization
import Translation

@available(iOS 26.0, macOS 26.0, *)
struct OnDeviceTranslationDriver: Sendable {
    let translate: @Sendable ([TranslationRequest]) async throws -> [TranslationResult]
    let cancel: @Sendable () async -> Void
}

@available(iOS 26.0, macOS 26.0, *)
struct OnDeviceTranslationDriverFactory: Sendable {
    let makeDriver: @Sendable (
        _ sourceLanguage: TranslationLanguage,
        _ targetLanguage: TranslationLanguage
    ) -> OnDeviceTranslationDriver

    static let live = OnDeviceTranslationDriverFactory { sourceLanguage, targetLanguage in
        let owner = OnDeviceTranslationSessionOwner(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        return OnDeviceTranslationDriver(
            translate: { requests in
                try await owner.translate(requests)
            },
            cancel: {
                await owner.cancel()
            }
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
public struct OnDeviceTranslationProvider: TranslationProvider {
    let driverFactory: OnDeviceTranslationDriverFactory

    /// Creates a provider backed by Apple's on-device Translation framework.
    public init() {
        self.driverFactory = .live
    }

    init(driverFactory: OnDeviceTranslationDriverFactory) {
        self.driverFactory = driverFactory
    }

    public static func == (
        lhs: OnDeviceTranslationProvider,
        rhs: OnDeviceTranslationProvider
    ) -> Bool {
        true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(Self.self))
    }

    /// Translates a batch using language assets already installed on the device.
    public func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        try Task.checkCancellation()
        guard !requests.contains(where: { $0.sourceLanguage == .automatic }) else {
            throw TranslationFailure.automaticSourceLanguageUnavailable
        }

        let groups = Dictionary(grouping: requests) { request in
            guard case .language(let language) = request.sourceLanguage else {
                preconditionFailure("Automatic source languages must fail during preflight.")
            }
            return language
        }

        let unorderedResults = try await withThrowingTaskGroup(
            of: [TranslationResult].self,
            returning: [TranslationResult].self
        ) { group in
            for (sourceLanguage, groupRequests) in groups {
                try Task.checkCancellation()
                let driver = driverFactory.makeDriver(sourceLanguage, targetLanguage)
                group.addTask {
                    let results = try await translate(groupRequests, using: driver)
                    return try TranslationResponseMembership.validateAndOrder(
                        results,
                        expectedIdentifiers: groupRequests.map(\.id)
                    )
                }
            }

            var results: [TranslationResult] = []
            results.reserveCapacity(requests.count)
            do {
                for try await groupResults in group {
                    results.append(contentsOf: groupResults)
                }
            } catch {
                group.cancelAll()
                throw error
            }
            return results
        }

        try Task.checkCancellation()
        return unorderedResults
    }

    private func translate(
        _ requests: [TranslationRequest],
        using driver: OnDeviceTranslationDriver
    ) async throws -> [TranslationResult] {
        let cancellation = OnDeviceCancellationCoordinator()

        do {
            let results = try await withTaskCancellationHandler {
                let results: [TranslationResult]
                do {
                    results = try await driver.translate(requests)
                } catch {
                    await cancellation.finishOperation()
                    try Task.checkCancellation()
                    throw error
                }

                await cancellation.finishOperation()
                try Task.checkCancellation()
                return results
            } onCancel: {
                cancellation.requestCancellation {
                    await driver.cancel()
                }
            }
            return results
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TranslationFailure {
            throw failure
        } catch {
            if Task.isCancelled || TranslationError.alreadyCancelled ~= error {
                throw CancellationError()
            }
            if TranslationError.unsupportedSourceLanguage ~= error {
                throw TranslationFailure.unsupportedSourceLanguage
            }
            if TranslationError.unsupportedTargetLanguage ~= error {
                throw TranslationFailure.unsupportedTargetLanguage
            }
            if TranslationError.unsupportedLanguagePairing ~= error {
                throw TranslationFailure.unsupportedLanguagePairing
            }
            if TranslationError.unableToIdentifyLanguage ~= error {
                throw TranslationFailure.unableToIdentifySourceLanguage
            }
            if TranslationError.nothingToTranslate ~= error {
                throw TranslationFailure.nothingToTranslate
            }
            if TranslationError.notInstalled ~= error {
                throw TranslationFailure.languageAssetsNotInstalled
            }
            throw TranslationFailure.providerInternal
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private actor OnDeviceTranslationSessionOwner {
    private let session: TranslationSession

    init(
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) {
        self.session = TranslationSession(
            installedSource: sourceLanguage.localeLanguage,
            target: targetLanguage.localeLanguage
        )
    }

    func translate(
        _ requests: [TranslationRequest]
    ) async throws -> [TranslationResult] {
        let batch = requests.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: $0.id
            )
        }
        var results: [TranslationResult] = []
        results.reserveCapacity(requests.count)
        for try await response in session.translate(batch: batch) {
            guard let requestID = response.clientIdentifier else {
                throw TranslationFailure.providerInternal
            }
            results.append(
                TranslationResult(
                    requestID: requestID,
                    translatedText: response.targetText
                )
            )
        }
        return results
    }

    func cancel() {
        session.cancel()
    }
}

final class OnDeviceCancellationCoordinator: Sendable {
    private enum State {
        case active
        case cancelling(Task<Void, Never>)
        case finished
    }

    private let state = Mutex(State.active)

    @discardableResult
    func requestCancellation(
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        state.withLock { state in
            switch state {
            case .active:
                state = .cancelling(
                    Task {
                        await operation()
                    }
                )
                return true
            case .cancelling:
                preconditionFailure("A cancellation handler must run at most once.")
            case .finished:
                // Completion won the race, so no resource work remains to cancel.
                return false
            }
        }
    }

    func finishOperation() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            switch state {
            case .active:
                state = .finished
                return nil
            case .cancelling(let task):
                state = .finished
                return task
            case .finished:
                preconditionFailure("Cancellation coordination must finish exactly once.")
            }
        }
        await task?.value
    }
}
