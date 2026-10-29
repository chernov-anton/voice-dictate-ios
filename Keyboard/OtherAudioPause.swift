import AVFoundation
import os
import DictationShared

/// Pauses other audio (a Safari video, Music) while the record pad is held and resumes it on release, like system
/// dictation, but only if this hold paused it. Fallback order (`MediaPausePolicy.plan`):
/// 1. `keyboardRemote`: MediaRemote Pause from this process, verified by the other audio stopping within 0.3–0.8 s;
///    undone with Play.
/// 2. `companionRemote`: the same from the companion through an App Group request, in case the keyboard sandbox
///    blocks mediaremoted; skipped when the keyboard's command was accepted by a handler (same Now Playing app).
/// 3. `interrupt`/`duck`: a play-only `.playback` session in this process (non-mixable, then `duckOthers`), only
///    while `isOtherAudioPlaying`; undone by deactivating with `.notifyOthersOnDeactivation`.
/// If the audio stops between a remote Pause and a session step, the Pause took effect late and is what gets undone.
/// The companion's microphone session is never touched. Every failure is logged and ignored.
/// Each step goes to os_log category `mediaPause` and to `Library/Caches/media-pause.jsonl` in the keyboard's
/// container (restarts past 64 KB): `step`, `ok`, `error`/`errorName`, `otherAudioPlaying`, `silenceSecondaryHint`
/// (logged, not used), `outputs`/`inputs` port types, `nowPlaying` (MediaRemote isPlaying/pid/bundle), `detail`.
@MainActor
final class OtherAudioPause {
    /// Per process: AVAudioSession is process-wide, so all controllers share one queue and one record of what a hold changed.
    nonisolated private static let worker = Worker()
    private var held = false

    /// Idempotent; acts on transitions only. `cause` says why a hold ended (touchUp, touchCancel, disappear, reset).
    func set(_ on: Bool, cause: String) {
        guard on != held else { return }
        held = on
        let worker = Self.worker
        worker.want(on)
        if on { worker.queue.async { worker.pause() } }
        else { worker.queue.async { worker.resume(cause: cause) } }
    }

    deinit {
        // A dismissed keyboard ends its hold in viewWillDisappear; this covers teardown without it.
        if held { let worker = Self.worker; worker.want(false); worker.queue.async { worker.resume(cause: "deinit") } }
    }

    /// Owns the blocking calls (session activation, MediaRemote waits; never on the main thread) and the log file.
    /// `state`, `generation` and `store` are only touched on `queue`; `wanted` is the main thread's latest hold state.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "voicedictate.mediaPause", qos: .userInitiated)
        private let log = Logger(subsystem: Identifiers.logSubsystem, category: "mediaPause")
        private let file = JSONLinesFile.caches("media-pause.jsonl")
        private let remote = MediaRemote.shared
        private var state = MediaPause()
        private var generation = 0
        private var store: ProbeStore?
        private let wantedLock = NSLock()
        private var wanted = false

        init() {
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).map(String.init) ?? "?"
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(String.init) ?? "-"
                self?.queue.async { self?.record("keyboardInterruption", detail: "type=\(type) options=\(options)") }
            }
        }

        func want(_ on: Bool) { wantedLock.lock(); wanted = on; wantedLock.unlock() }
        private var isWanted: Bool { wantedLock.lock(); defer { wantedLock.unlock() }; return wanted }
        private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

        func pause() {
            generation += 1
            let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
            let before = remote.nowPlaying(timeout: 0.15)
            let companion = liveCompanion()
            let plan = MediaPausePolicy.plan(otherAudioPlaying: other, nowPlayingIsPlaying: before.isPlaying,
                                             remoteAvailable: remote.canSend, companionLive: companion != nil)
            let symbols = remote.missing.isEmpty ? "all" : "missing:" + remote.missing.joined(separator: ",")
            record("hold", detail: (plan.isEmpty ? "nothing playing; skipped" : "plan=" + plan.map(\.rawValue).joined(separator: ","))
                   + " symbols=\(symbols) companion=\(companion != nil ? "live" : "absent")", nowPlaying: before)
            guard !plan.isEmpty else { return }
            // Only MediaRemote said "playing" (AVAudioSession didn't), so only it can say "stopped".
            let remoteGate = !other
            let engaged = state.begin(plan, nowPlayingWasPlaying: before.isPlaying == true, stillPlaying: { playing(remoteGate: remoteGate) },
                                      skipped: { step, why in record(step.rawValue, ok: false, detail: "skipped: \(why)") }) { step in
                guard isWanted else { record(step.rawValue, ok: false, detail: "skipped: hold already ended"); return .failed }
                switch step {
                case .keyboardRemote: return keyboardPause(remoteGate: remoteGate)
                case .companionRemote: return companion.map { companionPause($0, remoteGate: remoteGate) } ?? .failed
                case .interrupt, .duck: return activate(step)
                }
            }
            record("paused", ok: engaged != nil, detail: "via=\(engaged?.rawValue ?? "none") playOnRelease=\(state.pausedRemote?.rawValue ?? "none")")
            // Session steps: shows whether the other app actually stopped (its audio no longer reported as playing).
            if let engaged, !engaged.isRemote { check("afterPause", generation: generation, delay: 0.5) }
        }

        func resume(cause: String) {
            generation += 1
            let undo = state.end()
            guard !undo.isEmpty else { record("release", detail: "cause=\(cause); nothing to undo"); return }
            if let step = undo.deactivate {
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    record("deactivate", detail: "cause=\(cause) undo=\(step.rawValue)")
                } catch {
                    record("deactivate", error: error, detail: "cause=\(cause) undo=\(step.rawValue)")
                }
            }
            switch undo.play {
            case .keyboardRemote: keyboardPlay(cause: cause)
            case .companionRemote: companionPlay(cause: cause)
            case .interrupt, .duck, nil: break
            }
            check("afterResume", generation: generation, delay: 1.0)
        }

        // MARK: Steps

        private func keyboardPause(remoteGate: Bool) -> MediaPausePolicy.Outcome {
            let start = now
            guard let result = remote.send(.pause, timeout: MediaPausePolicy.firstVerify) else {
                record("keyboardRemote", ok: false, detail: "pause not sent"); return .failed
            }
            record("keyboardRemote", detail: "pause " + describe(result))
            return verify("keyboardRemoteVerify", since: start, wait: MediaPausePolicy.keyboardWait, remoteGate: remoteGate) {
                (result.handled == true ? .handled : .noEffect, "")
            }
        }

        private func companionPause(_ store: ProbeStore, remoteGate: Bool) -> MediaPausePolicy.Outcome {
            let start = now
            let request = MediaRemoteRequest(command: .pause, issuedAt: start)
            do { try store.writeMediaRequest(request) } catch {
                record("companionRemote", error: error, detail: "request write failed"); return .failed
            }
            record("companionRemote", detail: "pause requested id=\(request.id)")
            // A stop counts as the companion's only once it confirms it sent the Pause (the reply can trail the stop).
            let sentPause: () -> (Bool, String) = { [self] in
                var reply = try? store.readMediaReply()
                while reply?.requestID != request.id && now - start < MediaPausePolicy.companionWait {
                    Thread.sleep(forTimeInterval: 0.05); reply = try? store.readMediaReply()
                }
                let matching = reply?.requestID == request.id ? reply : nil
                return (matching?.sent == true, companionReplySummary(for: request.id, reply: matching))
            }
            return verify("companionRemoteVerify", since: start, wait: MediaPausePolicy.companionWait, remoteGate: remoteGate,
                          stopIsOurs: sentPause) { [self] in
                let reply = try? store.readMediaReply()
                let summary = companionReplySummary(for: request.id, reply: reply)
                // No reply by now means the request went stale unsent (the companion re-checks its TTL right before
                // sending), so no Pause of ours can still land.
                guard let reply, reply.requestID == request.id, reply.sent else { return (.failed, summary) }
                return (reply.result?.handled == true ? .handled : .noEffect, summary)
            }
        }

        private func activate(_ step: MediaPausePolicy.Step) -> MediaPausePolicy.Outcome {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: step.options.categoryOptions)
                try session.setActive(true)
                record(step.rawValue)
                return .stopped
            } catch {
                record(step.rawValue, error: error)
                return .failed
            }
        }

        /// Asks the companion for Play and waits for its reply; if none comes (its session ended and it stopped
        /// polling, or the write failed), the keyboard sends Play itself. The companion keeps answering for a while
        /// after its microphone stops while a Pause it sent is outstanding.
        private func companionPlay(cause: String) {
            let start = now
            let request = MediaRemoteRequest(command: .play, issuedAt: start)
            guard let store = companionStore() else {
                record("companionRemotePlay", ok: false, detail: "cause=\(cause) no App Group; trying keyboard"); keyboardPlay(cause: cause); return
            }
            do { try store.writeMediaRequest(request) } catch {
                record("companionRemotePlay", error: error, detail: "cause=\(cause) request write failed; trying keyboard"); keyboardPlay(cause: cause); return
            }
            while now - start < MediaPausePolicy.companionWait {
                Thread.sleep(forTimeInterval: 0.1)
                if let reply = try? store.readMediaReply(), reply.requestID == request.id {
                    record("companionRemotePlay", ok: reply.sent, detail: "cause=\(cause) after \(milliseconds(since: start)) ms "
                           + companionReplySummary(for: request.id, reply: reply))
                    if !reply.sent { keyboardPlay(cause: cause) }
                    return
                }
            }
            record("companionRemotePlay", ok: false, detail: "cause=\(cause) no reply in \(milliseconds(since: start)) ms; trying keyboard")
            keyboardPlay(cause: cause)
        }

        private func keyboardPlay(cause: String) {
            let result = remote.send(.play, timeout: 0.3)
            record("keyboardRemotePlay", ok: result != nil, detail: "cause=\(cause) " + (result.map(describe) ?? "play not sent"))
        }

        /// Polls from `firstVerify` to `wait` after `start` (100 ms apart) until the other audio stops; `stopIsOurs`
        /// can veto crediting a stop to this attempt. If it never stops, `unstopped` classifies the attempt and adds log detail.
        private func verify(_ step: String, since start: TimeInterval, wait: TimeInterval, remoteGate: Bool,
                            stopIsOurs: (() -> (Bool, String))? = nil,
                            unstopped: () -> (MediaPausePolicy.Outcome, String)) -> MediaPausePolicy.Outcome {
            var offset = MediaPausePolicy.firstVerify
            while true {
                let delay = start + offset - now
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if !playing(remoteGate: remoteGate) {
                    let stoppedAfter = milliseconds(since: start)
                    let (ours, detail) = stopIsOurs?() ?? (true, "")
                    record(step, ok: ours, detail: "stopped after \(stoppedAfter) ms" + (ours ? "" : "; not credited") + (detail.isEmpty ? "" : " \(detail)"),
                           nowPlaying: remote.nowPlaying(timeout: 0.15))
                    return ours ? .stopped : .failed
                }
                if offset + 0.05 >= wait { break }
                offset += 0.1
            }
            let (outcome, detail) = unstopped()
            record(step, ok: false, detail: "still playing after \(milliseconds(since: start)) ms; outcome=\(outcome) \(detail)",
                   nowPlaying: remote.nowPlaying(timeout: 0.15))
            return outcome
        }

        // MARK: Helpers

        /// An unanswered MediaRemote query counts as still playing: unknown is not evidence that this hold stopped it.
        private func playing(remoteGate: Bool) -> Bool {
            if AVAudioSession.sharedInstance().isOtherAudioPlaying { return true }
            return remoteGate && remote.nowPlaying(timeout: 0.15).isPlaying != false
        }

        private func companionStore() -> ProbeStore? {
            if store == nil, let url = AppGroup.containerURL() { store = try? ProbeStore(directory: url) }
            return store
        }

        /// The App Group store if the companion's session heartbeat is fresh and its microphone is up.
        private func liveCompanion() -> ProbeStore? {
            guard let store = companionStore(), let session = try? store.readSession(),
                  session.isFresh(at: now), session.microphoneAvailable else { return nil }
            return store
        }

        private func companionReplySummary(for id: UUID, reply: MediaRemoteReply? = nil) -> String {
            guard let reply = reply ?? (try? companionStore()?.readMediaReply()), reply.requestID == id else { return "companion: no reply" }
            let missing = reply.missing.isEmpty ? "" : " missing=" + reply.missing.joined(separator: ",")
            return "companion: sent=\(reply.sent) " + (reply.result.map(describe) ?? "") + missing
        }

        private func describe(_ result: MediaRemoteSendResult) -> String {
            "replied=\(result.replied) handled=\(result.handled.map(String.init) ?? "?") reply=\(result.reply ?? "-")"
        }

        private func milliseconds(since start: TimeInterval) -> Int { Int(((now - start) * 1000).rounded()) }

        private func check(_ step: String, generation: Int, delay: TimeInterval) {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard self.generation == generation else { return }
                record(step, nowPlaying: remote.nowPlaying(timeout: 0.15))
            }
        }

        private func record(_ step: String, ok: Bool? = nil, error: Error? = nil, detail: String? = nil, nowPlaying: NowPlayingSnapshot? = nil) {
            let entry = AudioSessionLogEntry(step: step, session: AVAudioSession.sharedInstance(), ok: ok, error: error, detail: detail, nowPlaying: nowPlaying)
            let outcome = entry.ok ? "ok" : "error=\(entry.error ?? 0) \(entry.errorName ?? "")"
            log.notice("media pause \(step, privacy: .public) \(outcome, privacy: .public) other=\(entry.otherAudioPlaying ?? false) hint=\(entry.silenceSecondaryHint ?? false) out=\(entry.outputs?.joined(separator: ",") ?? "", privacy: .public) \(nowPlaying?.summary ?? "", privacy: .public) \(detail ?? "", privacy: .public)")
            file?.append(entry)
        }
    }
}
