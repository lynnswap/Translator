import Foundation
import Synchronization

struct GoogleAppsScriptSessionFactory: Sendable {
    let makeConfiguration: @Sendable () -> URLSessionConfiguration

    static let live = GoogleAppsScriptSessionFactory {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func makeSession() -> GoogleAppsScriptSession {
        GoogleAppsScriptSession(configuration: makeConfiguration())
    }
}

struct GoogleAppsScriptSession: Sendable {
    private let session: URLSession
    private let invalidationDelegate: GoogleAppsScriptSessionInvalidationDelegate

    init(configuration: URLSessionConfiguration) {
        let invalidationDelegate = GoogleAppsScriptSessionInvalidationDelegate()
        self.session = URLSession(
            configuration: configuration,
            delegate: invalidationDelegate,
            delegateQueue: nil
        )
        self.invalidationDelegate = invalidationDelegate
    }

    var configuration: URLSessionConfiguration {
        session.configuration
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func finish() async {
        await invalidationDelegate.invalidateAfterFinishingTasks(in: session)
    }
}

private final class GoogleAppsScriptSessionInvalidationDelegate:
    NSObject,
    URLSessionDelegate,
    @unchecked Sendable
{
    private struct State {
        var invalidationRequested = false
        var invalidated = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    // SAFETY: URLSession delegate callbacks and operation tasks access mutable state only
    // through this mutex.
    private let state = Mutex(State())

    func invalidateAfterFinishingTasks(in session: URLSession) async {
        let needsInvalidationRequest = state.withLock { state in
            precondition(
                !state.invalidationRequested,
                "A Google Apps Script session must be finished exactly once."
            )
            state.invalidationRequested = true
            return !state.invalidated
        }
        if needsInvalidationRequest {
            session.finishTasksAndInvalidate()
        }
        await waitForInvalidation()
    }

    private func waitForInvalidation() async {
        await withCheckedContinuation { continuation in
            let alreadyInvalidated = state.withLock { state in
                guard !state.invalidated else { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyInvalidated {
                continuation.resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: (any Error)?
    ) {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            assert(!state.invalidated, "URLSession must report invalidation exactly once.")
            guard !state.invalidated else { return [] }
            state.invalidated = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

struct GoogleAppsScriptTransport: Sendable {
    private struct RequestItem: Encodable, Sendable {
        let tweetId: String
        let text: String
    }

    private struct RequestBody: Encodable, Sendable {
        let tweets: [RequestItem]
        let sourceLang: String
        let targetLang: String
    }

    let endpoint: GoogleAppsScriptEndpoint
    let session: GoogleAppsScriptSession
    let makeToken: @Sendable () -> UUID

    init(
        endpoint: GoogleAppsScriptEndpoint,
        sessionFactory: GoogleAppsScriptSessionFactory = .live,
        makeToken: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.endpoint = endpoint
        self.session = sessionFactory.makeSession()
        self.makeToken = makeToken
    }

    var transport: TranslationTransport {
        TranslationTransport(
            translate: { requests, sourceLanguage, targetLanguage in
                try await translate(
                    requests: requests,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
            },
            finish: {
                await session.finish()
            }
        )
    }

    func translate(
        requests: [TranslationRequest],
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationLanguage
    ) async throws -> [TranslationTransportResult] {
        try Task.checkCancellation()

        var tokens: [String] = []
        var tokenSet: Set<String> = []
        tokens.reserveCapacity(requests.count)
        tokenSet.reserveCapacity(requests.count)
        for _ in requests {
            var token: String
            repeat {
                token = makeToken().uuidString
            } while !tokenSet.insert(token).inserted
            tokens.append(token)
        }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encodeRequestBody(
            requests: requests,
            tokens: tokens,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()

            guard let response = response as? HTTPURLResponse else {
                throw TranslationFailure.malformedResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw TranslationFailure.serverRejected(statusCode: response.statusCode)
            }

            let tokenResults = try TranslationResponseMembership.validateAndOrder(
                Self.decodeResponse(data),
                expectedIdentifiers: tokens
            )
            return zip(requests, tokenResults).map { request, tokenResult in
                TranslationTransportResult(
                    requestID: request.id,
                    translatedText: tokenResult.translatedText
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TranslationFailure {
            throw failure
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw TranslationFailure.transport
        }
    }

    static func encodeRequestBody(
        requests: [TranslationRequest],
        tokens: [String],
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationLanguage
    ) throws -> Data {
        precondition(requests.count == tokens.count)
        let sourceIdentifier: String
        switch sourceLanguage {
        case .automatic:
            sourceIdentifier = ""
        case .language(let language):
            sourceIdentifier = language.identifier
        }
        return try JSONEncoder().encode(
            RequestBody(
                tweets: zip(requests, tokens).map { request, token in
                    RequestItem(tweetId: token, text: request.text)
                },
                sourceLang: sourceIdentifier,
                targetLang: targetLanguage.identifier
            )
        )
    }

    static func decodeResponse(_ data: Data) throws -> [TranslationTransportResult] {
        let rows: [[String]]
        do {
            rows = try JSONDecoder().decode([[String]].self, from: data)
        } catch {
            throw TranslationFailure.malformedResponse
        }

        return try rows.map { row in
            guard row.count == 2 else {
                throw TranslationFailure.malformedResponse
            }
            return TranslationTransportResult(
                requestID: row[0],
                translatedText: row[1]
            )
        }
    }
}
