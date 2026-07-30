/// A translated string correlated to its originating request.
public struct TranslationResult: Hashable, Sendable {
    public let requestID: String
    public let translatedText: String

    public init(requestID: String, translatedText: String) {
        self.requestID = requestID
        self.translatedText = translatedText
    }
}
