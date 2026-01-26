import Foundation
import Synchronization

public final class TranslationMemoryCache: @unchecked Sendable {
    // SAFETY: This type only wraps NSCache, which is thread-safe for concurrent access.
    private final class CacheKey: NSObject {
        let id: String
        let targetLanguage: Locale.Language?

        init(id: String, targetLanguage: Locale.Language?) {
            self.id = id
            self.targetLanguage = targetLanguage
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(id)
            hasher.combine(targetLanguage)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return id == other.id && targetLanguage == other.targetLanguage
        }
    }

    private let cache = NSCache<CacheKey, NSString>()
    private let lock = Mutex(())

    public init(countLimit: Int = 2000) {
        cache.countLimit = countLimit
    }

    public func get(id: String, targetLanguage: Locale.Language?) -> String? {
        let key = CacheKey(id: id, targetLanguage: targetLanguage)
        return cache.object(forKey: key) as String?
    }

    public func getMany(_ ids: [String], targetLanguage: Locale.Language?) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(ids.count)
        for id in ids {
            let key = CacheKey(id: id, targetLanguage: targetLanguage)
            if let value = cache.object(forKey: key) {
                result[id] = value as String
            }
        }
        return result
    }

    public func setMany(_ dict: [String: String], targetLanguage: Locale.Language?) {
        lock.withLock { _ in
            for (id, text) in dict {
                let key = CacheKey(id: id, targetLanguage: targetLanguage)
                cache.setObject(text as NSString, forKey: key)
            }
        }
    }

    public func remove(id: String, targetLanguage: Locale.Language?) {
        lock.withLock { _ in
            let key = CacheKey(id: id, targetLanguage: targetLanguage)
            cache.removeObject(forKey: key)
        }
    }

    public func removeAll() {
        lock.withLock { _ in
            cache.removeAllObjects()
        }
    }
}
