import Foundation
import Synchronization
import Translation

@available(iOS 26.0, macOS 26.0, *)
struct OnDeviceTranslationDriver: Sendable {
    let translate: @Sendable ([TranslationRequest]) async throws -> [TranslationTransportResult]
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
struct OnDeviceTranslationTransport: Sendable {
    let driverFactory: OnDeviceTranslationDriverFactory

    init(driverFactory: OnDeviceTranslationDriverFactory = .live) {
        self.driverFactory = driverFactory
    }

    var transport: TranslationTransport {
        TranslationTransport(
            translate: { requests, sourceLanguage, targetLanguage in
                try await translate(
                    requests: requests,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
            }
        )
    }

    func translate(
        requests: [TranslationRequest],
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationLanguage
    ) async throws -> [TranslationTransportResult] {
        guard case .language(let sourceLanguage) = sourceLanguage else {
            throw TranslationFailure.automaticSourceLanguageUnavailable
        }

        let driver = driverFactory.makeDriver(sourceLanguage, targetLanguage)
        let cancellation = OnDeviceCancellationTask()

        do {
            do {
                let results = try await withTaskCancellationHandler {
                    do {
                        let results = try await driver.translate(requests)
                        await cancellation.waitForCompletion(ifRequested: Task.isCancelled)
                        try Task.checkCancellation()
                        return results
                    } catch {
                        await cancellation.waitForCompletion(ifRequested: Task.isCancelled)
                        throw error
                    }
                } onCancel: {
                    cancellation.start {
                        await driver.cancel()
                    }
                }
                await cancellation.waitForCompletionIfStarted()
                return results
            } catch {
                await cancellation.waitForCompletionIfStarted()
                throw error
            }
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
    ) async throws -> [TranslationTransportResult] {
        let batch = requests.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: $0.id
            )
        }
        var results: [TranslationTransportResult] = []
        results.reserveCapacity(requests.count)
        for try await response in session.translate(batch: batch) {
            guard let requestID = response.clientIdentifier else {
                throw TranslationFailure.malformedResponse
            }
            results.append(
                TranslationTransportResult(
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

private final class OnDeviceCancellationTask: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var waiters: [CheckedContinuation<Task<Void, Never>, Never>] = []
    }

    private let state = Mutex(State())

    func start(operation: @escaping @Sendable () async -> Void) {
        let (task, waiters) = state.withLock { state in
            precondition(state.task == nil, "A cancellation handler must run at most once.")
            // Publish the handle before releasing the lock: the cancellation handler and
            // translation operation may run concurrently, and completion must await this task.
            let task = Task {
                await operation()
            }
            state.task = task
            defer { state.waiters.removeAll() }
            return (task, state.waiters)
        }
        for waiter in waiters {
            waiter.resume(returning: task)
        }
    }

    func waitForCompletion(ifRequested cancellationWasRequested: Bool) async {
        guard cancellationWasRequested else { return }

        let task = await withCheckedContinuation { continuation in
            let existingTask = state.withLock { state -> Task<Void, Never>? in
                if let task = state.task {
                    return task
                }
                state.waiters.append(continuation)
                return nil
            }
            if let existingTask {
                continuation.resume(returning: existingTask)
            }
        }
        await task.value
    }

    func waitForCompletionIfStarted() async {
        let task = state.withLock { $0.task }
        await task?.value
    }
}
