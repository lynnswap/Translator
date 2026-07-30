/// A translation provider and the configuration that defines its semantic identity.
public struct TranslationProvider: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case onDevice
        case googleAppsScript(GoogleAppsScriptEndpoint)
    }

    let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    /// Apple's on-device Translation framework using already-installed languages.
    @available(iOS 26.0, macOS 26.0, *)
    public static let onDevice = TranslationProvider(storage: .onDevice)

    /// A Google Apps Script web-app endpoint implementing the Translator wire contract.
    public static func googleAppsScript(_ endpoint: GoogleAppsScriptEndpoint) -> TranslationProvider {
        TranslationProvider(storage: .googleAppsScript(endpoint))
    }

    func validate(sourceLanguages: [TranslationSourceLanguage]) throws {
        guard case .onDevice = storage else { return }
        guard !sourceLanguages.contains(.automatic) else {
            throw TranslationFailure.automaticSourceLanguageUnavailable
        }
    }
}
