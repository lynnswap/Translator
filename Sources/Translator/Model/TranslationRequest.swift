/// A single piece of source text and its correlation identifier.
///
/// `id` correlates a result with this request. It does not participate in cache identity.
public struct TranslationRequest: Hashable, Sendable {
    public let id: String
    public let text: String
    public let sourceLanguage: TranslationSourceLanguage

    public init(
        id: String,
        text: String,
        sourceLanguage: TranslationSourceLanguage
    ) {
        self.id = id
        self.text = text
        self.sourceLanguage = sourceLanguage
    }
}
