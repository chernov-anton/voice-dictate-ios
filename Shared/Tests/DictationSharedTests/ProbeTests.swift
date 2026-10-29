import XCTest
@testable import DictationShared
final class ProbeTests: XCTestCase {
    func testFreshHeartbeatRequiresRunningAudioAndNonnegativeAge() {
        let snapshot = ProbeSnapshot(sessionID: UUID(), tick: 1, uptime: 10, elapsed: 2, audioCallbacks: 1, echoedPing: nil, active: true)
        XCTAssertTrue(snapshot.isFresh(at: 12.9))
        XCTAssertFalse(snapshot.isFresh(at: 13))
        XCTAssertFalse(snapshot.isFresh(at: 9))
    }
    func testStoppedAndSilentEngineNeverAppearReady() {
        var snapshot = ProbeSnapshot(sessionID: UUID(), tick: 1, uptime: 10, elapsed: 2, audioCallbacks: 0, echoedPing: nil, active: true)
        XCTAssertFalse(snapshot.isFresh(at: 10))
        snapshot.audioCallbacks = 2
        snapshot.active = false
        XCTAssertFalse(snapshot.isFresh(at: 10))
    }
    func testSessionExpiresAtFiveMinutes() {
        XCTAssertTrue(ProbeSnapshot.withinSession(start: 10, now: 309.9))
        XCTAssertFalse(ProbeSnapshot.withinSession(start: 10, now: 310))
        XCTAssertFalse(ProbeSnapshot.withinSession(start: 10, now: 9))
    }
    func testSnapshotAndPingRoundTripAndRejectCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProbeStore(directory: directory)
        let id = UUID()
        try store.writePing(ProbePing(sessionID: id, id: id))
        XCTAssertEqual(try store.readPing()?.id, id)
        let snapshot = ProbeSnapshot(sessionID: id, tick: 3, uptime: 20, elapsed: 4, audioCallbacks: 50, echoedPing: id, active: true)
        try store.writeSnapshot(snapshot)
        XCTAssertEqual(try store.readSnapshot(), snapshot)
        try Data("bad".utf8).write(to: directory.appendingPathComponent("probe-state.json"))
        XCTAssertThrowsError(try store.readSnapshot())
    }
    func testStaleHeartbeatIsDistinctFromExplicitEnd() {
        var snapshot = ProbeSnapshot(sessionID: UUID(), tick: 1, uptime: 10, elapsed: 5, audioCallbacks: 3, echoedPing: nil, active: true)
        XCTAssertEqual(snapshot.unavailableReason(at: 14), "Companion stopped responding (heartbeat 4s old)")
        snapshot.active = false
        snapshot.endReason = "Session expired"
        snapshot.endedAt = 15
        XCTAssertEqual(snapshot.unavailableReason(at: 20), "Ended: Session expired at uptime 15s")
    }
    func testMicrophoneActivationValidation() {
        XCTAssertTrue(ProbeSnapshot.canActivate(isBackground: false, channels: 1, sampleRate: 48000))
        XCTAssertFalse(ProbeSnapshot.canActivate(isBackground: true, channels: 1, sampleRate: 48000))
        XCTAssertFalse(ProbeSnapshot.canActivate(isBackground: false, channels: 0, sampleRate: 48000))
        XCTAssertFalse(ProbeSnapshot.canActivate(isBackground: false, channels: 1, sampleRate: 0))
    }
    func testWriteFailurePropagates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ProbeStore(directory: directory)
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.writePing(ProbePing(sessionID: UUID(), id: UUID())))
    }
}
