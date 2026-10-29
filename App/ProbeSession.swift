import AVFoundation
import Combine
import UIKit
import DictationShared
import DictationCore
import DictationAudio

/// The tap and the main actor exchange only the current capture and callback count.
private final class CaptureSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: UtteranceCapture?
    private var count: UInt64 = 0
    func set(_ value: UtteranceCapture?) { lock.lock(); capture = value; lock.unlock() }
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); count &+= 1; let value = capture; lock.unlock()
        value?.append(buffer)
    }
    func callbacks() -> UInt64 { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class ProbeSession: ObservableObject {
    @Published var status = "Import your configuration to begin."
    @Published var active = false
    @Published var activating = false
    @Published var configured = false
    @Published var processing = false
    @Published var history: [RecoveryRecord] = []
    @Published var hasRetry = false
    @Published var recoveryBusy = false
    @Published var availabilitySeconds = AvailabilitySetting.load(from: .standard) {
        didSet { AvailabilitySetting.save(availabilitySeconds, to: .standard) }
    }
    private let configurationStore = ConfigurationStore()
    private var configuration: ConfigurationStore.Stored?
    private var recovery: RecoveryStore?
    private var engine: AVAudioEngine?
    private let slot = CaptureSlot()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var store: ProbeStore?
    private var state: SessionState?
    private var capture: UtteranceCapture?
    private var network: Task<String, Error>?
    private var processingTask: Task<Void, Never>?
    private var drain: Task<Void, Error>?
    private var attempt = UUID()
    private var networkFailure: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastCallbacks: UInt64 = 0
    private var lastAudioAt: TimeInterval = 0
    /// `Library/Caches/audio-session.jsonl`: activation (with the output route), interruptions, route and engine
    /// changes, deactivation. Pairs with the keyboard's `media-pause.jsonl` by timestamp.
    nonisolated private static let audioLog = JSONLinesFile.caches("audio-session.jsonl")
    nonisolated private static let audioLogQueue = DispatchQueue(label: "voicedictate.audioLog", qos: .utility)
    /// MediaRemote commands the keyboard asks for (see the keyboard's `OtherAudioPause`), run and logged off the main
    /// thread to `Library/Caches/media-pause.jsonl` here as `companionRemotePause`/`companionRemotePlay`.
    nonisolated private static let mediaQueue = DispatchQueue(label: "voicedictate.companionMedia", qos: .userInitiated)
    nonisolated private static let mediaLog = JSONLinesFile.caches("media-pause.jsonl")
    private var servedMediaRequest: UUID?
    /// A Pause was sent from here and no Play has been served since.
    private var mediaPauseOutstanding = false
    /// Commands dispatched to `mediaQueue` whose send and reply haven't finished; the grace task outlives them.
    private var mediaInFlight = 0
    private var mediaGrace: Timer?
    private var mediaGraceTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        do {
            configuration = try configurationStore.load(); configured = configuration != nil
            if configured { status = "Ready. Activate the microphone, then switch to your keyboard." }
        } catch let error as ConfigurationStore.StorageError { status = error.localizedDescription }
        catch { status = "Configuration is unreadable. Import it again." }
        prepareStorage()
        #if DEBUG
        importDevelopmentConfiguration()
        #endif
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                     NSNotification.Name.AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == AVAudioSession.interruptionNotification {
                        // Only this process's own session: the keyboard's pause session lives in another process.
                        if let session = note.object as? AVAudioSession, session !== AVAudioSession.sharedInstance() { return }
                        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                        let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "-"
                        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(String.init) ?? "-"
                        self.logAudio("interruption", detail: "type=\(raw.map(String.init) ?? "?") reason=\(reason) options=\(options) active=\(self.active)")
                        guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                    }
                    if note.name == .AVAudioEngineConfigurationChange {
                        guard let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
                        self.logAudio("engineConfigurationChange", detail: "active=\(self.active)")
                    }
                    if note.name == AVAudioSession.mediaServicesWereResetNotification { self.logAudio("mediaServicesReset") }
                    self.interrupt()
                }
            })
        }
        // Log only: shows whether the keyboard's pause session or a headphone change moved our route.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "-"
                self.logAudio("routeChange", detail: "reason=\(reason)")
            }
        })
    }
    #if DEBUG
    /// Local device-development transfer only: never bundled or copied through iCloud.
    private func importDevelopmentConfiguration() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let source = caches.appendingPathComponent("voice-dictate-import.json")
        if FileManager.default.fileExists(atPath: source.path) {
            do {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)
                configuration = try configurationStore.importFile(source); configured = true
                status = "Configuration saved securely. Ready to activate."
            } catch { status = "Development configuration import failed. Transfer it again while the phone is unlocked." }
            do { try FileManager.default.removeItem(at: source) }
            catch { status = "Configuration transfer file could not be removed. Reopen the app while unlocked." }
        }
        // Contains no keys, settings or user content; used to verify device setup.
        let report = "{\"configured\":\(configured),\"transferFileRemoved\":\(!FileManager.default.fileExists(atPath: source.path))}"
        try? Data(report.utf8).write(to: caches.appendingPathComponent("configuration-status.json"), options: [.atomic, .completeFileProtection])
    }
    #endif
    private func prepareStorage() {
        if recovery == nil {
            do { recovery = try RecoveryStore() }
            catch { status = "Recovery storage unavailable. Unlock the phone and try again." }
        }
        if let recovery {
            do { history = try recovery.read() }
            catch { status = "Saved history is unavailable. Unlock the phone and try again." }
        }
        if store == nil {
            do {
                guard let directory = AppGroup.containerURL() else {
                    status = "Keyboard sharing unavailable. App signing needs repair."; return
                }
                store = try ProbeStore(directory: directory)
            } catch { status = "Keyboard sharing unavailable. Unlock the phone and try again." }
        }
        updateRetry()
    }
    func importConfiguration(_ url: URL) {
        guard !active, !processing, !activating, !recoveryBusy else { return }
        do {
            configuration = try configurationStore.importFile(url); configured = true
            prepareStorage()
            status = "Configuration saved securely. You can delete the import file from Files."
        } catch let error as DictationFailure { status = error.rawValue }
        catch let error as ConfigurationStore.StorageError { status = error.localizedDescription }
        catch { status = "Could not read the selected configuration file." }
    }
    func activate() async {
        guard configured, !active, !activating, !processing, !recoveryBusy else { return }
        prepareStorage()
        guard store != nil, recovery != nil else { return }
        activating = true
        let request = UUID(); attempt = request
        if let drain { _ = try? await drain.value; self.drain = nil }
        guard attempt == request, activating else { return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard attempt == request, activating else { return }
        activating = false
        guard allowed else { status = "Enable microphone permission in Settings."; return }
        guard UIApplication.shared.applicationState != .background, store != nil else {
            status = "Return to this app to activate the microphone."; return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: MediaPausePolicy.microphoneOptions.categoryOptions)
            try audio.setActive(true)
            let engine = AVAudioEngine(); self.engine = engine
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureFailure.format }
            let slot = self.slot
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in slot.receive(buffer) }
            try engine.start()
            let now = ProcessInfo.processInfo.systemUptime
            state = SessionState(now: now, availabilityDuration: availabilitySeconds); active = true
            lastCallbacks = slot.callbacks(); lastAudioAt = now
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            persist()
            logAudio("activate", detail: "options=\(AVAudioSession.sharedInstance().categoryOptions.rawValue)")
            status = "Ready — hold the microphone pad in the Voice Dictate keyboard."
        } catch {
            logAudio("activate", error: error)
            end(reason: "Microphone activation failed. Try again in the app.")
        }
    }
    private func poll() {
        guard var state, let store else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if active {
            let count = slot.callbacks()
            if count != lastCallbacks { lastAudioAt = now; lastCallbacks = count }
            if now - lastAudioAt >= 3 { interrupt(); return }
        }
        serveMediaRequest(store)
        let previous = state.snapshot.phase
        state.tick(now: now)
        do {
            if let command = try store.readCommand() {
                // The other process can publish after tick's initial clock sample.
                state.apply(command, now: ProcessInfo.processInfo.systemUptime)
            }
            if let receipt = try store.readReceipt() { state.consume(receipt) }
        } catch {
            // Fail closed if keyboard IPC becomes unreadable while capturing.
            if previous == .recording {
                self.state = state; requestStop()
                if self.state?.snapshot.phase != .recording { stopRecording() }
            }
            status = "Keyboard sharing is unavailable. Unlock the phone."; return
        }
        self.state = state
        if state.snapshot.phase == .recording {
            let lease = try? store.readLease()
            if lease?.isLive(for: state.snapshot, now: ProcessInfo.processInfo.systemUptime) != true {
                if previous == .recording { requestStop() }
                else if let utterance = state.snapshot.utteranceID {
                    self.state?.fail(sessionID: state.snapshot.sessionID, utteranceID: utterance, reason: "Hold to talk.")
                }
            } else if previous != .recording { startRecording() }
        }
        if previous == .recording, state.snapshot.phase == .transcribing { stopRecording() }
        if !state.snapshot.microphoneAvailable && active { stopMicrophone() }
        persist()
    }
    private func startRecording() {
        guard let snapshot = state?.snapshot, let utterance = snapshot.utteranceID else { return }
        guard let engine, let configuration, let recovery else {
            state?.fail(sessionID: snapshot.sessionID, utteranceID: utterance, reason: "Recording unavailable. End the session and activate again.")
            persist(); return
        }
        let token = UUID(); attempt = token; networkFailure = nil
        do {
            let capture = try UtteranceCapture(format: engine.inputNode.outputFormat(forBus: 0), directory: recovery.directory,
                onFailure: { [weak self] error in Task { @MainActor in self?.captureFailed(error, token: token) } },
                onLimit: { [weak self] in Task { @MainActor in
                    guard self?.attempt == token else { return }; self?.requestStop()
                } }, onStreamOverflow: { [weak self] in Task { @MainActor in
                    guard let self, self.attempt == token else { return }
                    self.networkFailure = "Connection fell behind. Stop, then retry the saved recording in the app."
                    self.state?.warn("Streaming failed. Audio is being saved. Stop, then End session in the app and tap Retry.")
                    self.persist(); self.network?.cancel()
                } })
            self.capture = capture; slot.set(capture); hasRetry = true
            network = Task {
                do {
                    return try await RealtimeTranscription.transcribe(socket: OpenAISocket(key: configuration.credentials.openAIApiKey),
                        chunks: capture.chunks, settings: configuration.settings)
                } catch {
                    capture.detachStream()
                    if self.attempt == token {
                        self.networkFailure = self.networkFailure ?? (error as? DictationFailure)?.rawValue ?? "Transcription failed. Retry the saved recording."
                        self.status = "Recording saved locally. Stop, then End session in the app and tap Retry."
                        self.state?.warn(self.status); self.persist()
                    }
                    throw error
                }
            }
            status = "Recording… Release the keyboard microphone to finish."
        } catch {
            status = "Could not start recording. Check storage and microphone."
            state?.fail(sessionID: snapshot.sessionID, utteranceID: utterance, reason: status)
            persist()
        }
    }
    /// Runs the keyboard's fresh MediaRemote request once and answers in `media-reply.json`. MediaRemote talks to
    /// mediaremoted only; the microphone session is not touched.
    private func serveMediaRequest(_ store: ProbeStore) {
        guard let request = try? store.readMediaRequest(), request.id != servedMediaRequest,
              request.isFresh(at: ProcessInfo.processInfo.systemUptime) else { return }
        servedMediaRequest = request.id
        mediaPauseOutstanding = request.command == .pause
        mediaInFlight += 1
        Self.mediaQueue.async {
            defer { DispatchQueue.main.async { [weak self] in self?.mediaCommandFinished() } }
            let remote = MediaRemote.shared
            // Re-checked here: the keyboard stops waiting after `companionWait`, so a stale command must not go out.
            let fresh = request.isFresh(at: ProcessInfo.processInfo.systemUptime)
            let result = fresh ? remote.send(request.command, timeout: 0.3) : nil
            let reply = MediaRemoteReply(requestID: request.id, sent: result != nil, result: result, missing: remote.missing)
            var detail = "id=\(request.id) " + (result.map { "replied=\($0.replied) handled=\($0.handled.map(String.init) ?? "?") reply=\($0.reply ?? "-")" } ?? (fresh ? "not sent" : "stale; not sent"))
            do { try store.writeMediaReply(reply) } catch { detail += " replyWriteFailed" }
            if !remote.missing.isEmpty { detail += " missing=" + remote.missing.joined(separator: ",") }
            let step = request.command == .pause ? "companionRemotePause" : "companionRemotePlay"
            Self.mediaLog?.append(AudioSessionLogEntry(step: step, session: AVAudioSession.sharedInstance(), ok: result != nil,
                                                       detail: detail, nowPlaying: remote.nowPlaying(timeout: 0.15)))
        }
    }
    /// The session timer stops with the microphone (End session, interruption) and the app may then be suspended,
    /// but the keyboard sends its Play only once it sees the session end. While a Pause sent from here is
    /// outstanding (or a command is still being sent), keep answering for up to 2 s under a background task; the
    /// keyboard plays itself if no reply comes.
    private func mediaCommandFinished() {
        mediaInFlight -= 1
        if mediaGrace != nil, !mediaPauseOutstanding, mediaInFlight == 0 { endMediaGrace() }
    }
    private func startMediaGrace() {
        guard mediaPauseOutstanding || mediaInFlight > 0, mediaGrace == nil, let store else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        if mediaGraceTask == .invalid {
            mediaGraceTask = UIApplication.shared.beginBackgroundTask(withName: "Resume other audio") { [weak self] in
                MainActor.assumeIsolated { self?.endMediaGrace() }
            }
        }
        mediaGrace = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.serveMediaRequest(store)
                let idle = !self.mediaPauseOutstanding && self.mediaInFlight == 0
                if idle || ProcessInfo.processInfo.systemUptime >= deadline { self.endMediaGrace() }
            }
        }
    }
    private func endMediaGrace() {
        mediaGrace?.invalidate(); mediaGrace = nil; mediaPauseOutstanding = false
        if mediaGraceTask != .invalid { UIApplication.shared.endBackgroundTask(mediaGraceTask); mediaGraceTask = .invalid }
    }
    private func requestStop() {
        guard let snapshot = state?.snapshot, snapshot.phase == .recording, let utterance = snapshot.utteranceID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state?.apply(Command(sessionID: snapshot.sessionID, utteranceID: utterance, issuedAt: now, kind: .stop), now: now)
        stopRecording(); persist()
    }
    private func captureFailed(_ error: CaptureFailure, token: UUID) {
        guard attempt == token else { return }
        networkFailure = error.rawValue; network?.cancel(); requestStop()
    }
    private func stopRecording() {
        guard !processing, let snapshot = state?.snapshot, let utterance = snapshot.utteranceID else { return }
        guard let capture, let network, let configuration else {
            state?.fail(sessionID: snapshot.sessionID, utteranceID: utterance, reason: "Recording unavailable. End the session and activate again.")
            persist(); return
        }
        processing = true; slot.set(nil)
        beginBackgroundTask()
        let token = attempt
        let drain = Task { try await capture.stop() }; self.drain = drain
        processingTask = Task {
            do {
                try await drain.value
                guard token == self.attempt else { return }
                if let failure = self.networkFailure { throw PipelineFailure(message: failure) }
                guard await capture.streamIsComplete() else { throw PipelineFailure(message: self.networkFailure ?? "Streaming stopped. Retry the saved recording.") }
                let raw = try await network.value
                try Task.checkCancellation()
                guard token == self.attempt else { return }
                try await self.finish(raw: raw, configuration: configuration, snapshot: snapshot, utterance: utterance, token: token)
            } catch {
                network.cancel()
                guard token == self.attempt else { return }
                let message = self.networkFailure ?? (error as? PipelineFailure)?.message ?? (error as? CaptureFailure)?.rawValue ?? (error as? DictationFailure)?.rawValue ?? "Processing stopped. Retry the saved recording."
                self.state?.fail(sessionID: snapshot.sessionID, utteranceID: utterance, reason: message)
                self.status = message
            }
            guard token == self.attempt else { return }
            self.capture = nil; self.network = nil; self.drain = nil
            self.processing = false; self.processingTask = nil
            self.endBackgroundTask(); self.updateRetry(); self.persist()
        }
    }
    private struct PipelineFailure: Error { let message: String }
    private func finish(raw: String, configuration: ConfigurationStore.Stored, snapshot: SessionSnapshot, utterance: UUID, token: UUID) async throws {
        guard !raw.isEmpty else { throw PipelineFailure(message: "No speech detected. Record again.") }
        do { try saveRecord(id: utterance, raw: raw, text: raw, status: "Raw transcript saved; cleanup pending") }
        catch {
            state?.complete(sessionID: snapshot.sessionID, utteranceID: utterance, text: raw)
            status = "Raw transcript ready. History could not be saved; copy the text now. Audio retained."
            return
        }
        state?.cleaning(sessionID: snapshot.sessionID, utteranceID: utterance); status = "Cleaning…"; persist()
        let result = try await CleanupPolicy.clean(raw: raw, key: configuration.credentials.anthropicApiKey, settings: configuration.settings)
        try Task.checkCancellation()
        guard token == attempt else { return }
        do { try saveRecord(id: utterance, raw: raw, text: result.text, status: result.cleaned ? "Cleaned" : "Raw transcript — cleanup unavailable") }
        catch {
            state?.complete(sessionID: snapshot.sessionID, utteranceID: utterance, text: result.text)
            status = "Transcript ready. History could not be updated; copy the text now. Audio retained."
            return
        }
        state?.complete(sessionID: snapshot.sessionID, utteranceID: utterance, text: result.text)
        status = result.cleaned ? "Ready to insert." : "Raw transcript ready; cleanup was unavailable."
        if let recovery { try UtteranceCapture.discard(directory: recovery.directory) }
    }
    private func saveRecord(id: UUID, raw: String, text: String, status: String) throws {
        var records = history.filter { $0.id != id }
        records.insert(RecoveryRecord(id: id, raw: raw, text: text, status: status, date: Date()), at: 0)
        records = Array(records.prefix(10))
        guard let recovery else { throw PipelineFailure(message: "Recovery storage unavailable.") }
        history = records
        try recovery.save(records)
    }
    private func interrupt() {
        guard active else { return }
        requestStop()
        state?.disableMicrophone(reason: "Microphone interrupted. Activate again in the app.")
        stopMicrophone(); persist()
    }
    private func stopMicrophone() {
        active = false; slot.set(nil)
        let hadEngine = engine != nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            if hadEngine { logAudio("deactivate") }
        } catch { if hadEngine { logAudio("deactivate", error: error) } }
        if !processing { timer?.invalidate(); timer = nil }
        startMediaGrace()
    }
    func end(reason: String = "Session ended.") {
        attempt = UUID(); activating = false
        network?.cancel(); processingTask?.cancel(); network = nil; processingTask = nil
        if let capture { drain = Task { try await capture.stop() } }
        capture = nil; processing = false
        stopMicrophone(); timer?.invalidate(); timer = nil
        state?.end(reason: reason); status = reason; persist(); endBackgroundTask(); updateRetry()
    }
    private func logAudio(_ step: String, error: Error? = nil, detail: String? = nil) {
        let entry = AudioSessionLogEntry(step: step, session: AVAudioSession.sharedInstance(), error: error, detail: detail)
        Self.audioLogQueue.async { Self.audioLog?.append(entry) }
    }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            MainActor.assumeIsolated { self?.end(reason: "Background time expired. Recover text or retry audio in the app.") }
        }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func persist() {
        guard let state else { return }
        do { try store?.writeSession(state.snapshot) }
        catch { status = "Could not share the result. Unlock the phone; saved text is available in this app." }
    }
    private func updateRetry() {
        hasRetry = recovery.map { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("retry.pcm").path) } ?? false
    }
    func discardRetry() async {
        guard !active, !processing, !activating, !recoveryBusy else { return }
        recoveryBusy = true; defer { recoveryBusy = false }
        if let drain { _ = try? await drain.value; self.drain = nil }
        do { if let recovery { try UtteranceCapture.discard(directory: recovery.directory) }; updateRetry() }
        catch { status = "Could not delete saved audio." }
    }
    func retry() async {
        guard !active, !processing, !activating, !recoveryBusy else { return }
        recoveryBusy = true; defer { recoveryBusy = false }
        prepareStorage()
        guard let recovery, let configuration else { return }
        if let drain { _ = try? await drain.value; self.drain = nil }
        do {
            let data = try Data(contentsOf: recovery.directory.appendingPathComponent("retry.pcm"))
            guard (4800...14_400_000).contains(data.count) else { throw PipelineFailure(message: "Saved audio is too short. Record again.") }
            let token = UUID(); attempt = token
            var state = SessionState(now: ProcessInfo.processInfo.systemUptime)
            state.end(reason: "Manual retry")
            let utterance = UUID(); state.beginManualRetry(utteranceID: utterance)
            self.state = state; processing = true; beginBackgroundTask(); persist()
            let snapshot = state.snapshot
            let chunks = AsyncStream<Data> { continuation in
                for offset in stride(from: 0, to: data.count, by: 8192) {
                    continuation.yield(data.subdata(in: offset..<min(data.count, offset + 8192)))
                }
                continuation.finish()
            }
            processingTask = Task {
                do {
                    let raw = try await RealtimeTranscription.transcribe(socket: OpenAISocket(key: configuration.credentials.openAIApiKey), chunks: chunks, settings: configuration.settings)
                    try Task.checkCancellation()
                    guard self.attempt == token else { return }
                    try await self.finish(raw: raw, configuration: configuration, snapshot: snapshot, utterance: utterance, token: token)
                } catch {
                    guard self.attempt == token else { return }
                    self.status = (error as? DictationFailure)?.rawValue ?? "Retry failed. Saved audio remains available."
                    self.state?.fail(sessionID: snapshot.sessionID, utteranceID: utterance, reason: self.status)
                }
                guard self.attempt == token else { return }
                self.processing = false; self.processingTask = nil; self.endBackgroundTask(); self.updateRetry(); self.persist()
            }
        } catch { status = (error as? PipelineFailure)?.message ?? "Could not read saved audio." }
    }
}
