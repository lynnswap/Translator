# Translator

Translator is a Swift package for translating correlated batches of strings through either Apple's on-device Translation framework or a Google Apps Script endpoint. It validates language and provider configuration, preserves request ordering, and keeps an isolated in-memory cache for each client.

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

- Language and endpoint validation
- Provider selection and provider-specific transport
- Per-client in-memory caching
- Result membership validation and input-order restoration
- Structured cancellation and provider resource shutdown

Your app owns:

- The lifetime of each `TranslationClient`
- Google Apps Script deployment configuration
- Installation of on-device language assets
- User-facing failure handling and retry policy

## Quick start

Create one client at the composition root and retain it for as long as its cache should live:

```swift
import Translator

let endpoint = try GoogleAppsScriptEndpoint(deploymentID: "your-deployment-id")
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
    using: .googleAppsScript(endpoint)
) {
    for result in batch {
        print(result.requestID, result.translatedText)
    }
}
```

On iOS 26 and macOS 26 or later, pass `.onDevice` instead. The on-device provider requires every request to use an explicit `.language(...)` source.

## Contracts

- `TranslationClient` has reference identity. Aliases share a cache; separately initialized clients do not.
- `translations(for:to:using:)` returns a cold sequence. Work starts only when an iterator advances.
- Request IDs must be unique within one operation and are used only to correlate results.
- Cache identity includes exact source text, source-language policy, target language, and provider configuration.
- Iteration yields cached results first, then one fully validated fresh batch, both in input order.
- Unknown, duplicate, or missing provider result IDs terminate the sequence without committing fresh results to the cache.
- Task cancellation completes provider cancellation and resource shutdown before iteration throws `CancellationError`.
- Other terminal failures are reported as `TranslationFailure`.

See the package's DocC documentation for the Google Apps Script wire contract and complete provider semantics.

## Migrating from the legacy API

This version deliberately replaces the legacy streaming wrapper:

- Replace `Translator.shared` with an app-owned `TranslationClient`.
- Replace `TranslationService` selection with a `TranslationProvider`.
- Replace `TranslationUpdate` with `TranslationResult`.
- Treat request IDs as correlation only; cache identity now derives from translation content and provider configuration.
- Handle `TranslationFailure` and `CancellationError` separately.

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
