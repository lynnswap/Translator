import Foundation
#if canImport(Translation)
import Translation
#endif

public protocol TranslationService: Sendable {
    func translateStream(
        requests: [TranslationRequest],
        targetLanguage: String
    ) -> AsyncThrowingStream<[TranslationUpdate], Error>
}

#if canImport(Translation)
@available(iOS 26.0, macOS 26.0, *)
public struct AppleTranslationService: Sendable, TranslationService {
    public init() {}
    public func translateStream(
        requests: [TranslationRequest],
        targetLanguage: String
    ) -> AsyncThrowingStream<[TranslationUpdate], Error> {
        if requests.isEmpty {
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            let driver = Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    let groups = Dictionary(grouping: requests, by: { $0.sourceLanguage })
                    for (sourceLanguage, groupItems) in groups {
                        group.addTask {
                            let session = TranslationSession(
                                installedSource: .init(identifier: sourceLanguage),
                                target: .init(identifier: targetLanguage)
                            )
                            let translationRequests: [TranslationSession.Request] = groupItems.map { request in
                                .init(sourceText: request.text, clientIdentifier: request.id)
                            }
                            do {
                                let responses = try await session.translations(from: translationRequests)
                                let updates = responses.compactMap { response -> TranslationUpdate? in
                                    guard let id = response.clientIdentifier else { return nil }
                                    return TranslationUpdate(id: id, text: response.targetText)
                                }
                                if !updates.isEmpty {
                                    continuation.yield(updates)
                                }
                            } catch {
                                // Ignore per-language failures to keep the stream flowing.
                            }
                        }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in driver.cancel() }
        }
    }
}
#endif
