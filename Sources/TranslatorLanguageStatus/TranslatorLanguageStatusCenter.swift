import Foundation
import Observation

@MainActor
@Observable
public final class TranslatorLanguageStatusCenter {
    public static let shared = TranslatorLanguageStatusCenter()

    public private(set) var isMonitoring = false
    public private(set) var modelsByLocale: [String: LanguageResourceStatusModel] = [:]

    @ObservationIgnored private let bridge: any PrivateLanguageStatusBridge
    @ObservationIgnored private var monitoringClientCount = 0

    public convenience init() {
        self.init(bridge: ObjCPrivateLanguageStatusBridge())
    }

    internal init(bridge: any PrivateLanguageStatusBridge) {
        self.bridge = bridge
    }

    public func startMonitoring(taskHint: Int64 = 0) {
        if isMonitoring {
            monitoringClientCount += 1
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
        monitoringClientCount = started ? 1 : 0
    }

    public func stopMonitoring() {
        if monitoringClientCount == 0 {
            return
        }
        monitoringClientCount -= 1
        if monitoringClientCount > 0 {
            return
        }
        if !isMonitoring {
            monitoringClientCount = 0
            return
        }
        bridge.stop()
        isMonitoring = false
        modelsByLocale.removeAll()
    }

    public func model(for localeIdentifier: String) -> LanguageResourceStatusModel? {
        let key = LanguageResourceStatusModel.normalizedLocaleIdentifier(localeIdentifier)
        return modelsByLocale[key]
    }

    private func handleIncoming(_ events: [LanguageResourceStatusEvent]) {
        if !isMonitoring {
            return
        }
        for event in events {
            if !isMonitoring {
                return
            }
            let key = LanguageResourceStatusModel.normalizedLocaleIdentifier(event.localeIdentifier)
            let statusModel: LanguageResourceStatusModel
            if let existing = modelsByLocale[key] {
                statusModel = existing
            } else {
                let created = LanguageResourceStatusModel(localeIdentifier: key)
                modelsByLocale[key] = created
                statusModel = created
            }
            statusModel.apply(event)
        }
    }
}
