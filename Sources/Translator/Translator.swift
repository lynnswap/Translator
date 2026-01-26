import Foundation

public struct TranslationRequest: Hashable, Sendable {
    /// A stable identifier used for caching.
    /// The cache key is (id, targetLanguage), so id must uniquely represent the source text and source language.
    public let id: String
    public let text: String
    public let sourceLanguage: String

    public init(
        id: String,
        text: String,
        sourceLanguage: String
    ) {
        self.id = id
        self.text = text
        self.sourceLanguage = sourceLanguage
    }
}

public struct TranslationUpdate: Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}


public final class Translator: Sendable {
    public static let shared = Translator()

    private let cache: TranslationMemoryCache

    public init(cache: TranslationMemoryCache = TranslationMemoryCache()) {
        self.cache = cache
    }
    public func translateStream(
        requests: [TranslationRequest],
        targetLanguage: String,
        service: any TranslationService
    ) -> AsyncThrowingStream<[TranslationUpdate], Error> {
        if requests.isEmpty {
            return AsyncThrowingStream { $0.finish() }
        }

        let cache = self.cache
        return AsyncThrowingStream { continuation in
            let driver = Task.detached {
                do {
                    var requestIds: [String] = []
                    requestIds.reserveCapacity(requests.count)
                    for request in requests {
                        requestIds.append(request.id)
                    }
                    let cachedMap = cache.getMany(requestIds, targetLanguage: targetLanguage)
                    var cachedHits: [TranslationUpdate] = []
                    var miss: [TranslationRequest] = []
                    cachedHits.reserveCapacity(requests.count)
                    miss.reserveCapacity(requests.count)
                    for request in requests {
                        if let cached = cachedMap[request.id] {
                            cachedHits.append(.init(id: request.id, text: cached))
                        } else {
                            miss.append(request)
                        }
                    }
                    if !cachedHits.isEmpty {
                        continuation.yield(cachedHits)
                    }
                    if miss.isEmpty {
                        continuation.finish()
                        return
                    }

                    let stream = service.translateStream(
                        requests: miss,
                        targetLanguage: targetLanguage
                    )
                    for try await updates in stream {
                        if updates.isEmpty { continue }
                        var dict: [String: String] = [:]
                        dict.reserveCapacity(updates.count)
                        for update in updates {
                            dict[update.id] = update.text
                        }
                        cache.setMany(dict, targetLanguage: targetLanguage)
                        continuation.yield(updates)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in driver.cancel() }
        }
    }

    #if canImport(Translation)
    @available(iOS 26.0, macOS 26.0, *)
    public func translateStream(
        requests: [TranslationRequest],
        targetLanguage: String
    ) -> AsyncThrowingStream<[TranslationUpdate], Error> {
        translateStream(
            requests: requests,
            targetLanguage: targetLanguage,
            service: AppleTranslationService()
        )
    }
    #endif

    public func clearCache() async {
        cache.removeAll()
    }

    public func invalidate(id: String, targetLanguage: String) async {
        cache.remove(id: id, targetLanguage: targetLanguage)
    }
}
