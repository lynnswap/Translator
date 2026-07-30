struct TranslationOperation: Sendable {
    struct Miss: Sendable {
        let request: TranslationRequest
        let cacheKey: TranslationCache.Key
    }

    struct Prepared: Sendable {
        let cachedResults: [TranslationResult]
        let misses: [Miss]
    }

    private let requests: [TranslationRequest]
    private let targetLanguage: TranslationLanguage
    private let provider: AnyTranslationProvider
    private let cache: TranslationCache

    init(
        requests: [TranslationRequest],
        targetLanguage: TranslationLanguage,
        provider: AnyTranslationProvider,
        cache: TranslationCache
    ) {
        self.requests = requests
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.cache = cache
    }

    func prepare() async throws -> Prepared {
        try Task.checkCancellation()
        try Self.validateUniqueRequestIDs(requests)

        let keyedRequests = requests.map { request in
            (
                request,
                TranslationCache.Key(
                    text: request.text,
                    sourceLanguage: request.sourceLanguage,
                    targetLanguage: targetLanguage,
                    provider: provider
                )
            )
        }
        let cachedValues = try await cache.values(for: keyedRequests.map(\.1))
        try Task.checkCancellation()

        var cachedResults: [TranslationResult] = []
        var misses: [Miss] = []
        cachedResults.reserveCapacity(requests.count)
        misses.reserveCapacity(requests.count)
        for (request, key) in keyedRequests {
            if let translatedText = cachedValues[key] {
                cachedResults.append(
                    TranslationResult(
                        requestID: request.id,
                        translatedText: translatedText
                    )
                )
            } else {
                misses.append(Miss(request: request, cacheKey: key))
            }
        }
        return Prepared(cachedResults: cachedResults, misses: misses)
    }

    func translate(_ misses: [Miss]) async throws -> [TranslationResult] {
        try Task.checkCancellation()
        let unorderedResults: [TranslationResult]
        do {
            unorderedResults = try await provider.translate(
                misses.map(\.request),
                to: targetLanguage
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            throw error
        }

        try Task.checkCancellation()
        let orderedResults = try TranslationResponseMembership.validateAndOrder(
            unorderedResults,
            expectedIdentifiers: misses.map(\.request.id)
        )
        let keysByRequestID = Dictionary(
            uniqueKeysWithValues: misses.map { ($0.request.id, $0.cacheKey) }
        )
        let cacheValues = orderedResults.map { result in
            guard let key = keysByRequestID[result.requestID] else {
                preconditionFailure("Validated results must have an originating cache key.")
            }
            return (key: key, translatedText: result.translatedText)
        }

        // This cache write is the operation's commit point. Do not observe cancellation after
        // it: reporting cancellation after committed results would make cancellation semantics
        // disagree with the cache state.
        try await cache.store(cacheValues)
        return orderedResults
    }

    private static func validateUniqueRequestIDs(_ requests: [TranslationRequest]) throws {
        let duplicateCount = requests.count - Set(requests.map(\.id)).count
        guard duplicateCount == 0 else {
            throw TranslationFailure.duplicateRequestIdentifiers(count: duplicateCount)
        }
    }
}
