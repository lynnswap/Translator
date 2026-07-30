/// A translation client with an isolated, per-instance memory cache.
public final class TranslationClient: Sendable {
    private let cache: TranslationCache

    public init() {
        self.cache = TranslationCache()
    }

    /// Creates a cold sequence that translates `requests` into `targetLanguage`.
    ///
    /// Iteration yields cached results first in input order. If any requests miss the cache,
    /// the next element contains all fresh results in input order after the provider's complete
    /// result membership has been validated. Client and on-device failures are reported as
    /// ``TranslationFailure``. Custom provider errors pass through unchanged unless the caller task
    /// is cancelled, in which case iteration terminates as `CancellationError`.
    public func translations(
        for requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage,
        using provider: some TranslationProvider
    ) -> TranslationResults {
        TranslationResults(
            operation: TranslationOperation(
                requests: requests,
                targetLanguage: targetLanguage,
                provider: AnyTranslationProvider(provider),
                cache: cache
            )
        )
    }
}
