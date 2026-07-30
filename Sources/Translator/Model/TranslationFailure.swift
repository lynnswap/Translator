import Foundation

/// A terminal translation failure that requires consumer intervention or a new operation.
///
/// Task cancellation is reported separately as `CancellationError`.
public enum TranslationFailure: Error, Equatable, Sendable {
    case invalidGoogleAppsScriptDeploymentID
    case invalidLanguageIdentifier
    case duplicateRequestIdentifiers(count: Int)
    case providerUnavailable
    case automaticSourceLanguageUnavailable
    case unsupportedSourceLanguage
    case unsupportedTargetLanguage
    case unsupportedLanguagePairing
    case unableToIdentifySourceLanguage
    case nothingToTranslate
    case languageAssetsNotInstalled
    case providerInternal
    case transport
    case serverRejected(statusCode: Int)
    case malformedResponse
    case invalidResponseMembership(TranslationResponseMembershipFailure)
}

/// A redacted description of invalid provider response membership.
public enum TranslationResponseMembershipFailure: Error, Equatable, Sendable {
    case unknownIdentifiers(count: Int)
    case duplicateIdentifiers(count: Int)
    case missingIdentifiers(count: Int)
}

extension TranslationFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGoogleAppsScriptDeploymentID:
            "The Google Apps Script deployment ID is invalid."
        case .invalidLanguageIdentifier:
            "The translation language identifier is not a supported ISO language tag."
        case .duplicateRequestIdentifiers(let count):
            "The translation request contains \(count) duplicate correlation identifier(s)."
        case .providerUnavailable:
            "The selected translation provider is unavailable."
        case .automaticSourceLanguageUnavailable:
            "The selected translation provider requires an explicit source language."
        case .unsupportedSourceLanguage:
            "The translation provider does not support the source language."
        case .unsupportedTargetLanguage:
            "The translation provider does not support the target language."
        case .unsupportedLanguagePairing:
            "The translation provider does not support this language pairing."
        case .unableToIdentifySourceLanguage:
            "The translation provider could not identify the source language."
        case .nothingToTranslate:
            "The request does not contain translatable content."
        case .languageAssetsNotInstalled:
            "The required on-device translation languages are not installed."
        case .providerInternal:
            "The translation provider encountered an internal failure."
        case .transport:
            "The translation provider could not be reached."
        case .serverRejected(let statusCode):
            "The translation server rejected the request with status \(statusCode)."
        case .malformedResponse:
            "The translation provider returned an invalid response."
        case .invalidResponseMembership(let failure):
            switch failure {
            case .unknownIdentifiers(let count):
                "The translation provider returned \(count) unknown result identifier(s)."
            case .duplicateIdentifiers(let count):
                "The translation provider returned \(count) duplicate result identifier(s)."
            case .missingIdentifiers(let count):
                "The translation provider omitted \(count) result identifier(s)."
            }
        }
    }
}
