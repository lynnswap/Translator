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
    let targetLanguage: TranslationLanguage
}

private actor ProviderRecorder {
    private var calls: [RecordedCall] = []

    func record(
        requests: [TranslationRequest],
        targetLanguage: TranslationLanguage
    ) {
        calls.append(
            RecordedCall(
                requests: requests,
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

private struct TestProvider: TranslationProvider {
    let identity: String
    let recorder: ProviderRecorder
    let handler: @Sendable (
        [TranslationRequest],
        TranslationLanguage
    ) async throws -> [TranslationResult]

    static func == (lhs: TestProvider, rhs: TestProvider) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        await recorder.record(
            requests: requests,
            targetLanguage: targetLanguage
        )
        return try await handler(requests, targetLanguage)
    }
}

private struct AlternateTestProvider: TranslationProvider {
    let base: TestProvider

    static func == (lhs: AlternateTestProvider, rhs: AlternateTestProvider) -> Bool {
        lhs.base.identity == rhs.base.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(base.identity)
    }

    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        try await base.translate(requests, to: targetLanguage)
    }
}

private func makeProvider(
    identity: String = "provider",
    handler: @escaping @Sendable (
        [TranslationRequest],
        TranslationLanguage
    ) async throws -> [TranslationResult]
) -> (provider: TestProvider, recorder: ProviderRecorder) {
    let recorder = ProviderRecorder()
    return (
        TestProvider(
            identity: identity,
            recorder: recorder,
            handler: handler
        ),
        recorder
    )
}

private func successfulResults(
    for requests: [TranslationRequest]
) -> [TranslationResult] {
    requests.map {
        TranslationResult(
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

@Test func providerErasurePreservesSemanticIdentityAndConcreteType() {
    let recorder = ProviderRecorder()
    let handler: @Sendable (
        [TranslationRequest],
        TranslationLanguage
    ) async throws -> [TranslationResult] = { requests, _ in
        successfulResults(for: requests)
    }
    let concrete = TestProvider(
        identity: "same",
        recorder: recorder,
        handler: handler
    )
    let equivalent = TestProvider(
        identity: "same",
        recorder: ProviderRecorder(),
        handler: handler
    )
    let differentConfiguration = TestProvider(
        identity: "different",
        recorder: recorder,
        handler: handler
    )
    let differentType = AlternateTestProvider(base: equivalent)
    let existential: any TranslationProvider = concrete

    let erased = AnyTranslationProvider(concrete)
    #expect(erased == AnyTranslationProvider(equivalent))
    #expect(erased == AnyTranslationProvider(existential))
    #expect(erased != AnyTranslationProvider(differentConfiguration))
    #expect(erased != AnyTranslationProvider(differentType))
    #expect(
        Set([
            erased,
            AnyTranslationProvider(equivalent),
            AnyTranslationProvider(differentConfiguration),
            AnyTranslationProvider(differentType),
        ]).count == 3
    )
}

@Test func sequenceIsColdAndEachIteratorHasIndependentState() async throws {
    let callCount = CountProbe()
    let (provider, _) = makeProvider { requests, _ in
        callCount.increment()
        return successfulResults(for: requests)
    }
    let client = TranslationClient()
    let sequence = client.translations(
        for: [request(id: "first", text: "Hello")],
        to: japanese,
        using: provider
    )

    #expect(callCount.value == 0)

    var firstIterator = sequence.makeAsyncIterator()
    var secondIterator = sequence.makeAsyncIterator()
    #expect(try await firstIterator.next()?.map(\.requestID) == ["first"])
    #expect(try await firstIterator.next() == nil)
    #expect(try await secondIterator.next()?.map(\.requestID) == ["first"])
    #expect(try await secondIterator.next() == nil)
    #expect(callCount.value == 1)
}

@Test func emptyInputFinishesWithoutCallingProvider() async throws {
    let callCount = CountProbe()
    let (provider, _) = makeProvider { requests, _ in
        callCount.increment()
        return successfulResults(for: requests)
    }

    let batches = try await collect(
        TranslationClient().translations(
            for: [],
            to: japanese,
            using: provider
        )
    )
    #expect(batches.isEmpty)
    #expect(callCount.value == 0)
}

@Test func clientAliasesShareCacheButSeparateClientsDoNot() async throws {
    let callCount = CountProbe()
    let (provider, _) = makeProvider { requests, _ in
        callCount.increment()
        return successfulResults(for: requests)
    }
    let firstClient = TranslationClient()
    let alias = firstClient
    let secondClient = TranslationClient()

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
    let (provider, recorder) = makeProvider { requests, _ in
        successfulResults(for: requests)
    }
    let client = TranslationClient()

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

@Test func cacheSeparatesTextSourceTargetProviderConfigurationAndType() async throws {
    let callCount = CountProbe()
    let handler: @Sendable (
        [TranslationRequest],
        TranslationLanguage
    ) async throws -> [TranslationResult] = { requests, _ in
        callCount.increment()
        return successfulResults(for: requests)
    }
    let providerA = TestProvider(
        identity: "A",
        recorder: ProviderRecorder(),
        handler: handler
    )
    let equivalentProviderA = TestProvider(
        identity: "A",
        recorder: ProviderRecorder(),
        handler: handler
    )
    let providerB = TestProvider(
        identity: "B",
        recorder: ProviderRecorder(),
        handler: handler
    )
    let alternateProviderA = AlternateTestProvider(
        base: TestProvider(
            identity: "A",
            recorder: ProviderRecorder(),
            handler: handler
        )
    )
    let client = TranslationClient()

    func translate(
        id: String,
        text: String = "Hello",
        source: TranslationSourceLanguage = known(english),
        target: TranslationLanguage = japanese,
        provider: some TranslationProvider
    ) async throws {
        _ = try await collect(
            client.translations(
                for: [request(id: id, text: text, source: source)],
                to: target,
                using: provider
            )
        )
    }

    try await translate(id: "base", provider: providerA)
    try await translate(id: "correlation", provider: equivalentProviderA)
    try await translate(id: "automatic", source: .automatic, provider: providerA)
    try await translate(id: "source", source: known(french), provider: providerA)
    try await translate(id: "target", target: english, provider: providerA)
    try await translate(id: "configuration", provider: providerB)
    try await translate(id: "type", provider: alternateProviderA)
    try await translate(id: "text", text: "Hello!", provider: providerA)

    #expect(callCount.value == 7)
}

@Test func clientPassesOneCompleteMixedSourceBatchAndOrdersFreshResults() async throws {
    let (provider, recorder) = makeProvider { requests, _ in
        Array(successfulResults(for: requests).reversed())
    }
    let requests = [
        request(id: "1", text: "one"),
        request(id: "2", text: "deux", source: known(french)),
        request(id: "3", text: "unknown", source: .automatic),
        request(id: "4", text: "three"),
    ]

    let batches = try await collect(
        TranslationClient().translations(
            for: requests,
            to: japanese,
            using: provider
        )
    )
    let calls = await recorder.snapshot()

    #expect(batches.count == 1)
    #expect(batches[0].map(\.requestID) == ["1", "2", "3", "4"])
    #expect(calls.count == 1)
    #expect(calls[0].requests.map(\.id) == ["1", "2", "3", "4"])
    #expect(calls[0].targetLanguage == japanese)
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
    let (provider, _) = makeProvider { requests, _ in
        switch scenario {
        case .unknown:
            [
                TranslationResult(requestID: requests[0].id, translatedText: "one"),
                TranslationResult(requestID: "provider-token", translatedText: "unknown"),
            ]
        case .duplicate:
            [
                TranslationResult(requestID: requests[0].id, translatedText: "one"),
                TranslationResult(requestID: requests[0].id, translatedText: "again"),
                TranslationResult(requestID: requests[1].id, translatedText: "two"),
            ]
        case .missing:
            [TranslationResult(requestID: requests[0].id, translatedText: "one")]
        }
    }
    let error = await terminalError(
        from: TranslationClient().translations(
            for: [
                request(id: "private-first", text: "one"),
                request(id: "private-second", text: "two"),
            ],
            to: japanese,
            using: provider
        )
    )

    let failure = try #require(error as? TranslationFailure)
    #expect(failure == scenario.expectedFailure)
    #expect(!(failure.errorDescription ?? "").contains("private-first"))
    #expect(!(failure.errorDescription ?? "").contains("provider-token"))
}

@Test func membershipFailureRollsBackBeforeCacheCommit() async throws {
    let attempt = CountProbe()
    let (provider, _) = makeProvider { requests, _ in
        attempt.increment()
        if attempt.value == 1 {
            return [TranslationResult(requestID: "unknown", translatedText: "invalid")]
        }
        return successfulResults(for: requests)
    }
    let client = TranslationClient()

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

@Test func duplicateInputIdentifiersAreRedactedAndStopBeforeProvider() async throws {
    let (provider, recorder) = makeProvider { requests, _ in
        successfulResults(for: requests)
    }
    let error = await terminalError(
        from: TranslationClient().translations(
            for: [
                request(id: "private-duplicate", text: "one"),
                request(id: "private-duplicate", text: "two"),
            ],
            to: japanese,
            using: provider
        )
    )

    let failure = try #require(error as? TranslationFailure)
    #expect(failure == .duplicateRequestIdentifiers(count: 1))
    #expect(!(failure.errorDescription ?? "").contains("private-duplicate"))
    #expect(await recorder.snapshot().isEmpty)
}

private enum TestProviderError: Error, Equatable {
    case unavailable
}

@Test func customProviderErrorsPropagateUnchanged() async throws {
    let (provider, _) = makeProvider { _, _ in
        throw TestProviderError.unavailable
    }
    let error = await terminalError(
        from: TranslationClient().translations(
            for: [request(id: "1", text: "one")],
            to: japanese,
            using: provider
        )
    )

    #expect(error as? TestProviderError == .unavailable)
}

private final class DomainErrorCancellationProbe: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var cancellationRequested = false
        var started = false
        var startedWaiters: [CheckedContinuation<Void, Never>] = []
        var cleanupFinished = false
    }

    private let state = Mutex(State())

    func run() async throws -> [TranslationResult] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (wasAlreadyCancelled, waiters) = state.withLock { state in
                    state.started = true
                    defer { state.startedWaiters.removeAll() }
                    if state.cancellationRequested {
                        return (true, state.startedWaiters)
                    }
                    state.continuation = continuation
                    return (false, state.startedWaiters)
                }
                for waiter in waiters {
                    waiter.resume()
                }
                if wasAlreadyCancelled {
                    continuation.resume()
                }
            }
        } onCancel: {
            requestCancellation()
        }

        await Task.yield()
        state.withLock { $0.cleanupFinished = true }
        throw TestProviderError.unavailable
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard !state.started else { return true }
                state.startedWaiters.append(continuation)
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    private func requestCancellation() {
        let continuation = state.withLock { state in
            state.cancellationRequested = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }

    var didFinishCleanup: Bool {
        state.withLock { $0.cleanupFinished }
    }
}

@Test func cancelledProviderDomainErrorBecomesCancellationAfterCleanup() async throws {
    let probe = DomainErrorCancellationProbe()
    let (provider, _) = makeProvider { _, _ in
        try await probe.run()
    }
    let task = Task {
        try await collect(
            TranslationClient().translations(
                for: [request(id: "1", text: "one")],
                to: japanese,
                using: provider
            )
        )
    }

    await probe.waitUntilStarted()
    task.cancel()

    switch await task.result {
    case .success:
        Issue.record("Cancelled translation unexpectedly succeeded.")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    #expect(probe.didFinishCleanup)
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
        let result: (
            shouldSuspend: Bool,
            waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)]
        ) = state.withLock { state in
            state.callCount += 1
            if state.allowSuccess {
                return (false, [])
            }
            state.startedCount += 1
            let waiters = state.startedWaiters.filter { $0.count <= state.startedCount }
            state.startedWaiters.removeAll { $0.count <= state.startedCount }
            return (true, waiters)
        }
        for waiter in result.waiters {
            waiter.continuation.resume()
        }
        guard result.shouldSuspend else { return }

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

@Test func cancellationAwaitsProviderQuiescenceAndDoesNotPopulateCache() async throws {
    let probe = CancellationProbe()
    let (provider, recorder) = makeProvider { requests, _ in
        try await withThrowingTaskGroup(
            of: TranslationResult.self,
            returning: [TranslationResult].self
        ) { group in
            for request in requests {
                group.addTask {
                    try await probe.waitForCancellationIfNeeded(
                        id: request.id,
                        firstPhaseCount: 2
                    )
                    return TranslationResult(
                        requestID: request.id,
                        translatedText: "translated:\(request.text)"
                    )
                }
            }

            var results: [TranslationResult] = []
            do {
                for try await result in group {
                    results.append(result)
                }
            } catch {
                group.cancelAll()
                throw error
            }
            return results
        }
    }
    let client = TranslationClient()
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
    #expect(await recorder.snapshot().count == 2)
}

private final class PostProviderCancellationProbe: Sendable {
    private struct State {
        var callCount = 0
        var firstCallStarted = false
        var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseFirstCall: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func run(_ requests: [TranslationRequest]) async -> [TranslationResult] {
        let isFirstCall = state.withLock { state in
            state.callCount += 1
            return state.callCount == 1
        }
        if isFirstCall {
            await withCheckedContinuation { continuation in
                let waiters = state.withLock { state in
                    state.releaseFirstCall = continuation
                    state.firstCallStarted = true
                    defer { state.firstCallWaiters.removeAll() }
                    return state.firstCallWaiters
                }
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return successfulResults(for: requests)
    }

    func waitUntilFirstCallStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard !state.firstCallStarted else { return true }
                state.firstCallWaiters.append(continuation)
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = state.withLock { state in
            defer { state.releaseFirstCall = nil }
            return state.releaseFirstCall
        }
        continuation?.resume()
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }
}

@Test func providerSuccessAfterCancellationDoesNotReachCacheCommit() async throws {
    let probe = PostProviderCancellationProbe()
    let (provider, _) = makeProvider { requests, _ in
        await probe.run(requests)
    }
    let client = TranslationClient()
    let task = Task {
        try await collect(
            client.translations(
                for: [request(id: "first", text: "Hello")],
                to: japanese,
                using: provider
            )
        )
    }

    await probe.waitUntilFirstCallStarted()
    task.cancel()
    probe.release()

    switch await task.result {
    case .success:
        Issue.record("Cancelled translation unexpectedly reached the cache commit.")
    case .failure(let error):
        #expect(error is CancellationError)
    }

    let retry = try await collect(
        client.translations(
            for: [request(id: "second", text: "Hello")],
            to: japanese,
            using: provider
        )
    )
    #expect(retry.flatMap { $0 }.map(\.requestID) == ["second"])
    #expect(probe.callCount == 2)
}

@Test func concurrentOperationsShareCacheWithoutDataRaces() async throws {
    let (provider, recorder) = makeProvider { requests, _ in
        successfulResults(for: requests)
    }
    let client = TranslationClient()

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

private func cacheKey(_ text: String) -> TranslationCache.Key {
    let (provider, _) = makeProvider(identity: "cache") { requests, _ in
        successfulResults(for: requests)
    }
    return TranslationCache.Key(
        text: text,
        sourceLanguage: known(english),
        targetLanguage: japanese,
        provider: AnyTranslationProvider(provider)
    )
}

@Test func oversizedCacheStoreRetainsOnlyNewestUniqueEntries() async throws {
    let cache = TranslationCache(countLimit: 3)
    let first = cacheKey("first")
    let second = cacheKey("second")
    let third = cacheKey("third")
    let fourth = cacheKey("fourth")

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
    let keys = ["first", "second", "third", "fourth"].map(cacheKey)

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
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { _, _ in
            OnDeviceTranslationDriver(
                translate: { _ in throw scenario.error },
                cancel: {}
            )
        }
    )

    do {
        _ = try await provider.translate(
            [request(id: "1", text: "Hello")],
            to: japanese
        )
        Issue.record("Expected on-device translation to fail.")
    } catch let failure as TranslationFailure {
        #expect(failure == scenario.expectedFailure)
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDevicePreflightsAutomaticSourcesBeforeCreatingAnyDriver() async throws {
    let driverCount = CountProbe()
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { _, _ in
            driverCount.increment()
            return OnDeviceTranslationDriver(
                translate: { requests in successfulResults(for: requests) },
                cancel: {}
            )
        }
    )

    do {
        _ = try await provider.translate(
            [
                request(id: "known", text: "Hello"),
                request(id: "automatic", text: "Bonjour", source: .automatic),
            ],
            to: japanese
        )
        Issue.record("Expected automatic source policy to be rejected.")
    } catch let failure as TranslationFailure {
        #expect(failure == .automaticSourceLanguageUnavailable)
    }
    #expect(driverCount.value == 0)
}

@available(iOS 26.0, macOS 26.0, *)
private final class OnDeviceGroupingProbe: Sendable {
    struct Call: Sendable {
        let sourceLanguage: TranslationLanguage
        let targetLanguage: TranslationLanguage
        let requests: [TranslationRequest]
    }

    private let calls = Mutex<[Call]>([])

    func makeDriver(
        sourceLanguage: TranslationLanguage,
        targetLanguage: TranslationLanguage
    ) -> OnDeviceTranslationDriver {
        OnDeviceTranslationDriver(
            translate: { requests in
                self.calls.withLock {
                    $0.append(
                        Call(
                            sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage,
                            requests: requests
                        )
                    )
                }
                return Array(successfulResults(for: requests).reversed())
            },
            cancel: {}
        )
    }

    var snapshot: [Call] {
        calls.withLock { $0 }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDeviceGroupsExplicitSourcesInternallyAndClientOrdersResults() async throws {
    let probe = OnDeviceGroupingProbe()
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { source, target in
            probe.makeDriver(sourceLanguage: source, targetLanguage: target)
        }
    )
    let requests = [
        request(id: "english-1", text: "Hello"),
        request(id: "french", text: "Bonjour", source: known(french)),
        request(id: "english-2", text: "Welcome"),
    ]

    let batches = try await collect(
        TranslationClient().translations(
            for: requests,
            to: japanese,
            using: provider
        )
    )
    let calls = probe.snapshot

    #expect(batches.flatMap { $0 }.map(\.requestID) == requests.map(\.id))
    #expect(calls.count == 2)
    #expect(Set(calls.map(\.sourceLanguage)) == Set([english, french]))
    #expect(calls.allSatisfy { $0.targetLanguage == japanese })
    #expect(calls.allSatisfy { call in
        call.requests.allSatisfy {
            $0.sourceLanguage == .language(call.sourceLanguage)
        }
    })
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDeviceRejectsIdentifiersCrossingSourceGroups() async throws {
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { source, _ in
            OnDeviceTranslationDriver(
                translate: { _ in
                    let requestID = source == english ? "french" : "english"
                    return [
                        TranslationResult(
                            requestID: requestID,
                            translatedText: "wrong-source"
                        ),
                    ]
                },
                cancel: {}
            )
        }
    )

    do {
        _ = try await provider.translate(
            [
                request(id: "english", text: "Hello"),
                request(id: "french", text: "Bonjour", source: known(french)),
            ],
            to: japanese
        )
        Issue.record("Expected cross-source identifiers to be rejected.")
    } catch let failure as TranslationFailure {
        #expect(
            failure
                == .invalidResponseMembership(.unknownIdentifiers(count: 1))
        )
    }
}

private final class OnDeviceSiblingFailureProbe: Sendable {
    private struct State {
        var waitingDriverEntered = false
        var entryGate: CheckedContinuation<Void, Never>?
        var entryWaiters: [CheckedContinuation<Void, Never>] = []
        var cancellationRequested = false
        var cancellationFinished = false
    }

    private let state = Mutex(State())

    func runWaitingDriver() async throws {
        await withCheckedContinuation { continuation in
            let waiters = state.withLock { state in
                precondition(state.entryGate == nil)
                state.entryGate = continuation
                state.waitingDriverEntered = true
                defer { state.entryWaiters.removeAll() }
                return state.entryWaiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        let cancellationWasRequested = state.withLock { $0.cancellationRequested }
        precondition(cancellationWasRequested)
        throw CancellationError()
    }

    func waitUntilWaitingDriverEntered() async {
        await withCheckedContinuation { continuation in
            let alreadyEntered = state.withLock { state in
                guard !state.waitingDriverEntered else { return true }
                state.entryWaiters.append(continuation)
                return false
            }
            if alreadyEntered {
                continuation.resume()
            }
        }
    }

    func cancelWaitingDriver() async {
        let gate = state.withLock { state in
            state.cancellationRequested = true
            defer { state.entryGate = nil }
            return state.entryGate
        }
        gate?.resume()
        await Task.yield()
        state.withLock { $0.cancellationFinished = true }
    }

    var didFinishCancellation: Bool {
        state.withLock { $0.cancellationFinished }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test func onDeviceSiblingFailureAwaitsCancellationBeforeThrowing() async throws {
    let probe = OnDeviceSiblingFailureProbe()
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { source, _ in
            if source == english {
                return OnDeviceTranslationDriver(
                    translate: { _ in
                        try await probe.runWaitingDriver()
                        return []
                    },
                    cancel: {
                        await probe.cancelWaitingDriver()
                    }
                )
            }
            return OnDeviceTranslationDriver(
                translate: { _ in
                    await probe.waitUntilWaitingDriverEntered()
                    throw TranslationError.unsupportedTargetLanguage
                },
                cancel: {}
            )
        }
    )

    do {
        _ = try await provider.translate(
            [
                request(id: "english", text: "Hello"),
                request(id: "french", text: "Bonjour", source: known(french)),
            ],
            to: japanese
        )
        Issue.record("Expected one source driver to fail.")
    } catch let failure as TranslationFailure {
        #expect(failure == .unsupportedTargetLanguage)
    }
    #expect(probe.didFinishCancellation)
}

private final class OnDeviceCancellationProbe: Sendable {
    private struct State {
        var continuations: [String: CheckedContinuation<Void, any Error>] = [:]
        var cancelledBeforeStart: Set<String> = []
        var started: Set<String> = []
        var cancellationFinished: Set<String> = []
        var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func translate(id: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let (wasAlreadyCancelled, waiters) = state.withLock { state in
                state.started.insert(id)
                let waiters = state.startedWaiters.filter { $0.0 <= state.started.count }
                state.startedWaiters.removeAll { $0.0 <= state.started.count }
                if state.cancelledBeforeStart.remove(id) != nil {
                    return (true, waiters)
                }
                state.continuations[id] = continuation
                return (false, waiters)
            }
            for waiter in waiters {
                waiter.1.resume()
            }
            if wasAlreadyCancelled {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func cancel(id: String) async {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard let continuation = state.continuations.removeValue(forKey: id) else {
                state.cancelledBeforeStart.insert(id)
                return nil
            }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
        await Task.yield()
        state.withLock { state in
            _ = state.cancellationFinished.insert(id)
        }
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = state.withLock { state in
                guard state.started.count < count else { return true }
                state.startedWaiters.append((count, continuation))
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    var finishedCancellationCount: Int {
        state.withLock { $0.cancellationFinished.count }
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Test(arguments: 0..<16)
func onDeviceCancellationAwaitsEverySourceDriver(iteration: Int) async throws {
    let probe = OnDeviceCancellationProbe()
    let provider = OnDeviceTranslationProvider(
        driverFactory: OnDeviceTranslationDriverFactory { source, _ in
            OnDeviceTranslationDriver(
                translate: { requests in
                    try await probe.translate(id: source.identifier)
                    return successfulResults(for: requests)
                },
                cancel: {
                    await probe.cancel(id: source.identifier)
                }
            )
        }
    )
    let task = Task {
        try await provider.translate(
            [
                request(id: "english-\(iteration)", text: "Hello"),
                request(
                    id: "french-\(iteration)",
                    text: "Bonjour",
                    source: known(french)
                ),
            ],
            to: japanese
        )
    }

    await probe.waitUntilStarted(count: 2)
    task.cancel()
    let result = await task.result

    switch result {
    case .success:
        Issue.record("Cancelled on-device translation unexpectedly succeeded.")
    case .failure(let error):
        #expect(error is CancellationError)
    }
    #expect(probe.finishedCancellationCount == 2)
}

private final class CancellationCoordinatorProbe: Sendable {
    enum Event: Equatable, Sendable {
        case cleanupStarted
        case finishStarted
        case cleanupFinished
        case finishReturned
    }

    let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let cleanupRelease: AsyncStream<Void>
    private let cleanupReleaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (events, eventContinuation) = AsyncStream.makeStream()
        (cleanupRelease, cleanupReleaseContinuation) = AsyncStream.makeStream()
    }

    func runCleanup() async {
        eventContinuation.yield(.cleanupStarted)
        for await _ in cleanupRelease {
            break
        }
        eventContinuation.yield(.cleanupFinished)
    }

    func recordFinishStarted() {
        eventContinuation.yield(.finishStarted)
    }

    func releaseCleanup() {
        cleanupReleaseContinuation.yield()
        cleanupReleaseContinuation.finish()
    }

    func recordFinishReturned() {
        eventContinuation.yield(.finishReturned)
    }
}

@MainActor
@Test func cancellationCoordinatorAwaitsCleanupBeforeFinishing() async {
    let coordinator = OnDeviceCancellationCoordinator()
    let probe = CancellationCoordinatorProbe()
    var events = probe.events.makeAsyncIterator()

    #expect(
        coordinator.requestCancellation {
            await probe.runCleanup()
        }
    )
    #expect(await events.next() == .cleanupStarted)

    let finishTask = Task { @MainActor in
        probe.recordFinishStarted()
        await coordinator.finishOperation()
        probe.recordFinishReturned()
    }
    #expect(await events.next() == .finishStarted)
    probe.releaseCleanup()
    #expect(await events.next() == .cleanupFinished)
    #expect(await events.next() == .finishReturned)
    await finishTask.value
}

@Test func cancellationCoordinatorRejectsLateRequestAfterFinishing() async {
    let coordinator = OnDeviceCancellationCoordinator()

    await coordinator.finishOperation()

    #expect(!coordinator.requestCancellation {})
}
