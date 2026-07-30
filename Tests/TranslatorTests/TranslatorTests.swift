import Foundation
import Synchronization
import Testing
import Translation
@testable import Translator

private let english = try! TranslationLanguage(identifier: "en")
private let french = try! TranslationLanguage(identifier: "fr")
private let japanese = try! TranslationLanguage(identifier: "ja")

private func known(_ language: TranslationLanguage) -> TranslationSourceLanguage {
    .language(language)
}

private func request(
    id: String,
    text: String,
    source: TranslationSourceLanguage = known(english)
) -> TranslationRequest {
    TranslationRequest(id: id, text: text, sourceLanguage: source)
}

private struct RecordedCall: Sendable {
    let requests: [TranslationRequest]
    let sourceLanguage: TranslationSourceLanguage
    let targetLanguage: TranslationLanguage
}

private actor TransportRecorder {
    private var calls: [RecordedCall] = []

    func record(
        requests: [TranslationRequest],
        sourceLanguage: TranslationSourceLanguage,
        targetLanguage: TranslationLanguage
    ) {
        calls.append(
            RecordedCall(
                requests: requests,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
    }

    func snapshot() -> [RecordedCall] {
        calls
    }
}

private final class CountProbe: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

private func makeClient(
    finish: @escaping @Sendable () async -> Void = {},
    handler: @escaping @Sendable (
        [TranslationRequest],
        TranslationSourceLanguage,
        TranslationLanguage
    ) async throws -> [TranslationTransportResult]
) -> (client: TranslationClient, recorder: TransportRecorder) {
    let recorder = TransportRecorder()
    let transport = TranslationTransport(
        translate: { requests, sourceLanguage, targetLanguage in
            await recorder.record(
                requests: requests,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            return try await handler(requests, sourceLanguage, targetLanguage)
        },
        finish: finish
    )
    return (
        TranslationClient(
            transportFactory: TranslationTransportFactory { _ in transport }
        ),
        recorder
    )
}

private func successfulResults(
    for requests: [TranslationRequest]
) -> [TranslationTransportResult] {
    requests.map {
        TranslationTransportResult(
            requestID: $0.id,
            translatedText: "translated:\($0.text)"
        )
    }
}

private func collect(
    _ results: TranslationResults
) async throws -> [[TranslationResult]] {
    var batches: [[TranslationResult]] = []
    for try await batch in results {
        batches.append(batch)
    }
    return batches
}

private func terminalError(
    from results: TranslationResults
) async -> (any Error)? {
    do {
        _ = try await collect(results)
        return nil
    } catch {
        return error
    }
}

private func endpoint(_ deploymentID: String = "deployment-A") throws -> GoogleAppsScriptEndpoint {
    try GoogleAppsScriptEndpoint(deploymentID: deploymentID)
}

@Test func endpointRejectsEmptyWhitespaceAndPathInjection() throws {
    for invalidID in ["", " ", "deployment/id", "deployment?id", "déploiement"] {
        #expect(throws: TranslationFailure.invalidGoogleAppsScriptDeploymentID) {
            try GoogleAppsScriptEndpoint(deploymentID: invalidID)
        }
    }

    let valid = try endpoint("AKfycb_abc-123")
    #expect(valid.deploymentID == "AKfycb_abc-123")
    #expect(valid.url.absoluteString == "https://script.google.com/macros/s/AKfycb_abc-123/exec")
}

@Test func translationLanguageValidatesAndCanonicalizesFoundationLanguages() throws {
    #expect(try TranslationLanguage(identifier: "fr_CA").identifier == "fr-CA")
    #expect(try TranslationLanguage(identifier: "zh-Hant").identifier == "zh-Hant")

    let foundationLanguage = Locale.Language(identifier: "sr-Latn-RS")
    let language = try TranslationLanguage(foundationLanguage)
    #expect(language.identifier == "sr-Latn-RS")
    #expect(language.localeLanguage.languageCode?.identifier == "sr")

    for invalidIdentifier in ["", " ", "en US", "und", "zxx", "qq", "xyz", "en-u-ca-gregory"] {
        #expect(throws: TranslationFailure.invalidLanguageIdentifier) {
            try TranslationLanguage(identifier: invalidIdentifier)
        }
    }
    #expect(throws: TranslationFailure.invalidLanguageIdentifier) {
        try TranslationLanguage(Locale.Language(identifier: "und"))
    }
    #expect(throws: TranslationFailure.invalidLanguageIdentifier) {
        try TranslationLanguage(Locale.Language(identifier: "zxx"))
    }
}

@Test func sequenceIsColdAndEachIteratorHasIndependentState() async throws {
    let factoryCount = CountProbe()
    let transportCount = CountProbe()
    let transport = TranslationTransport(translate: { requests, _, _ in
        transportCount.increment()
        return successfulResults(for: requests)
    })
    let client = TranslationClient(
        transportFactory: TranslationTransportFactory { _ in
            factoryCount.increment()
            return transport
        }
    )
    let sequence = client.translations(
        for: [request(id: "first", text: "Hello")],
        to: japanese,
        using: .googleAppsScript(try endpoint())
    )

    #expect(factoryCount.value == 0)
    #expect(transportCount.value == 0)

    var firstIterator = sequence.makeAsyncIterator()
    var secondIterator = sequence.makeAsyncIterator()
    #expect(try await firstIterator.next()?.map(\.requestID) == ["first"])
    #expect(try await firstIterator.next() == nil)
    #expect(try await secondIterator.next()?.map(\.requestID) == ["first"])
    #expect(try await secondIterator.next() == nil)
    #expect(factoryCount.value == 1)
    #expect(transportCount.value == 1)
}

@Test func emptyInputFinishesWithoutResolvingTransport() async throws {
    let factoryCount = CountProbe()
    let client = TranslationClient(
        transportFactory: TranslationTransportFactory { _ in
            factoryCount.increment()
            return TranslationTransport(translate: { requests, _, _ in
                successfulResults(for: requests)
            })
        }
    )

    let batches = try await collect(
        client.translations(
            for: [],
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )
    #expect(batches.isEmpty)
    #expect(factoryCount.value == 0)
}

@Test func clientAliasesShareCacheButSeparateClientsDoNot() async throws {
    let provider = TranslationProvider.googleAppsScript(try endpoint())
    let callCount = CountProbe()
    let factory = TranslationTransportFactory { _ in
        TranslationTransport(translate: { requests, _, _ in
            callCount.increment()
            return successfulResults(for: requests)
        })
    }
    let firstClient = TranslationClient(transportFactory: factory)
    let alias = firstClient
    let secondClient = TranslationClient(transportFactory: factory)

    _ = try await collect(
        firstClient.translations(
            for: [request(id: "first", text: "Hello")],
            to: japanese,
            using: provider
        )
    )
    _ = try await collect(
        alias.translations(
            for: [request(id: "alias", text: "Hello")],
            to: japanese,
            using: provider
        )
    )
    _ = try await collect(
        secondClient.translations(
            for: [request(id: "second", text: "Hello")],
            to: japanese,
            using: provider
        )
    )

    #expect(callCount.value == 2)
}

@Test func cacheUsesContentIdentityAndKeepsRequestIDsAsCorrelationOnly() async throws {
    let (client, recorder) = makeClient { requests, _, _ in
        successfulResults(for: requests)
    }
    let provider = TranslationProvider.googleAppsScript(try endpoint())

    _ = try await collect(
        client.translations(
            for: [request(id: "warm", text: "Bonjour", source: known(french))],
            to: english,
            using: provider
        )
    )

    let batches = try await collect(
        client.translations(
            for: [
                request(id: "first", text: "Bonjour", source: known(french)),
                request(id: "fresh", text: "Salut", source: known(french)),
                request(id: "third", text: "Bonjour", source: known(french)),
            ],
            to: english,
            using: provider
        )
    )

    #expect(batches.count == 2)
    #expect(batches[0].map(\.requestID) == ["first", "third"])
    #expect(batches[1].map(\.requestID) == ["fresh"])
    #expect(await recorder.snapshot().count == 2)
}

@Test func cacheSeparatesSourcePolicyTargetAndProviderIdentity() async throws {
    let (client, recorder) = makeClient { requests, _, _ in
        successfulResults(for: requests)
    }
    let providerA = TranslationProvider.googleAppsScript(try endpoint("deployment-A"))
    let providerB = TranslationProvider.googleAppsScript(try endpoint("deployment-B"))

    func translate(
        id: String,
        text: String = "Hello",
        source: TranslationSourceLanguage = known(english),
        target: TranslationLanguage = japanese,
        provider: TranslationProvider = providerA
    ) async throws {
        _ = try await collect(
            client.translations(
                for: [request(id: id, text: text, source: source)],
                to: target,
                using: provider
            )
        )
    }

    try await translate(id: "base")
    try await translate(id: "correlation")
    try await translate(id: "automatic", source: .automatic)
    try await translate(id: "source", source: known(french))
    try await translate(id: "target", target: english)
    try await translate(id: "provider", provider: providerB)
    try await translate(id: "text", text: "Hello!")

    #expect(await recorder.snapshot().count == 6)
}

@Test func transportGroupsKnownAndAutomaticSourcesAndOrdersFreshResults() async throws {
    let (client, recorder) = makeClient { requests, _, _ in
        Array(successfulResults(for: requests).reversed())
    }
    let requests = [
        request(id: "1", text: "one"),
        request(id: "2", text: "deux", source: known(french)),
        request(id: "3", text: "unknown", source: .automatic),
        request(id: "4", text: "three"),
    ]

    let batches = try await collect(
        client.translations(
            for: requests,
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )
    let calls = await recorder.snapshot()

    #expect(batches.count == 1)
    #expect(batches[0].map(\.requestID) == ["1", "2", "3", "4"])
    #expect(calls.count == 3)
    #expect(Set(calls.map(\.sourceLanguage)) == Set([known(english), known(french), .automatic]))
    #expect(calls.allSatisfy { call in
        call.targetLanguage == japanese
            && call.requests.allSatisfy { $0.sourceLanguage == call.sourceLanguage }
    })
}

private enum MembershipScenario: CaseIterable, Sendable {
    case unknown
    case duplicate
    case missing

    var expectedFailure: TranslationFailure {
        switch self {
        case .unknown:
            .invalidResponseMembership(.unknownIdentifiers(count: 1))
        case .duplicate:
            .invalidResponseMembership(.duplicateIdentifiers(count: 1))
        case .missing:
            .invalidResponseMembership(.missingIdentifiers(count: 1))
        }
    }
}

@Test(arguments: MembershipScenario.allCases)
private func invalidFreshMembershipTerminatesBeforeReturningResults(
    scenario: MembershipScenario
) async throws {
    let (client, _) = makeClient { requests, _, _ in
        switch scenario {
        case .unknown:
            [
                TranslationTransportResult(requestID: requests[0].id, translatedText: "one"),
                TranslationTransportResult(requestID: "provider-token", translatedText: "unknown"),
            ]
        case .duplicate:
            [
                TranslationTransportResult(requestID: requests[0].id, translatedText: "one"),
                TranslationTransportResult(requestID: requests[0].id, translatedText: "again"),
                TranslationTransportResult(requestID: requests[1].id, translatedText: "two"),
            ]
        case .missing:
            [TranslationTransportResult(requestID: requests[0].id, translatedText: "one")]
        }
    }
    let error = await terminalError(
        from: client.translations(
            for: [
                request(id: "private-first", text: "one"),
                request(id: "private-second", text: "two"),
            ],
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )

    let failure = try #require(error as? TranslationFailure)
    #expect(failure == scenario.expectedFailure)
    #expect(!(failure.errorDescription ?? "").contains("private-first"))
    #expect(!(failure.errorDescription ?? "").contains("provider-token"))
}

@Test func membershipFailureRollsBackBeforeCacheCommit() async throws {
    let attempt = CountProbe()
    let (client, _) = makeClient { requests, _, _ in
        attempt.increment()
        if attempt.value == 1 {
            return [TranslationTransportResult(requestID: "unknown", translatedText: "invalid")]
        }
        return successfulResults(for: requests)
    }
    let provider = TranslationProvider.googleAppsScript(try endpoint())

    let firstError = await terminalError(
        from: client.translations(
            for: [request(id: "first", text: "Hello")],
            to: japanese,
            using: provider
        )
    )
    #expect(
        firstError as? TranslationFailure
            == .invalidResponseMembership(.unknownIdentifiers(count: 1))
    )

    let second = try await collect(
        client.translations(
            for: [request(id: "second", text: "Hello")],
            to: japanese,
            using: provider
        )
    )
    #expect(second.flatMap { $0 }.map(\.requestID) == ["second"])
    #expect(attempt.value == 2)
}

@Test func duplicateInputIdentifiersAreRedactedAndStopBeforeTransport() async throws {
    let (client, recorder) = makeClient { requests, _, _ in
        successfulResults(for: requests)
    }
    let error = await terminalError(
        from: client.translations(
            for: [
                request(id: "private-duplicate", text: "one"),
                request(id: "private-duplicate", text: "two"),
            ],
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )

    let failure = try #require(error as? TranslationFailure)
    #expect(failure == .duplicateRequestIdentifiers(count: 1))
    #expect(!(failure.errorDescription ?? "").contains("private-duplicate"))
    #expect(await recorder.snapshot().isEmpty)
}

private enum TestTransportError: Error {
    case unavailable
}

@Test func unknownTransportErrorsBecomePublicTerminalFailures() async throws {
    let (client, _) = makeClient { _, _, _ in
        throw TestTransportError.unavailable
    }
    let error = await terminalError(
        from: client.translations(
            for: [request(id: "1", text: "one")],
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )

    #expect(error as? TranslationFailure == .transport)
}

private final class CancellationProbe: Sendable {
    private struct State {
        var continuations: [String: CheckedContinuation<Void, any Error>] = [:]
        var cancelledIDs: Set<String> = []
        var startedCount = 0
        var finishedCount = 0
        var callCount = 0
        var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var allowSuccess = false
    }

    private let state = Mutex(State())

    func waitForCancellationIfNeeded(id: String, firstPhaseCount: Int) async throws {
        let shouldSuspend = state.withLock { state in
            state.callCount += 1
            if state.allowSuccess { return false }
            state.startedCount += 1
            let readyWaiters = state.startedWaiters.filter { $0.count <= state.startedCount }
            state.startedWaiters.removeAll { $0.count <= state.startedCount }
            for waiter in readyWaiters {
                waiter.continuation.resume()
            }
            return true
        }
        guard shouldSuspend else { return }

        defer {
            state.withLock { state in
                state.finishedCount += 1
                if state.finishedCount == firstPhaseCount {
                    state.allowSuccess = true
                }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let wasAlreadyCancelled = state.withLock { state in
                    if state.cancelledIDs.remove(id) != nil {
                        return true
                    }
                    state.continuations[id] = continuation
                    return false
                }
                if wasAlreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard state.startedCount < count else { return true }
                state.startedWaiters.append((count, continuation))
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func snapshot() -> (callCount: Int, finishedCount: Int) {
        state.withLock { ($0.callCount, $0.finishedCount) }
    }

    private func cancel(id: String) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard let continuation = state.continuations.removeValue(forKey: id) else {
                state.cancelledIDs.insert(id)
                return nil
            }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

@Test func cancellationWaitsForChildTransportsAndDoesNotPopulateCache() async throws {
    let probe = CancellationProbe()
    let finishCount = CountProbe()
    let (client, _) = makeClient(
        finish: { finishCount.increment() }
    ) { requests, _, _ in
        let operationID = try #require(requests.first?.id)
        try await probe.waitForCancellationIfNeeded(id: operationID, firstPhaseCount: 2)
        return successfulResults(for: requests)
    }
    let provider = TranslationProvider.googleAppsScript(try endpoint())
    let firstRequests = [
        request(id: "first-en", text: "Hello"),
        request(id: "first-fr", text: "Bonjour", source: known(french)),
    ]

    let task = Task {
        try await collect(
            client.translations(
                for: firstRequests,
                to: japanese,
                using: provider
            )
        )
    }
    await probe.waitUntilStarted(count: 2)
    task.cancel()
    let firstResult = await task.result

    switch firstResult {
    case .success:
        Issue.record("Cancelled translation unexpectedly succeeded.")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    #expect(probe.snapshot().finishedCount == 2)
    #expect(finishCount.value == 1)

    let secondBatches = try await collect(
        client.translations(
            for: [
                request(id: "second-en", text: "Hello"),
                request(id: "second-fr", text: "Bonjour", source: known(french)),
            ],
            to: japanese,
            using: provider
        )
    )
    #expect(secondBatches.count == 1)
    #expect(probe.snapshot().callCount == 4)
    #expect(finishCount.value == 2)
}

@Test func transportFinishRunsExactlyOnceForMembershipFailure() async throws {
    let finishCount = CountProbe()
    let (client, _) = makeClient(finish: { finishCount.increment() }) { _, _, _ in
        [TranslationTransportResult(requestID: "unknown", translatedText: "invalid")]
    }
    _ = await terminalError(
        from: client.translations(
            for: [request(id: "expected", text: "Hello")],
            to: japanese,
            using: .googleAppsScript(try endpoint())
        )
    )
    #expect(finishCount.value == 1)
}

@Test func concurrentOperationsShareCacheWithoutDataRaces() async throws {
    let (client, recorder) = makeClient { requests, _, _ in
        successfulResults(for: requests)
    }
    let provider = TranslationProvider.googleAppsScript(try endpoint())

    let resultCount = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
        for index in 0..<32 {
            group.addTask {
                let batches = try await collect(
                    client.translations(
                        for: [request(id: "id-\(index)", text: "text-\(index)")],
                        to: japanese,
                        using: provider
                    )
                )
                return batches.flatMap { $0 }.count
            }
        }

        var count = 0
        for try await childCount in group {
            count += childCount
        }
        return count
    }

    #expect(resultCount == 32)
    #expect(await recorder.snapshot().count == 32)
}

@Test func oversizedCacheStoreRetainsOnlyNewestUniqueEntries() async throws {
    let cache = TranslationCache(countLimit: 3)
    let first = TranslationCache.Key(
        text: "first",
        sourceLanguage: known(english),
        targetLanguage: japanese,
        provider: .googleAppsScript(try endpoint())
    )
    let second = TranslationCache.Key(
        text: "second",
        sourceLanguage: known(english),
        targetLanguage: japanese,
        provider: .googleAppsScript(try endpoint())
    )
    let third = TranslationCache.Key(
        text: "third",
        sourceLanguage: known(english),
        targetLanguage: japanese,
        provider: .googleAppsScript(try endpoint())
    )
    let fourth = TranslationCache.Key(
        text: "fourth",
        sourceLanguage: known(english),
        targetLanguage: japanese,
        provider: .googleAppsScript(try endpoint())
    )

    try await cache.store([
        (first, "obsolete-first"),
        (second, "second"),
        (first, "newest-first"),
        (third, "third"),
        (fourth, "fourth"),
    ])

    let values = try await cache.values(for: [first, second, third, fourth])
    #expect(values[first] == "newest-first")
    #expect(values[second] == nil)
    #expect(values[third] == "third")
    #expect(values[fourth] == "fourth")
}

@Test func smallCacheStoreMergesWithExistingRecency() async throws {
    let cache = TranslationCache(countLimit: 3)
    let provider = TranslationProvider.googleAppsScript(try endpoint())
    let keys = ["first", "second", "third", "fourth"].map { text in
        TranslationCache.Key(
            text: text,
            sourceLanguage: known(english),
            targetLanguage: japanese,
            provider: provider
        )
    }

    try await cache.store([
        (keys[0], "first"),
        (keys[1], "second"),
        (keys[2], "third"),
    ])
    _ = try await cache.values(for: [keys[0]])
    try await cache.store([(keys[3], "fourth")])

    let values = try await cache.values(for: keys)
    #expect(values[keys[0]] == "first")
    #expect(values[keys[1]] == nil)
    #expect(values[keys[2]] == "third")
    #expect(values[keys[3]] == "fourth")
}

private enum StubDisposition: Sendable {
    case response(statusCode: Int, data: Data)
    case pending(URLProtocolProbe)
}

private final class URLProtocolRouter: Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubDisposition

    static let shared = URLProtocolRouter()

    private let routes = Mutex<[URL: Handler]>([:])

    func install(url: URL, handler: @escaping Handler) {
        routes.withLock { routes in
            precondition(routes.updateValue(handler, forKey: url) == nil)
        }
    }

    func remove(url: URL) {
        routes.withLock { routes in
            precondition(routes.removeValue(forKey: url) != nil)
        }
    }

    func disposition(for request: URLRequest) -> StubDisposition? {
        guard let url = request.url else { return nil }
        return routes.withLock { $0[url] }?(request)
    }
}

private final class StubURLProtocol: URLProtocol {
    private let pendingProbe = Mutex<URLProtocolProbe?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let disposition = URLProtocolRouter.shared.disposition(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch disposition {
        case .response(let statusCode, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .pending(let probe):
            pendingProbe.withLock { storedProbe in
                precondition(storedProbe == nil)
                storedProbe = probe
            }
            probe.didStart()
        }
    }

    override func stopLoading() {
        let probe = pendingProbe.withLock { storedProbe in
            defer { storedProbe = nil }
            return storedProbe
        }
        probe?.didStop()
    }
}

private final class URLProtocolProbe: Sendable {
    private struct State {
        var started = 0
        var stopped = 0
        var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func didStart() {
        let waiters = state.withLock { state in
            state.started += 1
            let waiters = state.startWaiters.filter { $0.0 <= state.started }
            state.startWaiters.removeAll { $0.0 <= state.started }
            return waiters
        }
        for waiter in waiters {
            waiter.1.resume()
        }
    }

    func didStop() {
        let waiters = state.withLock { state in
            state.stopped += 1
            let waiters = state.stopWaiters.filter { $0.0 <= state.stopped }
            state.stopWaiters.removeAll { $0.0 <= state.stopped }
            return waiters
        }
        for waiter in waiters {
            waiter.1.resume()
        }
    }

    func waitUntilStarted(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard state.started < count else { return true }
                state.startWaiters.append((count, continuation))
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func waitUntilStopped(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyStopped = state.withLock { state in
                guard state.stopped < count else { return true }
                state.stopWaiters.append((count, continuation))
                return false
            }
            if alreadyStopped {
                continuation.resume()
            }
        }
    }

    var snapshot: (started: Int, stopped: Int) {
        state.withLock { ($0.started, $0.stopped) }
    }
}

private final class PayloadProbe: Sendable {
    private let payloads = Mutex<[Data]>([])

    func append(_ data: Data) {
        payloads.withLock { $0.append(data) }
    }

    var snapshot: [Data] {
        payloads.withLock { $0 }
    }
}

private final class SessionFactoryProbe: Sendable {
    private let count = Mutex(0)

    func makeConfiguration() -> URLSessionConfiguration {
        count.withLock { $0 += 1 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    var createdCount: Int {
        count.withLock { $0 }
    }
}

private func makeGoogleClient(
    sessionFactory: SessionFactoryProbe
) -> TranslationClient {
    TranslationClient(
        transportFactory: TranslationTransportFactory { provider in
            guard case .googleAppsScript(let endpoint) = provider.storage else {
                preconditionFailure("The test expects the Google Apps Script provider.")
            }
            return GoogleAppsScriptTransport(
                endpoint: endpoint,
                sessionFactory: GoogleAppsScriptSessionFactory {
                    sessionFactory.makeConfiguration()
                }
            ).transport
        }
    )
}

private func googleResponse(for request: URLRequest, payloadProbe: PayloadProbe? = nil) -> Data {
    guard let body = requestBodyData(request),
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let tweets = object["tweets"] as? [[String: Any]] else {
        return Data(#"{"invalid":true}"#.utf8)
    }
    payloadProbe?.append(body)
    let rows = tweets.compactMap { tweet -> [String]? in
        guard let token = tweet["tweetId"] as? String,
              let text = tweet["text"] as? String else {
            return nil
        }
        return [token, "translated:\(text)"]
    }
    return (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { unsafe buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = unsafe stream.read(buffer, maxLength: 4_096)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        unsafe data.append(buffer, count: count)
    }
    return data
}

@Test func liveGoogleSessionConfigurationIsEphemeralAndStateless() async {
    let session = GoogleAppsScriptSessionFactory.live.makeSession()
    let configuration = session.configuration

    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    await session.finish()
}

@Test func googleTransportUsesOpaqueTokensAndAutomaticSourceWireValue() async throws {
    let endpoint = try endpoint("opaque-token-contract")
    let payloadProbe = PayloadProbe()
    URLProtocolRouter.shared.install(url: endpoint.url) { request in
        .response(statusCode: 200, data: googleResponse(for: request, payloadProbe: payloadProbe))
    }
    defer { URLProtocolRouter.shared.remove(url: endpoint.url) }

    let sessionFactory = SessionFactoryProbe()
    let client = makeGoogleClient(sessionFactory: sessionFactory)
    let batches = try await collect(
        client.translations(
            for: [request(id: "raw-private-id", text: "Bonjour", source: .automatic)],
            to: english,
            using: .googleAppsScript(endpoint)
        )
    )

    #expect(batches.flatMap { $0 }.map(\.requestID) == ["raw-private-id"])
    let payload = try #require(payloadProbe.snapshot.first)
    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let tweets = try #require(object["tweets"] as? [[String: Any]])
    let token = try #require(tweets.first?["tweetId"] as? String)
    #expect(token != "raw-private-id")
    #expect(UUID(uuidString: token) != nil)
    #expect(object["sourceLang"] as? String == "")
    #expect(object["targetLang"] as? String == "en")
    #expect(sessionFactory.createdCount == 1)
}

@Test func googleTransportSharesOneSessionAcrossKnownSourceGroups() async throws {
    let endpoint = try endpoint("one-session-contract")
    let payloadProbe = PayloadProbe()
    URLProtocolRouter.shared.install(url: endpoint.url) { request in
        .response(statusCode: 200, data: googleResponse(for: request, payloadProbe: payloadProbe))
    }
    defer { URLProtocolRouter.shared.remove(url: endpoint.url) }

    let sessionFactory = SessionFactoryProbe()
    let client = makeGoogleClient(sessionFactory: sessionFactory)
    _ = try await collect(
        client.translations(
            for: [
                request(id: "english", text: "Hello"),
                request(id: "french", text: "Bonjour", source: known(french)),
                request(id: "automatic", text: "Unknown", source: .automatic),
            ],
            to: japanese,
            using: .googleAppsScript(endpoint)
        )
    )

    let sourceIdentifiers = try payloadProbe.snapshot.map { payload -> String in
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try #require(object["sourceLang"] as? String)
    }
    #expect(Set(sourceIdentifiers) == Set(["en", "fr", ""]))
    #expect(sessionFactory.createdCount == 1)
}

@Test func googleTransportMapsHTTPStatusAndMalformedMembership() async throws {
    let statusEndpoint = try endpoint("status-contract")
    URLProtocolRouter.shared.install(url: statusEndpoint.url) { _ in
        .response(statusCode: 503, data: Data())
    }
    defer { URLProtocolRouter.shared.remove(url: statusEndpoint.url) }

    let statusClient = makeGoogleClient(sessionFactory: SessionFactoryProbe())
    let statusError = await terminalError(
        from: statusClient.translations(
            for: [request(id: "private-status", text: "Hello")],
            to: japanese,
            using: .googleAppsScript(statusEndpoint)
        )
    )
    #expect(statusError as? TranslationFailure == .serverRejected(statusCode: 503))

    let membershipEndpoint = try endpoint("membership-contract")
    URLProtocolRouter.shared.install(url: membershipEndpoint.url) { _ in
        .response(
            statusCode: 200,
            data: Data(#"[["outside-token","translated"]]"#.utf8)
        )
    }
    defer { URLProtocolRouter.shared.remove(url: membershipEndpoint.url) }

    let membershipClient = makeGoogleClient(sessionFactory: SessionFactoryProbe())
    let membershipError = await terminalError(
        from: membershipClient.translations(
            for: [request(id: "private-membership", text: "Hello")],
            to: japanese,
            using: .googleAppsScript(membershipEndpoint)
        )
    )
    let membershipFailure = try #require(membershipError as? TranslationFailure)
    #expect(
        membershipFailure
            == .invalidResponseMembership(.unknownIdentifiers(count: 1))
    )
    #expect(!(membershipFailure.errorDescription ?? "").contains("outside-token"))
    #expect(!(membershipFailure.errorDescription ?? "").contains("private-membership"))
}

@Test(arguments: 0..<16)
func googleCancellationCancelsEveryURLProtocolTask(iteration: Int) async throws {
    let endpoint = try endpoint("cancellation-contract-\(iteration)")
    let protocolProbe = URLProtocolProbe()
    URLProtocolRouter.shared.install(url: endpoint.url) { _ in
        .pending(protocolProbe)
    }
    defer { URLProtocolRouter.shared.remove(url: endpoint.url) }

    let sessionFactory = SessionFactoryProbe()
    let client = makeGoogleClient(sessionFactory: sessionFactory)
    let task = Task {
        try await collect(
            client.translations(
                for: [
                    request(id: "first", text: "Hello"),
                    request(id: "second", text: "Bonjour", source: known(french)),
                ],
                to: japanese,
                using: .googleAppsScript(endpoint)
            )
        )
    }

    await protocolProbe.waitUntilStarted(2)
    task.cancel()
    let result = await task.result
    switch result {
    case .success:
        Issue.record("Cancelled URLSession operation unexpectedly succeeded.")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    await protocolProbe.waitUntilStopped(2)
    #expect(protocolProbe.snapshot.started == 2)
    #expect(protocolProbe.snapshot.stopped == 2)
    #expect(sessionFactory.createdCount == 1)
}

@available(iOS 26.0, macOS 26.0, *)
private enum OnDeviceErrorScenario: CaseIterable, Sendable {
    case unsupportedSource
    case unsupportedTarget
    case unsupportedPair
    case unableToIdentify
    case nothingToTranslate
    case notInstalled
    case internalError

    var error: any Error {
        switch self {
        case .unsupportedSource: TranslationError.unsupportedSourceLanguage
        case .unsupportedTarget: TranslationError.unsupportedTargetLanguage
        case .unsupportedPair: TranslationError.unsupportedLanguagePairing
        case .unableToIdentify: TranslationError.unableToIdentifyLanguage
        case .nothingToTranslate: TranslationError.nothingToTranslate
        case .notInstalled: TranslationError.notInstalled
        case .internalError: TranslationError.internalError
        }
    }

    var expectedFailure: TranslationFailure {
        switch self {
        case .unsupportedSource: .unsupportedSourceLanguage
        case .unsupportedTarget: .unsupportedTargetLanguage
        case .unsupportedPair: .unsupportedLanguagePairing
        case .unableToIdentify: .unableToIdentifySourceLanguage
        case .nothingToTranslate: .nothingToTranslate
        case .notInstalled: .languageAssetsNotInstalled
        case .internalError: .providerInternal
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test(arguments: OnDeviceErrorScenario.allCases)
private func onDeviceMapsEveryTranslationError(scenario: OnDeviceErrorScenario) async throws {
    let transport = OnDeviceTranslationTransport(
        driverFactory: OnDeviceTranslationDriverFactory { _, _ in
            OnDeviceTranslationDriver(
                translate: { _ in throw scenario.error },
                cancel: {}
            )
        }
    )

    do {
        _ = try await transport.translate(
            requests: [request(id: "1", text: "Hello")],
            sourceLanguage: known(english),
            targetLanguage: japanese
        )
        Issue.record("Expected on-device translation to fail.")
    } catch let failure as TranslationFailure {
        #expect(failure == scenario.expectedFailure)
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDeviceRejectsAutomaticSourceBeforeCreatingSessionDriver() async throws {
    let driverCount = CountProbe()
    let transport = OnDeviceTranslationTransport(
        driverFactory: OnDeviceTranslationDriverFactory { _, _ in
            driverCount.increment()
            return OnDeviceTranslationDriver(
                translate: { requests in successfulResults(for: requests) },
                cancel: {}
            )
        }
    )

    do {
        _ = try await transport.translate(
            requests: [request(id: "1", text: "Hello", source: .automatic)],
            sourceLanguage: .automatic,
            targetLanguage: japanese
        )
        Issue.record("Expected automatic source policy to be rejected.")
    } catch let failure as TranslationFailure {
        #expect(failure == .automaticSourceLanguageUnavailable)
    }
    #expect(driverCount.value == 0)
}

@available(iOS 26.0, macOS 26.0, *)
@Test func mixedOnDeviceSourcesFailBeforeResolvingTransport() async throws {
    let transportCount = CountProbe()
    let client = TranslationClient(
        transportFactory: TranslationTransportFactory { _ in
            transportCount.increment()
            return TranslationTransport(translate: { requests, _, _ in
                successfulResults(for: requests)
            })
        }
    )
    let error = await terminalError(
        from: client.translations(
            for: [
                request(id: "known", text: "Hello"),
                request(id: "automatic", text: "Bonjour", source: .automatic),
            ],
            to: japanese,
            using: .onDevice
        )
    )

    #expect(error as? TranslationFailure == .automaticSourceLanguageUnavailable)
    #expect(transportCount.value == 0)
}

private final class OnDeviceCancellationProbe: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var startedWaiter: CheckedContinuation<Void, Never>?
        var started = false
        var cancellationFinished = false
    }

    private let state = Mutex(State())

    func translate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = state.withLock { state in
                state.continuation = continuation
                state.started = true
                defer { state.startedWaiter = nil }
                return state.startedWaiter
            }
            waiter?.resume()
        }
    }

    func cancel() async {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: CancellationError())
        await Task.yield()
        state.withLock { $0.cancellationFinished = true }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard !state.started else { return true }
                state.startedWaiter = continuation
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    var didFinishCancellation: Bool {
        state.withLock { $0.cancellationFinished }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDeviceCancellationAwaitsSessionDriverCancellation() async throws {
    let probe = OnDeviceCancellationProbe()
    let transport = OnDeviceTranslationTransport(
        driverFactory: OnDeviceTranslationDriverFactory { _, _ in
            OnDeviceTranslationDriver(
                translate: { _ in
                    try await probe.translate()
                    return []
                },
                cancel: {
                    await probe.cancel()
                }
            )
        }
    )
    let task = Task {
        try await transport.translate(
            requests: [request(id: "1", text: "Hello")],
            sourceLanguage: known(english),
            targetLanguage: japanese
        )
    }

    await probe.waitUntilStarted()
    task.cancel()
    let result = await task.result
    switch result {
    case .success:
        Issue.record("Cancelled on-device translation unexpectedly succeeded.")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    #expect(probe.didFinishCancellation)
}
