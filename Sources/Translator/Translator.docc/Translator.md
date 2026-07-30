# ``Translator``

Translate batches of correlated strings with built-in on-device and Google Apps Script providers.

## Overview

Create a client at the composition root and retain it for as long as its in-memory cache should live.
`TranslationClient` has reference identity: aliases share that cache, while separately initialized
clients never do. Each call creates a cold ``TranslationResults`` value; no cache lookup or provider
I/O begins until the sequence is iterated.

```swift
let endpoint = try GoogleAppsScriptEndpoint(deploymentID: deploymentID)
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
    using: .googleAppsScript(endpoint)
) {
    for result in batch {
        print(result.requestID, result.translatedText)
    }
}
```

``TranslationLanguage`` validates ISO language codes and stores one canonical BCP-47 identifier.
Use ``TranslationSourceLanguage/language(_:)`` when the source is known or
``TranslationSourceLanguage/automatic`` when the provider should detect it. Automatic detection is
part of cache identity and is never inferred from a placeholder language.

Cached values are keyed by exact text, source policy, target language, and provider configuration.
Request IDs only correlate results. Cached results arrive first in input order. Fresh results arrive
only after the provider returns exactly one result for every cache miss; unknown, duplicate, or missing
IDs terminate the sequence with ``TranslationFailure`` without modifying the cache.

Cancelling the iteration task cancels and awaits all structured provider work before iteration throws
`CancellationError`. Every other terminal error is a ``TranslationFailure``.

## Provider contracts

``TranslationProvider/onDevice`` uses language models that are already installed. It is available on
iOS 26 and macOS 26 or later. Use ``TranslationProvider/googleAppsScript(_:)`` on earlier iOS releases
or when a server-backed provider is preferred.

The on-device provider requires an explicit source language. Passing `automatic` fails with
``TranslationFailure/automaticSourceLanguageUnavailable`` before a session is created. Unsupported
languages, unsupported pairings, unidentified language, empty translatable content, missing assets,
and provider-internal errors remain distinct failures.

The Google Apps Script endpoint receives one request for each known source language and a separate
request with an empty `sourceLang` for automatic detection. A translation operation owns one dedicated
ephemeral `URLSession` shared by those requests. The session has no cache, cookie, or credential store
and is invalidated only after every structured request reaches quiescence.

The wire request replaces consumer request IDs with operation-local opaque UUID tokens. The endpoint
must return canonical JSON with one two-string row per token:

```json
[["opaque-operation-token", "translated text"]]
```

Dictionary-shaped responses, rows with additional fields, and responses outside the operation's token
space are rejected. Public failures report only a membership kind and count; neither consumer IDs nor
provider tokens appear in error descriptions.

## Topics

### Translating

- ``TranslationClient``
- ``TranslationResults``
- ``TranslationRequest``
- ``TranslationResult``
- ``TranslationLanguage``
- ``TranslationSourceLanguage``

### Choosing a provider

- ``TranslationProvider``
- ``GoogleAppsScriptEndpoint``

### Handling failure

- ``TranslationFailure``
- ``TranslationResponseMembershipFailure``
