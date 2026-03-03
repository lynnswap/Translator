import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

internal protocol PrivateLanguageStatusBridge: AnyObject {
    func start(taskHint: Int64, observations: @escaping ([LanguageResourceStatusEvent]) -> Void) -> Bool
    func stop()
}

internal final class ObjCPrivateLanguageStatusBridge: PrivateLanguageStatusBridge {
    private enum Selectors {
        static let alloc = selector(["alloc"])
        static let cancel = selector(["cancel"])
        static let initWithTaskHintUseDedicatedMachPortObservations = selector([
            "observations:",
            "Port:",
            "Mach",
            "Dedicated",
            "use",
            "Hint:",
            "Task",
            "With",
            "init",
        ])
        static let initWithObservationTypeUseDedicatedMachPortObservations = selector([
            "observations:",
            "Port:",
            "Mach",
            "Dedicated",
            "use",
            "Type:",
            "Observation",
            "With",
            "init",
        ])

        static let locale = selector(["locale"])
        static let localeIdentifier = selector(["Identifier", "locale"])
        static let progress = selector(["progress"])
        static let status = selector(["status"])
        static let downloadSize = selector(["Size", "download"])
        static let isIndeterminateProgress = selector(["Progress", "Indeterminate", "is"])
        static let rank = selector(["rank"])

        private static func selector(_ reversedWords: [String]) -> Selector {
            NSSelectorFromString(reversedWords.reversed().joined())
        }
    }

    private var statusSession: AnyObject?
    private var observationsCallbackObject: AnyObject?
    private var observationsHandler: (([LanguageResourceStatusEvent]) -> Void)?
    private var currentTaskHint: Int64 = 0

    func start(taskHint: Int64, observations: @escaping ([LanguageResourceStatusEvent]) -> Void) -> Bool {
        if statusSession != nil {
            return true
        }

        currentTaskHint = taskHint
        observationsHandler = observations

        guard let cls = NSClassFromString("_LTLanguageStatus") as AnyObject? else {
            reset()
            return false
        }

        let allocSelector = Selectors.alloc
        guard cls.responds(to: allocSelector),
              let allocated = cls.perform(allocSelector)?.takeUnretainedValue()
        else {
            reset()
            return false
        }

        let taskHintSelector = Selectors.initWithTaskHintUseDedicatedMachPortObservations
        let observationTypeSelector = Selectors.initWithObservationTypeUseDedicatedMachPortObservations
        let initSelector: Selector
        if allocated.responds(to: taskHintSelector) {
            initSelector = taskHintSelector
        } else if allocated.responds(to: observationTypeSelector) {
            initSelector = observationTypeSelector
        } else {
            reset()
            return false
        }

        let block: @convention(block) (AnyObject?) -> Void = { [weak self] payload in
            guard let self else {
                return
            }
            let events = self.makeEvents(from: payload)
            if events.isEmpty {
                return
            }
            self.observationsHandler?(events)
        }
        let blockObject: AnyObject = unsafeBitCast(block, to: AnyObject.self)

        let initialized: AnyObject
        if initSelector == taskHintSelector {
            typealias InitMethod = @convention(c) (AnyObject, Selector, Int64, Bool, AnyObject) -> Unmanaged<AnyObject>
            let initImplementation = allocated.method(for: initSelector)
            let initMethod = unsafeBitCast(initImplementation, to: InitMethod.self)
            initialized = initMethod(allocated, initSelector, taskHint, false, blockObject).takeRetainedValue()
        } else {
            typealias LegacyInitMethod = @convention(c) (AnyObject, Selector, Int, Bool, AnyObject) -> Unmanaged<AnyObject>
            let initImplementation = allocated.method(for: initSelector)
            let initMethod = unsafeBitCast(initImplementation, to: LegacyInitMethod.self)
            let observationType = Int(truncatingIfNeeded: taskHint)
            initialized = initMethod(allocated, initSelector, observationType, false, blockObject).takeRetainedValue()
        }
        statusSession = initialized
        observationsCallbackObject = blockObject
        return true
    }

    func stop() {
        if let statusSession {
            let cancelSelector = Selectors.cancel
            if statusSession.responds(to: cancelSelector) {
                typealias CancelMethod = @convention(c) (AnyObject, Selector) -> Void
                let cancelImplementation = statusSession.method(for: cancelSelector)
                let cancelMethod = unsafeBitCast(cancelImplementation, to: CancelMethod.self)
                cancelMethod(statusSession, cancelSelector)
            }
        }
        reset()
    }

    private func reset() {
        statusSession = nil
        observationsCallbackObject = nil
        observationsHandler = nil
        currentTaskHint = 0
    }

    private func makeEvents(from payload: AnyObject?) -> [LanguageResourceStatusEvent] {
        let rawItems: [AnyObject]
        if let list = payload as? [AnyObject] {
            rawItems = list
        } else if let list = payload as? NSArray {
            rawItems = list.compactMap { $0 as AnyObject }
        } else if let payload {
            rawItems = [payload]
        } else {
            rawItems = []
        }

        return rawItems.compactMap { makeEvent(from: $0) }
    }

    private func makeEvent(from observation: AnyObject) -> LanguageResourceStatusEvent? {
        guard let localeObject = objectValue(from: observation, selector: Selectors.locale) else {
            return nil
        }

        let localeIdentifier: String
        if let locale = localeObject as? NSLocale {
            localeIdentifier = locale.localeIdentifier
        } else if let identifierObject = objectValue(from: localeObject, selector: Selectors.localeIdentifier) as? NSString {
            localeIdentifier = identifierObject as String
        } else {
            return nil
        }

        let progress = doubleValue(from: observation, selector: Selectors.progress) ?? 0
        let statusCode = int64Value(from: observation, selector: Selectors.status) ?? 0
        let downloadSize = uint64Value(from: observation, selector: Selectors.downloadSize) ?? 0
        let isIndeterminate = boolValue(from: observation, selector: Selectors.isIndeterminateProgress) ?? false
        let rank = int64Value(from: observation, selector: Selectors.rank) ?? 0

        return LanguageResourceStatusEvent(
            localeIdentifier: localeIdentifier,
            progress: progress,
            statusCode: statusCode,
            downloadSize: downloadSize,
            isIndeterminate: isIndeterminate,
            rank: rank,
            taskHint: currentTaskHint
        )
    }

    private func objectValue(from object: AnyObject, selector: Selector) -> AnyObject? {
        guard object.responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let implementation = object.method(for: selector)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)?.takeUnretainedValue()
    }

    private func boolValue(from object: AnyObject, selector: Selector) -> Bool? {
        guard object.responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = object.method(for: selector)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
    }

    private func doubleValue(from object: AnyObject, selector: Selector) -> Double? {
        guard object.responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Double
        let implementation = object.method(for: selector)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
    }

    private func int64Value(from object: AnyObject, selector: Selector) -> Int64? {
        guard object.responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
        let implementation = object.method(for: selector)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
    }

    private func uint64Value(from object: AnyObject, selector: Selector) -> UInt64? {
        guard object.responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
        let implementation = object.method(for: selector)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
    }
}
