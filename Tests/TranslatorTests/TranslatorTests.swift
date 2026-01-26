import Synchronization
import Testing
@testable import Translator

private struct StubTranslationService: TranslationService, Sendable {
    let handler: @Sendable ([TranslationRequest], String) -> AsyncThrowingStream<[TranslationUpdate], Error>

    func translateStream(
        requests: [TranslationRequest],
        targetLanguage: String
    ) -> AsyncThrowingStream<[TranslationUpdate], Error> {
        handler(requests, targetLanguage)
    }
}

private final class ServiceRecorder: @unchecked Sendable {
    // Guarded by lock.
    struct Call: Sendable {
        var count = 0
        var requests: [TranslationRequest] = []
        var targetLanguage = ""
    }

    private let lock = Mutex(Call())

    func record(requests: [TranslationRequest], targetLanguage: String) {
        lock.withLock { call in
            call.count += 1
            call.requests = requests
            call.targetLanguage = targetLanguage
        }
    }

    func snapshot() -> Call {
        lock.withLock { $0 }
    }
}

private enum TestError: Error, Equatable {
    case sample
}

private func collectBatches(
    _ stream: AsyncThrowingStream<[TranslationUpdate], Error>
) async throws -> [[TranslationUpdate]] {
    var batches: [[TranslationUpdate]] = []
    for try await batch in stream {
        batches.append(batch)
    }
    return batches
}

private func makeStream(
    _ batches: [[TranslationUpdate]]
) -> AsyncThrowingStream<[TranslationUpdate], Error> {
    AsyncThrowingStream { continuation in
        for batch in batches {
            continuation.yield(batch)
        }
        continuation.finish()
    }
}

private func makeErrorStream(
    _ error: Error
) -> AsyncThrowingStream<[TranslationUpdate], Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
    }
}

private final class TerminationProbe: @unchecked Sendable {
    private let lock = Mutex(false)

    func markTerminated() {
        lock.withLock { $0 = true }
    }

    func isTerminated() -> Bool {
        lock.withLock { $0 }
    }
}

private func makeHangingStream(
    _ probe: TerminationProbe
) -> AsyncThrowingStream<[TranslationUpdate], Error> {
    AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in
            probe.markTerminated()
        }
    }
}

private func waitForTermination(
    _ probe: TerminationProbe
) async -> Bool {
    for _ in 0..<10 {
        if probe.isTerminated() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return probe.isTerminated()
}

@Test func translateStream_emptyRequestsDoesNotCallService() async throws {
    let recorder = ServiceRecorder()
    let service = StubTranslationService { requests, targetLanguage in
        recorder.record(requests: requests, targetLanguage: targetLanguage)
        return makeStream([])
    }
    let translator = Translator(cache: TranslationMemoryCache())

    let batches = try await collectBatches(
        translator.translateStream(requests: [], targetLanguage: "en", service: service)
    )

    #expect(batches.isEmpty)
    #expect(recorder.snapshot().count == 0)
}

@Test func translateStream_allCachedSkipsService() async throws {
    let cache = TranslationMemoryCache()
    cache.setMany(["1": "cached-1", "2": "cached-2"], targetLanguage: "en")
    let recorder = ServiceRecorder()
    let service = StubTranslationService { requests, targetLanguage in
        recorder.record(requests: requests, targetLanguage: targetLanguage)
        return makeStream([[TranslationUpdate(id: "x", text: "unused")]])
    }
    let translator = Translator(cache: cache)
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en"),
        TranslationRequest(id: "2", text: "hola", sourceLanguage: "es")
    ]

    let batches = try await collectBatches(
        translator.translateStream(requests: requests, targetLanguage: "en", service: service)
    )

    #expect(batches.count == 1)
    #expect(batches[0].map(\.id) == ["1", "2"])
    #expect(batches[0].map(\.text) == ["cached-1", "cached-2"])
    #expect(recorder.snapshot().count == 0)
}

@Test func translateStream_ignoresCacheForOtherTargetLanguage() async throws {
    let cache = TranslationMemoryCache()
    cache.setMany(["1": "cached-en"], targetLanguage: "en")
    let recorder = ServiceRecorder()
    let service = StubTranslationService { requests, targetLanguage in
        recorder.record(requests: requests, targetLanguage: targetLanguage)
        return makeStream([[TranslationUpdate(id: "1", text: "translated-es")]])
    }
    let translator = Translator(cache: cache)
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en")
    ]

    let batches = try await collectBatches(
        translator.translateStream(requests: requests, targetLanguage: "es", service: service)
    )

    #expect(batches.count == 1)
    #expect(batches[0].map(\.text) == ["translated-es"])
    #expect(recorder.snapshot().requests.map(\.id) == ["1"])
    #expect(recorder.snapshot().targetLanguage == "es")
    #expect(cache.get(id: "1", targetLanguage: "en") == "cached-en")
    #expect(cache.get(id: "1", targetLanguage: "es") == "translated-es")
}

@Test func translateStream_yieldsCachedThenServiceUpdates() async throws {
    let cache = TranslationMemoryCache()
    cache.setMany(["1": "cached"], targetLanguage: "en")
    let recorder = ServiceRecorder()
    let service = StubTranslationService { requests, targetLanguage in
        recorder.record(requests: requests, targetLanguage: targetLanguage)
        return makeStream([
            [TranslationUpdate(id: "2", text: "translated")]
        ])
    }
    let translator = Translator(cache: cache)
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en"),
        TranslationRequest(id: "2", text: "hola", sourceLanguage: "es")
    ]

    let batches = try await collectBatches(
        translator.translateStream(requests: requests, targetLanguage: "en", service: service)
    )

    #expect(batches.count == 2)
    #expect(batches[0].map(\.id) == ["1"])
    #expect(batches[0].map(\.text) == ["cached"])
    #expect(batches[1].map(\.id) == ["2"])
    #expect(batches[1].map(\.text) == ["translated"])
    #expect(recorder.snapshot().requests.map(\.id) == ["2"])
    #expect(recorder.snapshot().targetLanguage == "en")
}

@Test func translateStream_cachesServiceUpdates() async throws {
    let cache = TranslationMemoryCache()
    let service = StubTranslationService { _, _ in
        makeStream([[TranslationUpdate(id: "1", text: "cached")]])
    }
    let translator = Translator(cache: cache)
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en")
    ]

    _ = try await collectBatches(
        translator.translateStream(requests: requests, targetLanguage: "en", service: service)
    )

    #expect(cache.get(id: "1", targetLanguage: "en") == "cached")
}

@Test func translateStream_skipsEmptyBatches() async throws {
    let service = StubTranslationService { _, _ in
        makeStream([
            [],
            [TranslationUpdate(id: "1", text: "translated")]
        ])
    }
    let translator = Translator(cache: TranslationMemoryCache())
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en")
    ]

    let batches = try await collectBatches(
        translator.translateStream(requests: requests, targetLanguage: "en", service: service)
    )

    #expect(batches.count == 1)
    #expect(batches[0].map(\.id) == ["1"])
    #expect(batches[0].map(\.text) == ["translated"])
}

@Test func translateStream_propagatesServiceError() async {
    let service = StubTranslationService { _, _ in
        makeErrorStream(TestError.sample)
    }
    let translator = Translator(cache: TranslationMemoryCache())
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en")
    ]

    do {
        _ = try await collectBatches(
            translator.translateStream(requests: requests, targetLanguage: "en", service: service)
        )
        #expect(Bool(false))
    } catch let error as TestError {
        #expect(error == .sample)
    } catch {
        #expect(Bool(false))
    }
}

@Test func clearCache_removesAllEntries() async {
    let cache = TranslationMemoryCache()
    cache.setMany(["1": "cached"], targetLanguage: "en")
    let translator = Translator(cache: cache)

    await translator.clearCache()

    #expect(cache.get(id: "1", targetLanguage: "en") == nil)
}

@Test func invalidate_removesEntryForTargetLanguage() async {
    let cache = TranslationMemoryCache()
    cache.setMany(["1": "cached-en"], targetLanguage: "en")
    cache.setMany(["1": "cached-es"], targetLanguage: "es")
    let translator = Translator(cache: cache)

    await translator.invalidate(id: "1", targetLanguage: "en")

    #expect(cache.get(id: "1", targetLanguage: "en") == nil)
    #expect(cache.get(id: "1", targetLanguage: "es") == "cached-es")
}

@Test func translateStream_cancelsDriverOnTermination() async {
    let probe = TerminationProbe()
    let service = StubTranslationService { _, _ in
        makeHangingStream(probe)
    }
    let translator = Translator(cache: TranslationMemoryCache())
    let requests = [
        TranslationRequest(id: "1", text: "hello", sourceLanguage: "en")
    ]

    let task = Task {
        do {
            for try await _ in translator.translateStream(
                requests: requests,
                targetLanguage: "en",
                service: service
            ) {}
        } catch {
        }
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    _ = await task.result

    let terminated = await waitForTermination(probe)
    #expect(terminated)
}
