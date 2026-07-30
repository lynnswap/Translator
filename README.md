# Translator

Translator is a Swift package for translating correlated batches of strings through an app-defined provider or Apple's on-device Translation framework. It preserves request ordering, validates provider result membership, and keeps an isolated in-memory cache for each client.

## Requirements

- Swift 6.3
- iOS 18+
- macOS 15+
- iOS 26+ or macOS 26+ when using the on-device provider

## Installation

Add the repository to your package dependencies and depend on the `Translator` product:

```swift
dependencies: [
    .package(
        url: "https://github.com/lynnswap/Translator.git",
        revision: "<reviewed-commit-sha>"
    ),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "Translator", package: "translator"),
        ]
    ),
]
```

Replace the placeholder with an approved commit SHA. After the first release is tagged, use that released version instead.

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

## Contracts

- `TranslationClient` has reference identity. Aliases share a cache; separately initialized clients do not.
- `translations(for:to:using:)` returns a cold sequence. Work starts only when an iterator advances.
- Request IDs must be unique within one operation and are used only to correlate results.
- The provider receives the complete cache-miss batch once per operation and owns any internal grouping.
- Cache identity includes the source text's exact Unicode scalar sequence, source-language policy,
  target language, provider type, and semantic provider configuration. Canonically equivalent text
  representations remain distinct.
- A provider's equality and hash must remain stable while it is used with a client.
- Each provider result may depend only on its request's text and source policy, the target language, and provider identity—not on request ID or batch membership/order.
- Iteration yields cached results first, then one fully validated fresh batch, both in input order.
- Unknown, duplicate, or missing provider result IDs terminate the sequence without committing fresh results to the cache.
- A cancelled provider call must finish resource cleanup before it returns or throws.
- Custom provider errors pass through unchanged unless the caller task is cancelled, which is reported as `CancellationError`. Client validation and on-device failures use `TranslationFailure`.

## Migrating from the legacy API

This version deliberately replaces the legacy streaming wrapper:

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
