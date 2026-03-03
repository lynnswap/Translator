import Foundation
import Testing
@testable import TranslatorLanguageStatus

private final class FakeLanguageStatusBridge: PrivateLanguageStatusBridge {
    var startCount = 0
    var stopCount = 0
    var shouldStart = true
    private var handler: (([LanguageResourceStatusEvent]) -> Void)?

    func start(taskHint: Int64, observations: @escaping ([LanguageResourceStatusEvent]) -> Void) -> Bool {
        startCount += 1
        handler = observations
        return shouldStart
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ events: [LanguageResourceStatusEvent]) {
        handler?(events)
    }
}

private func flushMainActor() async {
    for _ in 0..<4 {
        await Task.yield()
    }
}

@MainActor
@Test func startStopAreIdempotent() {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)
    center.startMonitoring(taskHint: 0)

    #expect(bridge.startCount == 1)
    #expect(center.isMonitoring)

    center.stopMonitoring()
    center.stopMonitoring()

    #expect(bridge.stopCount == 1)
    #expect(!center.isMonitoring)
    #expect(center.modelsByLocale.isEmpty)
}

@MainActor
@Test func sharedMonitoringRequiresMatchingStopCalls() {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)
    center.startMonitoring(taskHint: 0)
    #expect(bridge.startCount == 1)
    #expect(center.isMonitoring)

    center.stopMonitoring()
    #expect(bridge.stopCount == 0)
    #expect(center.isMonitoring)

    center.stopMonitoring()
    #expect(bridge.stopCount == 1)
    #expect(!center.isMonitoring)
}

@MainActor
@Test func firstEventCreatesLocaleModelAndAppliesValues() async throws {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 42)
    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "en_US",
            progress: 1.5,
            statusCode: 3,
            downloadSize: 1024,
            isIndeterminate: true,
            rank: 4,
            taskHint: 42
        )
    ])
    await flushMainActor()

    let model = try #require(center.model(for: "en-US"))
    #expect(center.modelsByLocale.count == 1)
    #expect(model.localeIdentifier == "en-us")
    #expect(model.progress == 1)
    #expect(model.statusCode == 3)
    #expect(model.downloadSize == 1024)
    #expect(model.isIndeterminate)
    #expect(model.rank == 4)
    #expect(model.taskHint == 42)
    #expect(model.hasValue)
}

@MainActor
@Test func sameLocaleReusesSingleObservableModel() async throws {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)
    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "en-US",
            progress: 0.1,
            statusCode: 1,
            downloadSize: 512,
            isIndeterminate: false,
            rank: 0,
            taskHint: 0
        )
    ])
    await flushMainActor()

    let firstModel = try #require(center.model(for: "en-US"))

    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "en_US",
            progress: 0.9,
            statusCode: 2,
            downloadSize: 2048,
            isIndeterminate: false,
            rank: 1,
            taskHint: 0
        )
    ])
    await flushMainActor()

    let secondModel = try #require(center.model(for: "EN-us"))
    #expect(firstModel === secondModel)
    #expect(center.modelsByLocale.count == 1)
    #expect(secondModel.progress == 0.9)
    #expect(secondModel.statusCode == 2)
    #expect(secondModel.downloadSize == 2048)
}

@MainActor
@Test func stopMonitoringClearsModels() async {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)
    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "ja-JP",
            progress: 0.25,
            statusCode: 1,
            downloadSize: 300,
            isIndeterminate: false,
            rank: 0,
            taskHint: 0
        )
    ])
    await flushMainActor()
    #expect(!center.modelsByLocale.isEmpty)

    center.stopMonitoring()
    #expect(center.modelsByLocale.isEmpty)

    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "ja-JP",
            progress: 0.5,
            statusCode: 2,
            downloadSize: 600,
            isIndeterminate: false,
            rank: 1,
            taskHint: 0
        )
    ])
    await flushMainActor()

    #expect(center.modelsByLocale.isEmpty)
}

@MainActor
@Test func modelLookupNormalizesLocaleIdentifier() async {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)
    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "zh-Hant_TW",
            progress: 0.4,
            statusCode: 1,
            downloadSize: 1024,
            isIndeterminate: false,
            rank: 0,
            taskHint: 0
        )
    ])
    await flushMainActor()

    #expect(center.model(for: "zh-hant-tw") != nil)
    #expect(center.model(for: "zh_HANT_tw") != nil)
}

@MainActor
@Test func startFailureKeepsCenterStopped() async {
    let bridge = FakeLanguageStatusBridge()
    bridge.shouldStart = false
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    center.startMonitoring(taskHint: 0)

    #expect(bridge.startCount == 1)
    #expect(!center.isMonitoring)

    bridge.emit([
        LanguageResourceStatusEvent(
            localeIdentifier: "ja-JP",
            progress: 0.1,
            statusCode: 1,
            downloadSize: 200,
            isIndeterminate: false,
            rank: 0,
            taskHint: 0
        )
    ])
    await flushMainActor()

    #expect(center.modelsByLocale.isEmpty)
}
