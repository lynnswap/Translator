import Translator

private struct FixtureProvider: TranslationProvider {
    let prefix: String

    func translate(
        _ requests: [TranslationRequest],
        to targetLanguage: TranslationLanguage
    ) async throws -> [TranslationResult] {
        requests.map {
            TranslationResult(
                requestID: $0.id,
                translatedText: "\(prefix)\($0.text)"
            )
        }
    }
}

@main
struct TranslatorConsumerFixture {
    static func main() async throws {
        let french = try TranslationLanguage(identifier: "fr")
        let english = try TranslationLanguage(identifier: "en")
        let requests = [
            TranslationRequest(
                id: "post-42",
                text: "Bonjour",
                sourceLanguage: .language(french)
            ),
        ]
        let client = TranslationClient()
        let results = client.translations(
            for: requests,
            to: english,
            using: FixtureProvider(prefix: "translated:")
        )

        var received: [TranslationResult] = []
        for try await batch in results {
            received.append(contentsOf: batch)
        }
        precondition(received.map(\.translatedText) == ["translated:Bonjour"])

        if #available(macOS 26.0, *) {
            let onDevice: any TranslationProvider = OnDeviceTranslationProvider()
            _ = client.translations(
                for: requests,
                to: english,
                using: onDevice
            )
        }
    }
}
