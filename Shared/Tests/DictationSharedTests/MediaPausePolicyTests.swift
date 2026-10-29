import XCTest
@testable import DictationShared
final class MediaPausePolicyTests: XCTestCase {
    func testMicrophoneSessionMixesUsesSpeakerAndA2DPButNeverDucks() {
        XCTAssertEqual(MediaPausePolicy.microphoneOptions, [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        // Ducking or interrupting from the Stay-ready session would last the whole window and needs deactivation to undo.
        XCTAssertFalse(MediaPausePolicy.microphoneOptions.contains(.duckOthers))
    }
    typealias Step = MediaPausePolicy.Step
    func testSessionStepOptionsAndRemoteSteps() {
        XCTAssertEqual(Step.interrupt.options, [])
        XCTAssertEqual(Step.duck.options, [.duckOthers, .mixWithOthers])
        XCTAssertEqual(Step.allCases.filter(\.isRemote), [.keyboardRemote, .companionRemote])
    }
    func testCommandCodesMatchMediaRemote() {
        XCTAssertEqual(MediaRemoteCommand.play.code, 0)
        XCTAssertEqual(MediaRemoteCommand.pause.code, 1)
    }
    func testPlanPrefersRemoteThenCompanionThenSession() {
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: true, nowPlayingIsPlaying: nil, remoteAvailable: true, companionLive: true),
                       [.keyboardRemote, .companionRemote, .interrupt, .duck])
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: true, nowPlayingIsPlaying: false, remoteAvailable: true, companionLive: false),
                       [.keyboardRemote, .interrupt, .duck])
    }
    func testWithoutMediaRemoteSymbolsOnlySessionStepsRunAndCompanionIsNotAsked() {
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: true, nowPlayingIsPlaying: nil, remoteAvailable: false, companionLive: true),
                       [.interrupt, .duck])
    }
    func testSessionStepsNeedOtherAudioPlaying() {
        // Only MediaRemote says playing (e.g. a route AVAudioSession doesn't report): remote steps only.
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: false, nowPlayingIsPlaying: true, remoteAvailable: true, companionLive: true),
                       [.keyboardRemote, .companionRemote])
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: false, nowPlayingIsPlaying: true, remoteAvailable: false, companionLive: true), [])
    }
    func testPlanIsEmptyWhenNothingPlays() {
        // The old policy also fired on secondaryAudioShouldBeSilencedHint, which is true whenever the mic session is up.
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: false, nowPlayingIsPlaying: nil, remoteAvailable: true, companionLive: true), [])
        XCTAssertEqual(MediaPausePolicy.plan(otherAudioPlaying: false, nowPlayingIsPlaying: false, remoteAvailable: true, companionLive: true), [])
    }

    private func run(_ pause: inout MediaPause, _ plan: [Step], nowPlayingWasPlaying: Bool = false, playing: @escaping () -> Bool = { true },
                     outcomes: [Step: MediaPausePolicy.Outcome]) -> (engaged: Step?, tried: [Step], skipped: [Step]) {
        var tried: [Step] = [], skipped: [Step] = []
        let engaged = pause.begin(plan, nowPlayingWasPlaying: nowPlayingWasPlaying, stillPlaying: playing, skipped: { step, _ in skipped.append(step) }) { step in
            tried.append(step); return outcomes[step] ?? .failed
        }
        return (engaged, tried, skipped)
    }
    let full: [Step] = [.keyboardRemote, .companionRemote, .interrupt, .duck]

    func testKeyboardRemotePauseIsUndoneWithKeyboardPlay() {
        var pause = MediaPause()
        let result = run(&pause, full, outcomes: [.keyboardRemote: .stopped])
        XCTAssertEqual(result.engaged, .keyboardRemote)
        XCTAssertEqual(result.tried, [.keyboardRemote])
        XCTAssertEqual(pause.end(), MediaPause.Undo(play: .keyboardRemote))
        XCTAssertNil(pause.engaged); XCTAssertNil(pause.sentRemote); XCTAssertNil(pause.pausedRemote)
    }
    func testCompanionIsTriedWhenKeyboardCommandFailedOrWentUnanswered() {
        for keyboard in [MediaPausePolicy.Outcome.failed, .noEffect] {
            var pause = MediaPause()
            let result = run(&pause, full, outcomes: [.keyboardRemote: keyboard, .companionRemote: .stopped])
            XCTAssertEqual(result.engaged, .companionRemote)
            XCTAssertEqual(result.tried, [.keyboardRemote, .companionRemote])
            XCTAssertEqual(pause.end(), MediaPause.Undo(play: .companionRemote))
        }
    }
    func testCompanionIsSkippedWhenKeyboardCommandWasHandledWithoutEffect() {
        var pause = MediaPause()
        let result = run(&pause, full, outcomes: [.keyboardRemote: .handled, .interrupt: .stopped])
        XCTAssertEqual(result.tried, [.keyboardRemote, .interrupt])
        XCTAssertEqual(result.skipped, [.companionRemote])
        XCTAssertEqual(result.engaged, .interrupt)
        // MediaRemote couldn't say the Now Playing app was playing, so it may have been idle: no Play.
        XCTAssertEqual(pause.end(), MediaPause.Undo(deactivate: .interrupt))
    }
    func testHandledPauseOfAConfirmedPlayerIsResumedEvenAfterASessionStep() {
        // Two apps playing: Pause stopped the Now Playing app, the other kept isOtherAudioPlaying true.
        var pause = MediaPause()
        let result = run(&pause, full, nowPlayingWasPlaying: true, outcomes: [.keyboardRemote: .handled, .interrupt: .stopped])
        XCTAssertEqual(result.engaged, .interrupt)
        XCTAssertEqual(pause.end(), MediaPause.Undo(deactivate: .interrupt, play: .keyboardRemote))
    }
    func testHandledPauseIsResumedWhenEverySessionStepFails() {
        var pause = MediaPause()
        let result = run(&pause, full, nowPlayingWasPlaying: true, outcomes: [.keyboardRemote: .handled])
        XCTAssertNil(result.engaged)
        XCTAssertEqual(pause.end(), MediaPause.Undo(play: .keyboardRemote))
    }
    func testUnconfirmedNoEffectPauseIsNotResumed() {
        var pause = MediaPause()
        _ = run(&pause, full, nowPlayingWasPlaying: true, outcomes: [.keyboardRemote: .noEffect, .companionRemote: .noEffect, .interrupt: .stopped])
        XCTAssertEqual(pause.end(), MediaPause.Undo(deactivate: .interrupt))
    }
    func testLatePauseIsUndoneInsteadOfInterrupting() {
        var pause = MediaPause()
        // Audio stopped after the verify window but before the session step: the Pause worked, so Play undoes it.
        let result = run(&pause, full, playing: { false }, outcomes: [.keyboardRemote: .noEffect, .companionRemote: .failed])
        XCTAssertEqual(result.engaged, .keyboardRemote)
        XCTAssertEqual(result.tried, [.keyboardRemote, .companionRemote])
        XCTAssertEqual(pause.end(), MediaPause.Undo(play: .keyboardRemote))
    }
    func testFailedRemoteNeverClaimsALateStop() {
        var pause = MediaPause()
        var asked = false
        let result = run(&pause, full, playing: { asked = true; return false }, outcomes: [:])
        XCTAssertFalse(asked, "no Pause was sent, so stopped audio is not ours")
        XCTAssertEqual(result.tried, full)
        XCTAssertNil(result.engaged)
        XCTAssertTrue(pause.end().isEmpty)
    }
    func testFallsBackToDuckWhenInterruptFails() {
        var pause = MediaPause()
        let result = run(&pause, [.interrupt, .duck], outcomes: [.duck: .stopped])
        XCTAssertEqual(result.tried, [.interrupt, .duck])
        XCTAssertEqual(pause.end(), MediaPause.Undo(deactivate: .duck))
    }
    func testNothingToUndoWhenNothingPlays() {
        var pause = MediaPause()
        XCTAssertNil(pause.begin([], stillPlaying: { XCTFail("not asked"); return true }) { _ in XCTFail("no attempt expected"); return .stopped })
        XCTAssertTrue(pause.end().isEmpty)
    }
    func testBeginWhileEngagedDoesNotStackAndEndUndoesOnce() {
        var pause = MediaPause()
        pause.begin([.keyboardRemote], stillPlaying: { true }) { _ in .stopped }
        XCTAssertEqual(pause.begin([.interrupt], stillPlaying: { true }) { _ in XCTFail("must not retry while engaged"); return .stopped }, .keyboardRemote)
        XCTAssertEqual(pause.end(), MediaPause.Undo(play: .keyboardRemote))
        XCTAssertTrue(pause.end().isEmpty)
    }
    func testRequestsAreFreshOnlyBriefly() {
        let request = MediaRemoteRequest(command: .pause, issuedAt: 100)
        XCTAssertTrue(request.isFresh(at: 100))
        XCTAssertTrue(request.isFresh(at: 100 + MediaRemoteRequest.ttl - 0.01))
        XCTAssertFalse(request.isFresh(at: 100 + MediaRemoteRequest.ttl))
        // A request sent at the last fresh moment is answered (0.3 s reply wait) before the keyboard stops waiting.
        XCTAssertLessThan(MediaRemoteRequest.ttl + 0.3, MediaPausePolicy.companionWait)
        XCTAssertFalse(request.isFresh(at: 99), "clock went backwards")
        XCTAssertFalse(MediaRemoteRequest(command: .play, issuedAt: .nan).isFresh(at: 100))
    }
    func testRequestAndReplyRoundTripThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProbeStore(directory: dir)
        XCTAssertNil(try store.readMediaRequest()); XCTAssertNil(try store.readMediaReply())
        let request = MediaRemoteRequest(command: .play, issuedAt: 5)
        try store.writeMediaRequest(request)
        XCTAssertEqual(try store.readMediaRequest(), request)
        let reply = MediaRemoteReply(requestID: request.id, sent: true, result: MediaRemoteSendResult(replied: true, handled: true, reply: "[0]"), missing: [])
        try store.writeMediaReply(reply)
        XCTAssertEqual(try store.readMediaReply(), reply)
    }
}

final class AudioSessionLogTests: XCTestCase {
    func testFourCharCodes() {
        XCTAssertEqual(AudioSessionLogEntry.fourCharCode(560557684), "!int")
        XCTAssertEqual(AudioSessionLogEntry.fourCharCode(561145187), "!rec")
        XCTAssertNil(AudioSessionLogEntry.fourCharCode(-50))
        XCTAssertNil(AudioSessionLogEntry.fourCharCode(1))
    }
    func testAppendsDecodableLinesAndRestartsPastLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = JSONLinesFile(url: url, limit: 400)
        let first = AudioSessionLogEntry(step: "interrupt", ok: false, error: 560557684, errorDomain: "NSOSStatusErrorDomain",
                                         otherAudioPlaying: true, silenceSecondaryHint: true, outputs: ["Speaker"], inputs: [],
                                         nowPlaying: NowPlayingSnapshot(isPlaying: true, pid: 42, bundle: "com.apple.mobilesafari"), at: 1, pid: 7)
        file.append(first)
        file.append(AudioSessionLogEntry(step: "deactivate", at: 2, pid: 7))
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoded = try JSONDecoder().decode(AudioSessionLogEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(decoded.errorName, "!int")
        for _ in 0..<10 { file.append(first) }
        lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertLessThan(lines.count, 12)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 400 + 300)
    }
}
