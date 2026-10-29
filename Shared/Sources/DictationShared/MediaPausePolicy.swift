import Foundation

/// Audio-session category options this app uses, named independently of AVFAudio so the policy can be
/// unit-tested on macOS. Bluetooth HFP is deliberately not representable: the microphone stays on the built-in
/// mic (HFP would switch input to a narrow-band headset mic, as the Mac app's `useBuiltInMic` avoids).
public enum SessionOption: String, CaseIterable, Codable, Sendable {
    case mixWithOthers, duckOthers, defaultToSpeaker, allowBluetoothA2DP
}

/// MediaRemote transport commands (`kMRPlay`, `kMRPause`).
public enum MediaRemoteCommand: String, Codable, Sendable {
    case play, pause
    public var code: UInt32 { self == .play ? 0 : 1 }
}

/// What mediaremoted answered to one command. `handled` is true when a handler status is 0 (success), nil when the
/// reply wasn't a status array; `reply` is its description for the log.
public struct MediaRemoteSendResult: Codable, Equatable, Sendable {
    public var replied: Bool
    public var handled: Bool?
    public var reply: String?
    public init(replied: Bool, handled: Bool?, reply: String?) { self.replied = replied; self.handled = handled; self.reply = reply }
}

/// The Now Playing app as MediaRemote reports it; nil fields were unavailable (missing symbol, no answer in time).
/// Unentitled processes may get false/0/nil here even while something plays, so it is logged and only ever
/// used as an extra "yes, playing" signal.
public struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    public var isPlaying: Bool?
    public var pid: Int32?
    public var bundle: String?
    public init(isPlaying: Bool? = nil, pid: Int32? = nil, bundle: String? = nil) { self.isPlaying = isPlaying; self.pid = pid; self.bundle = bundle }
    public var summary: String { "np=\(isPlaying.map(String.init) ?? "?") pid=\(pid.map(String.init) ?? "?") bundle=\(bundle ?? "?")" }
}

/// Keyboard → companion: send `command` through the companion's MediaRemote (App Group `media-request.json`).
public struct MediaRemoteRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var command: MediaRemoteCommand
    /// `ProcessInfo.systemUptime`, shared by both processes.
    public var issuedAt: TimeInterval
    public init(id: UUID = UUID(), command: MediaRemoteCommand, issuedAt: TimeInterval) { self.id = id; self.command = command; self.issuedAt = issuedAt }
    /// How long the companion may still send a request. Well inside the keyboard's `MediaPausePolicy.companionWait`,
    /// so a command still unanswered when the keyboard gives up can never be sent afterwards.
    public static let ttl: TimeInterval = 0.5
    /// The companion checks this when it picks a request up and again right before sending it.
    public func isFresh(at now: TimeInterval) -> Bool {
        issuedAt.isFinite && now.isFinite && now >= issuedAt && now - issuedAt < Self.ttl
    }
}

/// Companion → keyboard: what the companion did with a request (App Group `media-reply.json`).
public struct MediaRemoteReply: Codable, Equatable, Sendable {
    public var requestID: UUID
    /// False when the companion's MediaRemote couldn't send (symbols missing).
    public var sent: Bool
    public var result: MediaRemoteSendResult?
    public var missing: [String]
    public init(requestID: UUID, sent: Bool, result: MediaRemoteSendResult?, missing: [String]) {
        self.requestID = requestID; self.sent = sent; self.result = result; self.missing = missing
    }
}

/// Audio decisions for the companion's microphone session and for pausing other media while the pad is held.
public enum MediaPausePolicy {
    /// The companion's `.playAndRecord` session for the whole "Stay ready" window. Mixable, so other apps keep
    /// playing and their activations don't interrupt it; built-in speaker instead of the receiver (earpiece), and
    /// Bluetooth A2DP headphones for output while the built-in mic records.
    public static let microphoneOptions: Set<SessionOption> = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

    /// After a remote Pause, the first check that the other audio stopped and the last one (seconds).
    public static let firstVerify: TimeInterval = 0.3
    public static let keyboardWait: TimeInterval = 0.8
    /// The companion polls the App Group at 10 Hz, so its Pause gets a longer window: request TTL (0.5 s) plus
    /// mediaremoted's reply wait (0.3 s) plus margin. No reply by then means it was never sent.
    public static let companionWait: TimeInterval = 1.0

    /// One way to stop other audio during a hold, in fallback order.
    public enum Step: String, CaseIterable, Codable, Sendable {
        /// MediaRemote Pause from the keyboard process; undone with Play.
        case keyboardRemote
        /// MediaRemote Pause from the companion via an App Group request (for when the keyboard's sandbox blocks
        /// mediaremoted); undone with Play the same way.
        case companionRemote
        /// Keyboard `.playback` session, non-mixable: activation interrupts other audio; deactivation with
        /// `.notifyOthersOnDeactivation` sends interruption-ended `.shouldResume`.
        case interrupt
        /// Same session, mixable with `duckOthers`: lowers other audio while active; restored on deactivation.
        case duck

        public var isRemote: Bool { self == .keyboardRemote || self == .companionRemote }

        public var options: Set<SessionOption> {
            switch self {
            case .interrupt, .keyboardRemote, .companionRemote: return []
            case .duck: return [.duckOthers, .mixWithOthers]
            }
        }
    }

    /// Steps to try for one hold. Empty when nothing plays, so a quiet phone is never touched. The session steps
    /// need `otherAudioPlaying` (AVAudioSession's own signal; `secondaryAudioShouldBeSilencedHint` is true whenever
    /// the companion's mic session is active, so it is not a playback signal). The companion shares the
    /// keyboard's framework, so it is tried only when the symbols resolved, and only while it is live.
    public static func plan(otherAudioPlaying: Bool, nowPlayingIsPlaying: Bool?, remoteAvailable: Bool, companionLive: Bool) -> [Step] {
        guard otherAudioPlaying || nowPlayingIsPlaying == true else { return [] }
        var steps: [Step] = []
        if remoteAvailable { steps.append(.keyboardRemote); if companionLive { steps.append(.companionRemote) } }
        if otherAudioPlaying { steps += [.interrupt, .duck] }
        return steps
    }

    /// What one attempt achieved.
    public enum Outcome: Equatable, Sendable {
        /// Applied and the other audio is no longer playing (session steps: activated).
        case stopped
        /// Remote command reached a handler that accepted it, yet the audio still plays: another process's
        /// MediaRemote goes to the same Now Playing app, so the companion is skipped.
        case handled
        /// Remote command sent without a confirmed handler and the audio still plays.
        case noEffect
        /// Could not be applied at all.
        case failed
    }
}

/// What one hold changed, so its end undoes exactly that and nothing else.
public struct MediaPause: Sendable {
    /// What a hold end does: deactivate the keyboard's session step and/or send Play from the process whose Pause
    /// paused the Now Playing app.
    public struct Undo: Equatable, Sendable {
        public var deactivate: MediaPausePolicy.Step?
        public var play: MediaPausePolicy.Step?
        public init(deactivate: MediaPausePolicy.Step? = nil, play: MediaPausePolicy.Step? = nil) { self.deactivate = deactivate; self.play = play }
        public var isEmpty: Bool { deactivate == nil && play == nil }
    }

    /// The step that stopped the other audio.
    public private(set) var engaged: MediaPausePolicy.Step?
    /// The last remote step whose Pause was sent; if the audio stops before a session step runs, that Pause took
    /// effect late and is what gets undone.
    public private(set) var sentRemote: MediaPausePolicy.Step?
    /// The remote step whose Pause is known to have paused the Now Playing app, even if other audio kept playing
    /// (a second app) and a session step then took over: it still needs its Play.
    public private(set) var pausedRemote: MediaPausePolicy.Step?
    public init() {}

    /// Tries `plan` in order until one step stops the audio. A remote Pause that a handler accepted without the
    /// audio stopping counts as ours only if `nowPlayingWasPlaying` (MediaRemote said so before the hold), since
    /// otherwise the Now Playing app may have been idle and Play would start it. `stillPlaying` is consulted before
    /// each session step once a remote Pause was sent; `skipped` reports steps not attempted. No-op while engaged.
    @discardableResult
    public mutating func begin(_ plan: [MediaPausePolicy.Step], nowPlayingWasPlaying: Bool = false, stillPlaying: () -> Bool,
                               skipped: (MediaPausePolicy.Step, String) -> Void = { _, _ in },
                               attempt: (MediaPausePolicy.Step) -> MediaPausePolicy.Outcome) -> MediaPausePolicy.Step? {
        guard engaged == nil else { return engaged }
        var handled = false
        for step in plan {
            if step == .companionRemote && handled { skipped(step, "keyboard command was handled"); continue }
            if !step.isRemote, let sent = sentRemote, !stillPlaying() { engaged = sent; pausedRemote = sent; return sent }
            switch attempt(step) {
            case .stopped:
                if step.isRemote { sentRemote = step; pausedRemote = step }
                engaged = step; return step
            case .handled:
                sentRemote = step; handled = true
                if nowPlayingWasPlaying { pausedRemote = step }
            case .noEffect: sentRemote = step
            case .failed: break
            }
        }
        return nil
    }

    /// What to undo at hold end (empty if nothing took effect); always clears.
    public mutating func end() -> Undo {
        defer { engaged = nil; sentRemote = nil; pausedRemote = nil }
        return Undo(deactivate: engaged.flatMap { $0.isRemote ? nil : $0 }, play: pausedRemote)
    }
}
