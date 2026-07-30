import Foundation

actor TranslationCache {
    struct Key: Hashable, Sendable {
        let text: String
        let sourceLanguage: TranslationSourceLanguage
        let targetLanguage: TranslationLanguage
        let provider: TranslationProvider
    }

    private struct Entry: Sendable {
        let translatedText: String
        let lastAccess: UInt64
    }

    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var accessSequence: UInt64 = 0

    init(countLimit: Int = 2_000) {
        precondition(countLimit > 0)
        self.countLimit = countLimit
    }

    func values(for keys: [Key]) throws -> [Key: String] {
        try Task.checkCancellation()

        var values: [Key: String] = [:]
        values.reserveCapacity(keys.count)
        for key in keys {
            guard let entry = entries[key] else { continue }
            accessSequence &+= 1
            entries[key] = Entry(
                translatedText: entry.translatedText,
                lastAccess: accessSequence
            )
            values[key] = entry.translatedText
        }
        return values
    }

    func store(_ values: [(key: Key, translatedText: String)]) throws {
        try Task.checkCancellation()
        guard !values.isEmpty else { return }

        let finalAccessSequence = accessSequence &+ UInt64(values.count)
        var newestEntries: [Key: Entry] = [:]
        newestEntries.reserveCapacity(min(values.count, countLimit))

        // Walk backward and cap before merging. Inserting an unbounded batch and repeatedly
        // scanning for the oldest entry makes eviction quadratic while holding this actor.
        for (reverseOffset, value) in values.reversed().enumerated() {
            guard newestEntries[value.key] == nil else { continue }
            newestEntries[value.key] = Entry(
                translatedText: value.translatedText,
                lastAccess: finalAccessSequence &- UInt64(reverseOffset)
            )
            if newestEntries.count == countLimit {
                break
            }
        }

        accessSequence = finalAccessSequence
        if newestEntries.count == countLimit {
            entries = newestEntries
            return
        }

        entries.merge(newestEntries) { _, newest in newest }
        guard entries.count > countLimit else { return }

        entries = Dictionary(
            uniqueKeysWithValues: entries
                .sorted { $0.value.lastAccess > $1.value.lastAccess }
                .prefix(countLimit)
                .map { ($0.key, $0.value) }
        )
    }
}
