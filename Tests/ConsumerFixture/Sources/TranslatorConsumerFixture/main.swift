import Translator

@main
struct TranslatorConsumerFixture {
    static func translateExample(
        client: TranslationClient,
        endpoint: GoogleAppsScriptEndpoint
    ) async throws {
        let french = try TranslationLanguage(identifier: "fr")
        let english = try TranslationLanguage(identifier: "en")
        let requests = [
            TranslationRequest(
                id: "post-42",
                text: "Bonjour",
                sourceLanguage: .language(french)
            ),
        ]

        for try await batch in client.translations(
            for: requests,
            to: english,
            using: .googleAppsScript(endpoint)
        ) {
            for result in batch {
                print(result.requestID, result.translatedText)
            }
        }
    }

    static func main() async throws {
        let client = TranslationClient()
        let endpoint = try GoogleAppsScriptEndpoint(deploymentID: "consumer-fixture")
        let english = try TranslationLanguage(identifier: "en")
        let results = client.translations(
            for: [],
            to: english,
            using: .googleAppsScript(endpoint)
        )

        var batchCount = 0
        for try await batch in results {
            let _: [TranslationResult] = batch
            batchCount += 1
        }
        precondition(batchCount == 0)
    }
}
