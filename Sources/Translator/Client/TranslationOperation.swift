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
    private let provider: TranslationProvider
    private let cache: TranslationCache
    private let transportFactory: TranslationTransportFactory

    init(
        requests: [TranslationRequest],
        targetLanguage: TranslationLanguage,
        provider: TranslationProvider,
        cache: TranslationCache,
        transportFactory: TranslationTransportFactory
    ) {
        self.requests = requests
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.cache = cache
        self.transportFactory = transportFactory
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
        do {
            try Task.checkCancellation()
            try provider.validate(
                sourceLanguages: misses.map(\.request.sourceLanguage)
            )
            let transport = transportFactory.transport(provider)
            let groups = Dictionary(grouping: misses, by: { $0.request.sourceLanguage })

            let unorderedResults: [TranslationTransportResult]
            do {
                unorderedResults = try await withThrowingTaskGroup(
                    of: [TranslationTransportResult].self,
                    returning: [TranslationTransportResult].self
                ) { group in
                    for (sourceLanguage, groupMisses) in groups {
                        group.addTask {
                            let groupRequests = groupMisses.map(\.request)
                            let results = try await transport.translate(
                                groupRequests,
                                sourceLanguage,
                                targetLanguage
                            )
                            try Task.checkCancellation()
                            _ = try TranslationResponseMembership.validateAndOrder(
                                results,
                                expectedIdentifiers: groupRequests.map(\.id)
                            )
                            return results
                        }
                    }

                    var results: [TranslationTransportResult] = []
                    results.reserveCapacity(misses.count)
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
            } catch {
                await transport.finish()
                throw error
            }
            await transport.finish()

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
            let results = orderedResults.map {
                TranslationResult(
                    requestID: $0.requestID,
                    translatedText: $0.translatedText
                )
            }

            // This cache write is the operation's commit point. Do not observe cancellation after
            // it: reporting cancellation after committed results would make cancellation semantics
            // disagree with the cache state.
            try await cache.store(cacheValues)
            return results
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TranslationFailure {
            throw failure
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TranslationFailure.transport
        }
    }

    private static func validateUniqueRequestIDs(_ requests: [TranslationRequest]) throws {
        let duplicateCount = requests.count - Set(requests.map(\.id)).count
        guard duplicateCount == 0 else {
            throw TranslationFailure.duplicateRequestIdentifiers(count: duplicateCount)
        }
    }
}
