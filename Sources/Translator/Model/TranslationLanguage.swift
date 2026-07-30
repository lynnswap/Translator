import Foundation

/// A validated, canonical BCP-47 language used by a translation provider.
public struct TranslationLanguage: Hashable, Sendable {
    /// The canonical BCP-47 identifier.
    public let identifier: String

    /// The Foundation language represented by this value.
    public var localeLanguage: Locale.Language {
        Locale.Language(identifier: identifier)
    }

    /// Creates a language by validating and canonicalizing an identifier.
    public init(identifier: String) throws {
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else {
            throw TranslationFailure.invalidLanguageIdentifier
        }

        let language = Locale.Language(identifier: identifier)
        try self.init(language)

        let canonicalInput = Locale.identifier(.bcp47, from: identifier)
        guard canonicalInput == self.identifier else {
            throw TranslationFailure.invalidLanguageIdentifier
        }
    }

    /// Creates a language from a Foundation language value.
    public init(_ language: Locale.Language) throws {
        guard let languageCode = language.languageCode,
              languageCode.isISOLanguage,
              languageCode != .unidentified,
              languageCode != .uncoded,
              languageCode != .unavailable else {
            throw TranslationFailure.invalidLanguageIdentifier
        }

        let components = [
            languageCode.identifier,
            language.script?.identifier,
            language.region?.identifier,
        ].compactMap { $0 }
        let identifier = Locale.identifier(.bcp47, from: components.joined(separator: "-"))
        guard !identifier.isEmpty else {
            throw TranslationFailure.invalidLanguageIdentifier
        }

        self.identifier = identifier
    }
}

/// The source-language policy for a translation request.
public enum TranslationSourceLanguage: Hashable, Sendable {
    /// Ask a provider that supports detection to identify the source language.
    case automatic

    /// Translate from a known source language.
    case language(TranslationLanguage)
}
