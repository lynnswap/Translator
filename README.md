# Translator

Translator is a Swift package for translating correlated batches of strings through an app-defined provider or Apple's on-device Translation framework. It preserves request ordering, validates provider result membership, and keeps an isolated in-memory cache for each client.

## Requirements

- Swift 6.3
- iOS 18+
- macOS 15+
- iOS 26+ or macOS 26+ when using the on-device provider

## Responsibilities

Translator owns:

- The provider interface and Apple on-device provider
- Per-client in-memory caching
- Result membership validation and input-order restoration
- Cold sequence and cache commit semantics

Your app owns:

- The lifetime of each `TranslationClient`
- Custom provider configuration, errors, I/O, and cancellation cleanup
- Installation of on-device language assets
- User-facing failure handling and retry policy

## Quick start

Implement `TranslationProvider` for an app-owned backend. Every output-affecting configuration value belongs in the provider's stable `Hashable` identity:

```swift
import Translator

struct PreviewProvider: TranslationProvider {
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

let client = TranslationClient()
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
    using: PreviewProvider(prefix: "Translated: ")
) {
    for result in batch {
        print(result.requestID, result.translatedText)
    }
}
```

## On-device translation

On iOS 26 and macOS 26 or later, use `OnDeviceTranslationProvider` to translate with language assets already installed on the device:

```swift
if #available(iOS 26.0, macOS 26.0, *) {
    let results = client.translations(
        for: requests,
        to: english,
        using: OnDeviceTranslationProvider()
    )

    for try await batch in results {
        // Consume each validated result batch.
    }
}
```

The on-device provider requires every request to use an explicit `.language(...)` source. If any request uses `.automatic`, the complete batch fails before a translation session is created.

## Migration

### v0.1.0

These notes apply when migrating from the legacy API to `v0.1.0`. This release deliberately replaces the legacy streaming wrapper:

- Replace `Translator.shared` with an app-owned `TranslationClient`.
- Replace `TranslationService` selection with a `TranslationProvider`.
- Replace `TranslationUpdate` with `TranslationResult`.
- Treat request IDs as correlation only; cache identity derives from translation content and provider configuration.
- Handle custom provider errors, `TranslationFailure`, and `CancellationError` according to their origin.

No compatibility wrapper is provided because retaining both ownership models would create competing cache and lifecycle contracts.

## Testing

```sh
swift test
swift build --configuration release
swift run --package-path Tests/ConsumerFixture
```

`Tests/ConsumerFixture` is a separate package that imports and links only the public `Translator` product.

## License

Translator is available under the MIT license. See [LICENSE](LICENSE).
