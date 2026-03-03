import Foundation

@MainActor
public final class TranslatorLanguageStatusCenter {
    public static let shared = TranslatorLanguageStatusCenter()

    public private(set) var isMonitoring = false
    public private(set) var latestByLocale: [String: LanguageResourceStatusEvent] = [:]

    private let bridge: any PrivateLanguageStatusBridge

    public convenience init() {
        self.init(bridge: ObjCPrivateLanguageStatusBridge())
    }

    internal init(bridge: any PrivateLanguageStatusBridge) {
        self.bridge = bridge
    }

    public func startMonitoring(taskHint: Int64 = 0) {
        if isMonitoring {
            return
        }
        let started = bridge.start(taskHint: taskHint) { [weak self] events in
            guard let self else {
                return
            }
            Task { @MainActor in
                self.handleIncoming(events)
            }
        }
        isMonitoring = started
    }

    public func stopMonitoring() {
        if !isMonitoring {
            return
        }
        bridge.stop()
        isMonitoring = false
        latestByLocale.removeAll()
    }

    private func handleIncoming(_ events: [LanguageResourceStatusEvent]) {
        if !isMonitoring {
            return
        }
        for event in events {
            if !isMonitoring {
                return
            }
            let previous = latestByLocale[event.localeIdentifier]
            latestByLocale[event.localeIdentifier] = event

            let progressChanged = previous == nil
                || previous?.progress != event.progress
                || previous?.downloadSize != event.downloadSize
                || previous?.isIndeterminate != event.isIndeterminate

            let statusChanged = previous == nil
                || previous?.statusCode != event.statusCode
                || previous?.rank != event.rank
                || previous?.taskHint != event.taskHint

            if progressChanged {
                post(name: .translatorLanguageProgressDidChange, event: event)
            }
            if statusChanged {
                post(name: .translatorLanguageStateDidChange, event: event)
            }
        }
    }

    private func post(name: Notification.Name, event: LanguageResourceStatusEvent) {
        let userInfo: [AnyHashable: Any] = [
            TranslatorLanguageStatusUserInfoKey.event: event,
            TranslatorLanguageStatusUserInfoKey.localeIdentifier: event.localeIdentifier,
            TranslatorLanguageStatusUserInfoKey.progress: event.progress,
            TranslatorLanguageStatusUserInfoKey.statusCode: event.statusCode,
            TranslatorLanguageStatusUserInfoKey.downloadSize: event.downloadSize,
            TranslatorLanguageStatusUserInfoKey.isIndeterminate: event.isIndeterminate,
            TranslatorLanguageStatusUserInfoKey.rank: event.rank,
            TranslatorLanguageStatusUserInfoKey.taskHint: event.taskHint,
            TranslatorLanguageStatusUserInfoKey.timestamp: event.timestamp,
        ]
        NotificationCenter.default.post(name: name, object: self, userInfo: userInfo)
    }
}
