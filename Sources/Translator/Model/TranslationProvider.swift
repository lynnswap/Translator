/// A translation implementation and the configuration that defines its semantic identity.
///
/// Equality and hashing must include every configuration value that can affect translated output,
/// and that identity must remain stable while the provider is used with a ``TranslationClient``.
///
/// ``TranslationClient`` calls ``translate(_:to:)`` once with the operation's complete cache-miss
/// batch. Implementations own any source-language grouping and must return exactly one result for
/// every request identifier. Result order is not significant because the client validates
/// membership and restores input order. A client may use the same provider concurrently in separate
/// operations.
///
/// For cache correctness, each translated value may depend only on that request's text and source
/// language, the target language, and the provider's semantic identity. It must not depend on the
/// request identifier or on the membership or order of the surrounding batch.
///
/// Cancellation is complete only after provider-owned work and resources have reached quiescence.
/// A cancelled call must not return or throw until that cleanup has finished. The client reports
/// caller cancellation as `CancellationError`, regardless of the provider's underlying error.
public protocol TranslationProvider: Hashable, Sendable {
    /// Translates one operation's complete cache-miss batch.
    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult]
}

struct AnyTranslationProvider: Hashable, Sendable {
    private let box: any TranslationProviderBox

    init(_ provider: some TranslationProvider) {
        self.box = ConcreteTranslationProviderBox(provider)
    }

    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        try await box.translate(requests, to: targetLanguage)
    }

    static func == (lhs: AnyTranslationProvider, rhs: AnyTranslationProvider) -> Bool {
        lhs.box.isEqual(to: rhs.box)
    }

    func hash(into hasher: inout Hasher) {
        box.hash(into: &hasher)
    }
}

private protocol TranslationProviderBox: Sendable {
    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult]

    func isEqual(to other: any TranslationProviderBox) -> Bool
    func hash(into hasher: inout Hasher)
}

private struct ConcreteTranslationProviderBox<Provider: TranslationProvider>:
    TranslationProviderBox
{
    let provider: Provider

    init(_ provider: Provider) {
        self.provider = provider
    }

    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        try await provider.translate(requests, to: targetLanguage)
    }

    func isEqual(to other: any TranslationProviderBox) -> Bool {
        guard let other = other as? Self else { return false }
        return provider == other.provider
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(Provider.self))
        provider.hash(into: &hasher)
    }
}
