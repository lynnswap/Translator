import Foundation

public struct LanguageResourceStatusEvent: Sendable, Hashable {
    public let localeIdentifier: String
    public let progress: Double
    public let statusCode: Int64
    public let downloadSize: UInt64
    public let isIndeterminate: Bool
    public let rank: Int64
    public let taskHint: Int64
    public let timestamp: Date

    public init(
        localeIdentifier: String,
        progress: Double,
        statusCode: Int64,
        downloadSize: UInt64,
        isIndeterminate: Bool,
        rank: Int64,
        taskHint: Int64,
        timestamp: Date = Date()
    ) {
        self.localeIdentifier = localeIdentifier
        self.progress = progress
        self.statusCode = statusCode
        self.downloadSize = downloadSize
        self.isIndeterminate = isIndeterminate
        self.rank = rank
        self.taskHint = taskHint
        self.timestamp = timestamp
    }
}
