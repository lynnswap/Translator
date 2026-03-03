import Foundation
import Observation

@MainActor
@Observable
public final class LanguageResourceStatusModel {
    public let localeIdentifier: String
    public var progress: Double = 0
    public var statusCode: Int64 = 0
    public var downloadSize: UInt64 = 0
    public var isIndeterminate: Bool = false
    public var rank: Int64 = 0
    public var taskHint: Int64 = 0
    public var timestamp: Date = .distantPast
    public var hasValue = false

    public init(localeIdentifier: String) {
        self.localeIdentifier = Self.normalizedLocaleIdentifier(localeIdentifier)
    }

    internal func apply(_ event: LanguageResourceStatusEvent) {
        let clampedProgress = min(max(event.progress, 0), 1)
        progress = clampedProgress
        statusCode = event.statusCode
        downloadSize = event.downloadSize
        isIndeterminate = event.isIndeterminate
        rank = event.rank
        taskHint = event.taskHint
        timestamp = event.timestamp
        hasValue = true
    }

    internal static func normalizedLocaleIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
