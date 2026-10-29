import XCTest
@testable import DictationShared
final class HoldTests: XCTestCase {
    func testQuickReleaseWaitsForStartThenStopsExactlyOnce() {
        var state = SessionState(now: 0), hold = HoldToTalk()
        let session = state.snapshot.sessionID, utterance = UUID(), controller = UUID()
        hold.begin(sessionID: session, utteranceID: utterance); hold.release()
        XCTAssertNil(hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: true, now: 1, controllerID: controller))
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        XCTAssertNil(hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: true, now: 1, controllerID: controller))
        let stop = hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: false, now: 2, controllerID: controller)
        XCTAssertEqual(stop?.kind, .stop)
        XCTAssertNil(hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: false, now: 2, controllerID: controller))
    }
    func testHoldingDoesNotStopAndForeignSessionIsIgnored() {
        var state = SessionState(now: 0), hold = HoldToTalk()
        let utterance = UUID(), session = state.snapshot.sessionID
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        hold.begin(sessionID: session, utteranceID: utterance)
        XCTAssertNil(hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: false, now: 2, controllerID: UUID()))
        hold.begin(sessionID: UUID(), utteranceID: utterance); hold.release()
        XCTAssertNil(hold.stopIfReady(snapshot: state.snapshot, awaitingAcknowledgement: false, now: 2, controllerID: UUID()))
    }
}
extension HoldTests {
    func testIsHeldOnlyBetweenBeginAndReleaseOrReset() {
        var hold = HoldToTalk()
        XCTAssertFalse(hold.isHeld)
        hold.begin(sessionID: UUID(), utteranceID: UUID())
        XCTAssertTrue(hold.isHeld)
        hold.stopWriteFailed()
        XCTAssertTrue(hold.isHeld)
        hold.release()
        XCTAssertFalse(hold.isHeld)
        hold.begin(sessionID: UUID(), utteranceID: UUID())
        hold.reset()
        XCTAssertFalse(hold.isHeld)
        hold.release()
        XCTAssertFalse(hold.isHeld)
    }
    func testLeaseExpiresAndRejectsReleasedOrWrongController() {
        var state = SessionState(now: 0)
        let utterance = UUID(), controller = UUID(), session = state.snapshot.sessionID
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start, controllerID: controller), now: 1)
        let lease = HoldLease(sessionID: session, utteranceID: utterance, controllerID: controller, at: 1, held: true)
        XCTAssertTrue(lease.isLive(for: state.snapshot, now: 1.9))
        XCTAssertFalse(lease.isLive(for: state.snapshot, now: 2))
        XCTAssertFalse(lease.isLive(for: state.snapshot, now: 0.9))
        XCTAssertFalse(HoldLease(sessionID: session, utteranceID: utterance, controllerID: controller, at: 1, held: false).isLive(for: state.snapshot, now: 1))
        XCTAssertFalse(HoldLease(sessionID: session, utteranceID: utterance, controllerID: UUID(), at: 1, held: true).isLive(for: state.snapshot, now: 1))
    }
    func testLateStopAfterAutomaticStopPreservesCompletionIdentity() {
        var state = SessionState(now: 0)
        let session = state.snapshot.sessionID, utterance = UUID()
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 1, kind: .start), now: 1)
        state.apply(Command(sessionID: session, utteranceID: utterance, issuedAt: 2, kind: .stop), now: 2)
        let late = Command(sessionID: session, utteranceID: utterance, issuedAt: 2.1, kind: .stop)
        state.apply(late, now: 2.1)
        XCTAssertFalse(state.snapshot.lastCommandOutcome!.accepted)
        XCTAssertTrue(state.snapshot.alreadyFinishing(late))
        XCTAssertFalse(state.snapshot.alreadyFinishing(Command(sessionID: session, utteranceID: UUID(), issuedAt: 2.1, kind: .stop)))
        XCTAssertFalse(state.snapshot.alreadyFinishing(Command(sessionID: UUID(), utteranceID: utterance, issuedAt: 2.1, kind: .stop)))
    }
}
