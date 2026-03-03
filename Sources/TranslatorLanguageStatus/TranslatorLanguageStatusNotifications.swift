import Foundation

public enum TranslatorLanguageStatusUserInfoKey {
    public static let event = "event"
    public static let localeIdentifier = "localeIdentifier"
    public static let progress = "progress"
    public static let statusCode = "statusCode"
    public static let downloadSize = "downloadSize"
    public static let isIndeterminate = "isIndeterminate"
    public static let rank = "rank"
    public static let taskHint = "taskHint"
    public static let timestamp = "timestamp"
}

extension Notification.Name {
    public static let translatorLanguageProgressDidChange = Notification.Name("TranslatorLanguageStatus.progressDidChange")
    public static let translatorLanguageStateDidChange = Notification.Name("TranslatorLanguageStatus.stateDidChange")
}
