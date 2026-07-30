import Foundation

struct TranslationTransportResult: Sendable {
    let requestID: String
    let translatedText: String
}

struct TranslationTransport: Sendable {
    let translate: @Sendable (
        _ requests: [TranslationRequest],
        _ sourceLanguage: TranslationSourceLanguage,
        _ targetLanguage: TranslationLanguage
    ) async throws -> [TranslationTransportResult]
    let finish: @Sendable () async -> Void

    init(
        translate: @escaping @Sendable (
            _ requests: [TranslationRequest],
            _ sourceLanguage: TranslationSourceLanguage,
            _ targetLanguage: TranslationLanguage
        ) async throws -> [TranslationTransportResult],
        finish: @escaping @Sendable () async -> Void = {}
    ) {
        self.translate = translate
        self.finish = finish
    }
}

struct TranslationTransportFactory: Sendable {
    let transport: @Sendable (TranslationProvider) -> TranslationTransport

    static let live = TranslationTransportFactory { provider in
        switch provider.storage {
        case .onDevice:
            if #available(iOS 26.0, macOS 26.0, *) {
                return OnDeviceTranslationTransport().transport
            }
            return TranslationTransport(
                translate: { _, _, _ in
                    throw TranslationFailure.providerUnavailable
                }
            )
        case .googleAppsScript(let endpoint):
            return GoogleAppsScriptTransport(endpoint: endpoint).transport
        }
    }
}
