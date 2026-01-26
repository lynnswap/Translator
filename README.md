# Translator

Lightweight streaming translation wrapper with in-memory caching.

## Requirements

- Swift 6.2
- iOS 26+ / macOS 26+ for on-device translation (Translation.framework)

## Usage

```swift
import Foundation
import Translator

let requests = [
    TranslationRequest(id: "1", text: "hola", sourceLanguage: Locale.Language(identifier: "es"))
]

if #available(iOS 26.0, macOS 26.0, *) {
    let stream = Translator.shared.translateStream(
        requests: requests,
        targetLanguage: Locale.Language(identifier: "en")
    )

    for try await batch in stream {
        for update in batch {
            print(update.id, update.text)
        }
    }
}
```

## Cache utilities

```swift
await translator.clearCache()
await translator.invalidate(id: "1", targetLanguage: Locale.Language(identifier: "en"))
```

## Notes

- Request IDs must be unique per source text and source language. The cache key is `(id, targetLanguage)`.
- Cached hits are yielded first, then live updates.
- Empty update batches are ignored.
