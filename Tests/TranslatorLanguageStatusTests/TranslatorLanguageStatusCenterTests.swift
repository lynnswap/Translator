import Foundation
import Synchronization
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
    #expect(center.latestByLocale.isEmpty)
}

@MainActor
@Test func emitsProgressAndStateNotificationsByDiff() async {
    let bridge = FakeLanguageStatusBridge()
    let center = TranslatorLanguageStatusCenter(bridge: bridge)

    let counts = Mutex((progress: 0, state: 0))

    let progressToken = NotificationCenter.default.addObserver(
        forName: .translatorLanguageProgressDidChange,
        object: center,
        queue: .main
    ) { _ in
        counts.withLock { value in
            value.progress += 1
        }
    }

    let stateToken = NotificationCenter.default.addObserver(
        forName: .translatorLanguageStateDidChange,
        object: center,
        queue: .main
    ) { _ in
        counts.withLock { value in
            value.state += 1
        }
    }

    defer {
        NotificationCenter.default.removeObserver(progressToken)
        NotificationCenter.default.removeObserver(stateToken)
    }

    center.startMonitoring(taskHint: 0)

    let first = LanguageResourceStatusEvent(
        localeIdentifier: "en-US",
        progress: 0.25,
        statusCode: 1,
        downloadSize: 1024,
        isIndeterminate: false,
        rank: 0,
        taskHint: 0
    )
    bridge.emit([first])
    await flushMainActor()
    #expect(counts.withLock { $0.progress } == 1)
    #expect(counts.withLock { $0.state } == 1)

    bridge.emit([first])
    await flushMainActor()
    #expect(counts.withLock { $0.progress } == 1)
    #expect(counts.withLock { $0.state } == 1)

    let progressOnly = LanguageResourceStatusEvent(
        localeIdentifier: "en-US",
        progress: 0.5,
        statusCode: 1,
        downloadSize: 2048,
        isIndeterminate: false,
        rank: 0,
        taskHint: 0
    )
    bridge.emit([progressOnly])
    await flushMainActor()
    #expect(counts.withLock { $0.progress } == 2)
    #expect(counts.withLock { $0.state } == 1)

    let stateOnly = LanguageResourceStatusEvent(
        localeIdentifier: "en-US",
        progress: 0.5,
        statusCode: 2,
        downloadSize: 2048,
        isIndeterminate: false,
        rank: 1,
        taskHint: 0
    )
    bridge.emit([stateOnly])
    await flushMainActor()
    #expect(counts.withLock { $0.progress } == 2)
    #expect(counts.withLock { $0.state } == 2)
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

    #expect(center.latestByLocale.isEmpty)
}
