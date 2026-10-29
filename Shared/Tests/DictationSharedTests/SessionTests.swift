import XCTest
@testable import DictationShared
final class SessionTests: XCTestCase {
    func testCommandSnapshotReceiptRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProbeStore(directory: directory)
        let state = SessionState(now: 0)
        let command = Command(sessionID: state.snapshot.sessionID, utteranceID: UUID(), issuedAt: 1, kind: .start)
        try store.writeCommand(command)
        XCTAssertEqual(try store.readCommand()?.commandID, command.commandID)
        try store.writeSession(state.snapshot)
        XCTAssertEqual(try store.readSession()?.sessionID, state.snapshot.sessionID)
        let receipt = InsertionReceipt(sessionID: command.sessionID, resultID: UUID(), utteranceID: command.utteranceID, controllerID: command.controllerID, documentID: UUID(), state: .attempted, at: 1)
        try store.writeReceipt(receipt)
        XCTAssertEqual(try store.readReceipt()?.state, .attempted)
        try Data("{bad".utf8).write(to: directory.appendingPathComponent("command.json"))
        XCTAssertThrowsError(try store.readCommand())
    }
    func testInterruptionRejectsCommandsAndAttemptDoesNotConsumeResult() {
        var state = SessionState(now: 0)
        let utterance = UUID()
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        state.end(reason: "Interrupted")
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 2, kind: .stop), now: 2)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
        XCTAssertEqual(state.snapshot.phase, .ended)
        var second = SessionState(now: 0)
        second.apply(Command(sessionID: second.snapshot.sessionID, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        second.apply(Command(sessionID: second.snapshot.sessionID, utteranceID: utterance, issuedAt: 2, kind: .stop), now: 2)
        second.complete(sessionID: second.snapshot.sessionID, utteranceID: utterance, text: "actual transcript")
        let result = second.snapshot.result!
        second.consume(InsertionReceipt(sessionID: second.snapshot.sessionID, resultID: result.id, utteranceID: utterance, controllerID: UUID(), documentID: UUID(), state: .attempted, at: 3))
        XCTAssertNotNil(second.snapshot.result)
    }
    func testClockReversalAndExactCommandExpiry() {
        var state = SessionState(now: 10)
        state.tick(now: 9)
        XCTAssertEqual(state.snapshot.endReason, "Clock changed")
        var fresh = SessionState(now: 0)
        fresh.apply(Command(sessionID: fresh.snapshot.sessionID, utteranceID: UUID(), issuedAt: 0, kind: .start), now: 3)
        XCTAssertFalse(fresh.snapshot.lastCommandOutcome!.accepted)
        XCTAssertEqual(fresh.snapshot.phase, .ready)
    }
    func testLateStopPreservesResultAndRejectsForeignReceipt() {
        var state = SessionState(now: 0)
        let utterance = UUID()
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 299, kind: .start), now: 299)
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 310, kind: .stop), now: 310)
        state.complete(sessionID: state.snapshot.sessionID, utteranceID: utterance, text: "actual transcript")
        let result = state.snapshot.result!
        XCTAssertFalse(state.snapshot.microphoneAvailable)
        state.end(reason: "Expired")
        XCTAssertEqual(state.snapshot.result, result)
        for (session, resultID) in [(UUID(), result.id), (state.snapshot.sessionID, UUID())] {
            state.consume(InsertionReceipt(sessionID: session, resultID: resultID, utteranceID: utterance, controllerID: UUID(), documentID: UUID(), state: .inserted, at: 311))
            XCTAssertEqual(state.snapshot.result, result)
        }
    }
    func testDuplicateStartAndMismatchedStop() {
        var state = SessionState(now: 0)
        let utterance = UUID()
        let start = Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 1, kind: .start)
        state.apply(start, now: 1)
        XCTAssertEqual(state.snapshot.phase, .recording)
        state.apply(start, now: 2)
        XCTAssertEqual(state.snapshot.utteranceID, utterance)
        let badStop = Command(sessionID: state.snapshot.sessionID, utteranceID: UUID(), issuedAt: 3, kind: .stop)
        state.apply(badStop, now: 3)
        XCTAssertEqual(state.snapshot.phase, .recording)
        XCTAssertEqual(state.snapshot.lastCommandOutcome?.accepted, false)
    }
    func testRejectsOldSessionVersionAndStaleCommands() {
        var state = SessionState(now: 0)
        var command = Command(sessionID: UUID(), utteranceID: UUID(), issuedAt: 0, kind: .start)
        state.apply(command, now: 1)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
        command.sessionID = state.snapshot.sessionID; command.version = 99
        state.apply(command, now: 1)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
        command.version = 1; command.commandID = UUID()
        state.apply(command, now: 10)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
        XCTAssertEqual(state.snapshot.phase, .ready)
    }
    func testRecordingSurvivesIdleExpiryButHasOwnLimit() {
        var state = SessionState(now: 0)
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: UUID(), issuedAt: 270, kind: .start), now: 270)
        state.tick(now: 301)
        XCTAssertEqual(state.snapshot.phase, .recording)
        state.tick(now: 570)
        XCTAssertEqual(state.snapshot.phase, .transcribing)
        XCTAssertNil(state.snapshot.result)
        XCTAssertFalse(state.snapshot.microphoneAvailable)
    }
    func testIdleExpiryAndHeartbeat() {
        var state = SessionState(now: 0)
        XCTAssertTrue(state.snapshot.isFresh(at: 2.9))
        XCTAssertFalse(state.snapshot.isFresh(at: 3))
        state.tick(now: 300)
        XCTAssertEqual(state.snapshot.phase, .ended)
    }
    func testStopProducesOneResultAndReceiptRetiresIt() {
        var state = SessionState(now: 0)
        let utterance = UUID()
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        let stop = Command(sessionID: state.snapshot.sessionID, utteranceID: utterance, issuedAt: 2, kind: .stop)
        state.apply(stop, now: 2)
        state.complete(sessionID: state.snapshot.sessionID, utteranceID: utterance, text: "actual transcript")
        let result = state.snapshot.result!
        state.apply(stop, now: 3)
        XCTAssertEqual(state.snapshot.result?.id, result.id)
        let receipt = InsertionReceipt(sessionID: state.snapshot.sessionID, resultID: result.id, utteranceID: utterance, controllerID: UUID(), documentID: UUID(), state: .inserted, at: 3)
        state.consume(receipt)
        XCTAssertNil(state.snapshot.result)
        XCTAssertEqual(state.snapshot.phase, .ready)
    }
    func testInsertionRequiresSameVisibleRequestAndNoPriorAttempt() {
        let session = UUID(), utterance = UUID(), document = UUID()
        let result = DictationResult(utteranceID: utterance, text: "probe")
        var gate = InsertionGate()
        XCTAssertFalse(gate.permits(sessionID: session, result: result, documentID: document, receipt: nil))
        gate.begin(sessionID: session, utteranceID: utterance, documentID: document)
        XCTAssertTrue(gate.permits(sessionID: session, result: result, documentID: document, receipt: nil))
        XCTAssertFalse(gate.permits(sessionID: session, result: result, documentID: UUID(), receipt: nil))
        let receipt = InsertionReceipt(sessionID: session, resultID: result.id, utteranceID: utterance, controllerID: UUID(), documentID: document, state: .attempted, at: 1)
        XCTAssertFalse(gate.permits(sessionID: session, result: result, documentID: document, receipt: receipt))
        gate.cancel()
        XCTAssertFalse(gate.permits(sessionID: session, result: result, documentID: document, receipt: nil))
    }
    func testProcessingSurvivesMicExpiryButExplicitEndRejectsLateCompletion() {
        var state = SessionState(now: 0)
        let session = state.snapshot.sessionID, utterance = UUID()
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 299, kind: .start), now: 299)
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 300, kind: .stop), now: 300)
        state.disableMicrophone(reason: "Expired")
        state.cleaning(sessionID: session, utteranceID: utterance)
        XCTAssertEqual(state.snapshot.phase, .cleaning)
        state.complete(sessionID: UUID(), utteranceID: utterance, text: "wrong session")
        XCTAssertNil(state.snapshot.result)
        state.end(reason: "User cancelled")
        state.complete(sessionID: session, utteranceID: utterance, text: "late")
        XCTAssertNil(state.snapshot.result)
        XCTAssertEqual(state.snapshot.phase, .ended)
    }
    func testFailureAndUnconsumedResultAllowNewRecording() {
        var state = SessionState(now: 0)
        let session = state.snapshot.sessionID, first = UUID(), second = UUID()
        state.apply(Command(sessionID: session, utteranceID: first, issuedAt: 1, kind: .start), now: 1)
        state.fail(sessionID: session, utteranceID: first, reason: "Connection failed")
        state.apply(Command(sessionID: session, utteranceID: second, issuedAt: 2, kind: .start), now: 2)
        XCTAssertTrue(state.snapshot.lastCommandOutcome!.accepted)
        state.apply(Command(sessionID: session, utteranceID: second, issuedAt: 3, kind: .stop), now: 3)
        state.complete(sessionID: session, utteranceID: first, text: "stale")
        XCTAssertNil(state.snapshot.result)
        state.complete(sessionID: session, utteranceID: second, text: "new")
        state.apply(Command(sessionID: session, utteranceID: UUID(), issuedAt: 4, kind: .start), now: 4)
        XCTAssertEqual(state.snapshot.phase, .recording)
        XCTAssertNil(state.snapshot.result)
    }
    func testStopCannotReenableInterruptedMicrophone() {
        var state = SessionState(now: 0)
        let session = state.snapshot.sessionID, utterance = UUID()
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        state.disableMicrophone(reason: "Interrupted")
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 2, kind: .stop), now: 2)
        state.complete(sessionID: session, utteranceID: utterance, text: "text")
        let result = state.snapshot.result!
        state.consume(InsertionReceipt(sessionID: session, resultID: result.id, utteranceID: utterance,
                      controllerID: UUID(), documentID: UUID(), state: .inserted, at: 3))
        XCTAssertFalse(state.snapshot.microphoneAvailable)
        XCTAssertEqual(state.snapshot.phase, .ended)
        state.apply(Command(sessionID: session, utteranceID: UUID(), issuedAt: 4, kind: .start), now: 4)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
    }
    func testReusedFailedUtteranceIDIsRejected() {
        var state = SessionState(now: 0)
        let session = state.snapshot.sessionID, utterance = UUID()
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        state.fail(sessionID: session, utteranceID: utterance, reason: "failed")
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 2, kind: .start), now: 2)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
    }
    func testLongAvailabilityDoesNotExtendUtteranceLimit() {
        var state = SessionState(now: 0, availabilityDuration: 3600)
        state.tick(now: 301)
        XCTAssertTrue(state.snapshot.microphoneAvailable)
        state.apply(Command(sessionID: state.snapshot.sessionID, utteranceID: UUID(), issuedAt: 302, kind: .start), now: 302)
        state.tick(now: 602)
        XCTAssertEqual(state.snapshot.phase, .transcribing)
        XCTAssertTrue(state.snapshot.microphoneAvailable)
        state.tick(now: 3600)
        XCTAssertFalse(state.snapshot.microphoneAvailable)
    }
}
