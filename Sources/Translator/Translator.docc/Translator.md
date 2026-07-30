# ``Translator``

Translate correlated batches with app-defined providers or Apple's on-device Translation framework.

## Overview

Create a client at the composition root and retain it for as long as its in-memory cache should live.
`TranslationClient` has reference identity: aliases share that cache, while separately initialized
clients never do. Each call creates a cold ``TranslationResults`` value; no cache lookup or provider
work begins until the sequence is iterated.

Define a provider for an app-owned translation implementation:

```swift
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
    )
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

On iOS 26 and macOS 26 or later, use the built-in on-device provider:

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

``TranslationLanguage`` validates ISO language codes and stores one canonical BCP-47 identifier.
Use ``TranslationSourceLanguage/language(_:)`` when the source is known or
``TranslationSourceLanguage/automatic`` when a custom provider supports detection. Automatic
detection is part of cache identity and is never inferred from a placeholder language.

## Provider contract

``TranslationProvider`` is the package's only implementation seam. Equality and hashing identify
the provider type and every immutable configuration value that can change translated output. Do not
include mutable session, request, or metrics state, and do not mutate semantic identity while a
provider is used with a client.

The client calls ``TranslationProvider/translate(_:to:)`` once with the operation's complete
cache-miss batch. A provider owns any source-language grouping, I/O, child tasks, and resources for
that call. Separate client operations may invoke an equal provider concurrently.

For cache correctness, each translated value depends only on that request's text and source policy,
the target language, and the provider's semantic identity. A provider must not use a request
identifier or the surrounding batch's membership or order to change a translated value.

A successful provider call returns exactly one ``TranslationResult`` for every request identifier.
Result order is not significant. The client rejects unknown, duplicate, or missing identifiers and
restores input order before committing fresh values to its cache.

Cancellation is a completion contract, not only a signal. A cancelled provider call stops and awaits
all provider-owned work before returning or throwing. The client reports caller cancellation as
`CancellationError`; custom provider errors otherwise pass through unchanged.

## On-device provider

``OnDeviceTranslationProvider`` uses models already installed on the device and is available on
iOS 26 and macOS 26 or later. It rejects a complete batch if any request uses
``TranslationSourceLanguage/automatic``. After preflight, it groups explicit source languages,
creates one Translation session for each group, and awaits all session cancellation work before
completing.

Unsupported languages, unsupported pairings, unidentified language, empty translatable content,
missing assets, and provider-internal errors remain distinct ``TranslationFailure`` values.

## Result and cache semantics

Cached values are keyed by the source text's exact Unicode scalar sequence, source policy, target
language, provider implementation type, and semantic provider configuration. Canonically equivalent
text representations remain distinct. Request IDs only correlate results. Cached results arrive
first in input order. Fresh results arrive only after complete provider membership validation, and
a membership failure does not modify the cache.

Each iterator starts an independent operation. An iterator yields at most two batches: cached results,
then fully validated fresh results. Cancellation terminates iteration with `CancellationError`;
client validation and built-in provider failures use ``TranslationFailure``.

## Topics

### Translating

- ``TranslationClient``
- ``TranslationResults``
- ``TranslationRequest``
- ``TranslationResult``
- ``TranslationLanguage``
- ``TranslationSourceLanguage``

### Providing translations

- ``TranslationProvider``
- ``OnDeviceTranslationProvider``

### Handling failure

- ``TranslationFailure``
- ``TranslationResponseMembershipFailure``
