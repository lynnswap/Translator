/// A translation client with an isolated, per-instance memory cache.
public final class TranslationClient: Sendable {
    private let cache: TranslationCache
    private let transportFactory: TranslationTransportFactory

    public init() {
        self.cache = TranslationCache()
        self.transportFactory = .live
    }

    init(
        cache: TranslationCache = TranslationCache(),
        transportFactory: TranslationTransportFactory
    ) {
        self.cache = cache
        self.transportFactory = transportFactory
    }

    /// Creates a cold sequence that translates `requests` into `targetLanguage`.
    ///
    /// Iteration yields cached results first in input order. If any requests miss the cache,
    /// the next element contains all fresh results in input order after the provider's complete
    /// result membership has been validated. A non-cancellation failure terminates iteration as
    /// `TranslationFailure`; cancellation terminates it as `CancellationError`.
    public func translations(
        for requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage,
        using provider: TranslationProvider
    ) -> TranslationResults {
        TranslationResults(
            operation: TranslationOperation(
                requests: requests,
                targetLanguage: targetLanguage,
                provider: provider,
                cache: cache,
                transportFactory: transportFactory
            )
        )
    }
}
