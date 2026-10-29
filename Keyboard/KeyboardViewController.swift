import UIKit
import SwiftUI
import DictationShared

final class KeyboardViewController: UIInputViewController {
    private let status = UILabel()
    private let message = UILabel()
    private let record = UIButton(type: .system)
    /// Built on first need: a cold launch with a live session never shows it, and SwiftUI hosting is the costliest view.
    private var activationView: UIView?
    /// Whether the activation link should be hidden; applied (building the link if needed) at the end of each refresh.
    private var activationHidden = false
    private var cachedStore: ProbeStore?
    private let stack = UIStackView()
    private var height: NSLayoutConstraint?
    private let recover = UIButton(type: .system)
    private let nextKeyboard = UIButton(type: .system)
    private var deleteRepeat: Timer?
    private let controllerID = UUID()
    private var timer: Timer?
    private var current: SessionSnapshot?
    private var pending: Command?
    private var gate = InsertionGate()
    private var visible = false
    private var inserting = false
    /// Every change re-evaluates the screen-awake request and the pause of other audio, so release/cancel/dismissal/error
    /// resets (including the companion ending the recording: cap, failure, interruption, End session) restore both.
    private var hold = HoldToTalk() {
        didSet {
            guard hold.isHeld != oldValue.isHeld else { return }
            awake.set(hold.isHeld, cause: holdEndCause)
            otherAudio.set(hold.isHeld, cause: holdEndCause)
        }
    }
    private let awake = ScreenAwake()
    private let otherAudio = OtherAudioPause()
    /// Why the next hold end happens, for the screen-awake log; anything not set by a gesture is a reset.
    private var holdEndCause = "reset"
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    override init(nibName: String?, bundle: Bundle?) {
        LaunchTiming.mark("init")
        super.init(nibName: nibName, bundle: bundle)
        Self.prewarmAppGroup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); Self.prewarmAppGroup() }
    /// Parses the embedded profile and looks up the container off the main thread before the first refresh needs them.
    private static func prewarmAppGroup() {
        DispatchQueue.global(qos: .userInitiated).async { _ = AppGroup.containerURL() }
    }

    override func viewDidLoad() {
        LaunchTiming.mark("viewDidLoad")
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        status.numberOfLines = 2; status.font = .systemFont(ofSize: 14, weight: .semibold)
        message.numberOfLines = 2; message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabel
        status.text = "Voice Dictate"
        var pad = UIButton.Configuration.filled()
        pad.title = "Hold to talk"; pad.subtitle = "Release to insert"
        pad.image = UIImage(systemName: "mic.fill")
        pad.imagePlacement = .leading; pad.imagePadding = 12
        pad.baseBackgroundColor = .systemIndigo; pad.cornerStyle = .large
        pad.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        record.configuration = pad
        record.accessibilityLabel = "Hold to dictate"
        record.accessibilityHint = "Hold while speaking, then release to finish."
        record.addTarget(self, action: #selector(beginHold), for: .touchDown)
        record.addTarget(self, action: #selector(endHold), for: [.touchUpInside, .touchUpOutside])
        record.addTarget(self, action: #selector(cancelHold), for: .touchCancel)
        styleKey(recover, title: "Insert transcript", symbol: "doc.on.clipboard")
        recover.addTarget(self, action: #selector(insertRecovery), for: .touchUpInside)
        styleKey(nextKeyboard, title: nil, symbol: "globe")
        nextKeyboard.accessibilityLabel = "Next keyboard"
        nextKeyboard.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = UIButton(type: .system); styleKey(space, title: nil, symbol: "space")
        space.accessibilityLabel = "Space"
        space.addTarget(self, action: #selector(addSpace), for: .touchUpInside)
        let enter = UIButton(type: .system); styleKey(enter, title: nil, symbol: "return")
        enter.accessibilityLabel = "Return"
        enter.addTarget(self, action: #selector(addReturn), for: .touchUpInside)
        let delete = DeleteKeyButton(type: .system); styleKey(delete, title: nil, symbol: "delete.left")
        delete.onAccessibilityActivate = { [weak self] in self?.deleteOnce() }
        delete.accessibilityLabel = "Delete"
        delete.addTarget(self, action: #selector(beginDelete), for: .touchDown)
        delete.addTarget(self, action: #selector(endDelete), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        let row = UIStackView(arrangedSubviews: [nextKeyboard, space, enter, delete])
        row.distribution = .fillEqually; row.spacing = 8
        [status, message, record, recover, row].forEach(stack.addArrangedSubview)
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // Placeholder until fitHeight() measures the visible content at the real width.
        let height = view.heightAnchor.constraint(equalToConstant: 264); height.priority = UILayoutPriority(999)
        self.height = height
        let padHeight = record.heightAnchor.constraint(greaterThanOrEqualToConstant: 88)
        padHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
            padHeight, row.heightAnchor.constraint(equalToConstant: 44), height
        ])
        LaunchTiming.mark("viewDidLoadEnd")
    }
    deinit { deleteRepeat?.invalidate() }
    override func viewWillLayoutSubviews() {
        // The system shows its own globe below the keyboard on devices that don't need ours.
        let hideNext = !needsInputModeSwitchKey
        if nextKeyboard.isHidden != hideNext { nextKeyboard.isHidden = hideNext }
        super.viewWillLayoutSubviews()
    }
    override func viewDidLayoutSubviews() {
        LaunchTiming.mark("layout")
        super.viewDidLayoutSubviews()
        fitHeight()
    }
    /// Sizes the keyboard to its visible rows so no blank band sits above the system globe/dictation bar.
    /// The stack's bottom is only `<=` the view's, so the measurement depends on width alone and converges.
    private func fitHeight() {
        let hideMessage = message.text?.isEmpty ?? true
        if message.isHidden != hideMessage { message.isHidden = hideMessage }
        let width = view.bounds.width - 24
        guard width > 0, let height else { return }
        let content = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let target = ceil(content) + 18
        if abs(height.constant - target) > 0.5 { height.constant = target }
    }
    private func syncActivation() {
        if activationHidden { activationView?.isHidden = true; return }
        if activationView == nil {
            let activation = UIHostingController(rootView: Link(destination: URL(string: "voicedictate://activate")!) {
                VStack(spacing: 4) {
                    Image(systemName: "mic.badge.plus").font(.system(size: 24))
                    Text("Activate microphone").font(.headline)
                    Text("Open Voice Dictate, then swipe back").font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
                .foregroundStyle(.white)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 18))
            })
            addChild(activation); activation.view.backgroundColor = .clear
            activation.sizingOptions = .intrinsicContentSize
            activationView = activation.view
            // Same slot as before: directly below the record pad.
            stack.insertArrangedSubview(activation.view, at: (stack.arrangedSubviews.firstIndex(of: record) ?? 2) + 1)
            activation.didMove(toParent: self)
        }
        activationView?.isHidden = false
    }
    private func styleKey(_ button: UIButton, title: String?, symbol: String) {
        var config = UIButton.Configuration.tinted()
        config.title = title; config.image = UIImage(systemName: symbol); config.imagePadding = 6
        config.baseForegroundColor = .label; config.baseBackgroundColor = .tertiarySystemFill
        config.cornerStyle = .medium
        button.configuration = config
    }
    override func viewWillAppear(_ animated: Bool) {
        LaunchTiming.mark("viewWillAppear")
        super.viewWillAppear(animated); visible = true
        refresh(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        LaunchTiming.mark("viewWillAppearEnd")
    }
    override func viewDidAppear(_ animated: Bool) {
        LaunchTiming.mark("viewDidAppear")
        super.viewDidAppear(animated)
        DispatchQueue.main.async { LaunchTiming.finish() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); visible = false
        gate.cancel(); holdEndCause = "disappear"; endHold(); endDelete()
        if pending == nil && hold.utteranceID == nil { timer?.invalidate(); timer = nil; current = nil }
    }
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        if !inserting { gate.cancel() }
    }
    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        if !inserting { gate.cancel() }
    }
    private func store() throws -> ProbeStore {
        guard hasFullAccess,
              let url = AppGroup.containerURL() else {
            throw NSError(domain: "Dictate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Full Access or App Group unavailable"])
        }
        if let cachedStore { return cachedStore }
        let files = try ProbeStore(directory: url)
        cachedStore = files
        return files
    }
    private func refresh() {
        if !visible && hold.utteranceID == nil && pending == nil { timer?.invalidate(); timer = nil; return }
        defer { syncActivation(); fitHeight() }
        recover.isHidden = true; current = nil
        guard hasFullAccess else {
            activationHidden = true; record.isHidden = true
            status.text = "Enable Full Access for Voice Dictate in keyboard settings."
            pending = nil; hold.reset(); gate.cancel(); return
        }
        do {
            let files = try store()
            guard let snapshot = try files.readSession(), snapshot.version == 1 else {
                activationHidden = false; record.isHidden = true
                status.text = "Activate the microphone to begin."; gate.cancel(); return
            }
            current = snapshot
            if let session = hold.sessionID, let utterance = hold.utteranceID,
               session == snapshot.sessionID,
               snapshot.utteranceID == utterance || (pending?.kind == .start && snapshot.phase == .ready) {
                try files.writeLease(HoldLease(sessionID: session, utteranceID: utterance, controllerID: controllerID,
                    at: ProcessInfo.processInfo.systemUptime, held: visible && !hold.released))
            }

            let fresh = snapshot.isFresh(at: ProcessInfo.processInfo.systemUptime)
            let usePad = (fresh && snapshot.microphoneAvailable) || hold.utteranceID != nil
            activationHidden = usePad
            record.isHidden = !usePad
            if let command = pending {
                if snapshot.sessionID != command.sessionID {
                    pending = nil; hold.reset(); gate.cancel(); message.text = "Session changed. Try again."
                } else if let outcome = snapshot.lastCommandOutcome, outcome.commandID == command.commandID {
                    pending = nil
                    if !outcome.accepted {
                        hold.reset()
                        if !snapshot.alreadyFinishing(command) { gate.cancel(); message.text = outcome.reason }
                    }
                    else if command.kind == .start && snapshot.phase == .recording { feedback.impactOccurred(); message.text = "Recording… Release when finished." }
                    else { hold.reset() }
                } else if ProcessInfo.processInfo.systemUptime - command.issuedAt >= 3 {
                    pending = nil; hold.reset(); gate.cancel(); message.text = "Command timed out. Check session status."
                }
            }
            status.text = !snapshot.microphoneAvailable ? (snapshot.endReason ?? "Session ended; result available for recovery") :
                (fresh ? "Dictation: \(snapshot.phase.rawValue)" : "Companion not responding. Reactivate in the app.")
            if fresh && snapshot.microphoneAvailable {
                if snapshot.phase == .ready, let deadline = snapshot.availabilityEndsAt {
                    let minutes = max(0, Int(ceil((deadline - ProcessInfo.processInfo.systemUptime) / 60)))
                    status.text = "Mic ready · \(minutes)m left · not recording"
                } else if snapshot.phase == .recording, let started = snapshot.recordingStartedAt {
                    let seconds = max(0, Int(ProcessInfo.processInfo.systemUptime - started))
                    status.text = String(format: "Recording · %d:%02d", seconds / 60, seconds % 60)
                }
            }
            if let warning = snapshot.warning { message.text = warning }
            if snapshot.phase == .failed {
                let reason = snapshot.endReason ?? "Failed"
                message.text = ["Recording too short.", "No speech detected. Record again.", "Hold to talk."].contains(reason)
                    ? "Hold to talk, then release when finished."
                    : reason + " End session in the app, then tap Retry."
            }
            if let stop = hold.stopIfReady(snapshot: snapshot, awaitingAcknowledgement: pending != nil,
                now: ProcessInfo.processInfo.systemUptime, controllerID: controllerID) {
                try files.writeCommand(stop); pending = stop
            }
            if hold.utteranceID != nil && pending == nil && [.transcribing, .cleaning, .resultReady, .failed, .ended].contains(snapshot.phase) { hold.reset() }
            let recording = snapshot.phase == .recording
            record.configuration?.title = recording ? "Release to finish" : "Hold to talk"
            record.configuration?.subtitle = recording ? "Listening…" : "Release to insert"
            record.configuration?.baseBackgroundColor = recording ? .systemRed : .systemIndigo
            record.isEnabled = hold.utteranceID != nil || (fresh && pending == nil && snapshot.microphoneAvailable && [.ready, .recording, .failed, .resultReady].contains(snapshot.phase))
            if let result = snapshot.result {
                let receipt = try files.readReceipt()
                let alreadyInserted = receipt?.sessionID == snapshot.sessionID && receipt?.resultID == result.id && receipt?.state == .inserted
                recover.isHidden = alreadyInserted
                if !alreadyInserted && snapshot.phase == .resultReady && gate.permits(sessionID: snapshot.sessionID, result: result,
                    documentID: textDocumentProxy.documentIdentifier, receipt: receipt) {
                    try insert(result, session: snapshot.sessionID, files: files)
                } else if !alreadyInserted {
                    let ambiguous = receipt?.sessionID == snapshot.sessionID && receipt?.resultID == result.id
                    recover.configuration?.title = ambiguous ? "Insert again (may duplicate)" : "Insert transcript"
                }
            }
        } catch { hold.stopWriteFailed(); gate.cancel(); message.text = "Shared-file error: \(error.localizedDescription)" }
    }
    @objc private func beginHold() {
        guard pending == nil, let snapshot = current, snapshot.isFresh(at: ProcessInfo.processInfo.systemUptime), snapshot.microphoneAvailable else { return }
        // An interrupted gesture can leave a recording visible; pressing it again requests Stop.
        if snapshot.phase == .recording, let utterance = snapshot.utteranceID {
            hold.begin(sessionID: snapshot.sessionID, utteranceID: utterance); endHold(); return
        }
        guard [.ready, .failed, .resultReady].contains(snapshot.phase) else { return }
        let utterance = UUID()
        let command = Command(sessionID: snapshot.sessionID, utteranceID: utterance,
            issuedAt: ProcessInfo.processInfo.systemUptime, kind: .start, controllerID: controllerID)
        do {
            let files = try store()
            try files.writeLease(HoldLease(sessionID: snapshot.sessionID, utteranceID: utterance,
                controllerID: controllerID, at: ProcessInfo.processInfo.systemUptime, held: true))
            try files.writeCommand(command); pending = command
            hold.begin(sessionID: snapshot.sessionID, utteranceID: utterance)
            gate.begin(sessionID: snapshot.sessionID, utteranceID: utterance, documentID: textDocumentProxy.documentIdentifier)
            feedback.prepare(); message.text = "Starting…"
        } catch { hold.reset(); gate.cancel(); message.text = "Could not start recording." }
    }
    @objc private func endHold() {
        if holdEndCause == "reset" { holdEndCause = "touchUp" }
        hold.release()
        holdEndCause = "reset"
        refresh()
    }
    @objc private func cancelHold() { holdEndCause = "touchCancel"; endHold() }
    private func insert(_ result: DictationResult, session: UUID, files: ProbeStore) throws {
        guard visible else { return }
        gate.cancel()
        var receipt = InsertionReceipt(sessionID: session, resultID: result.id, utteranceID: result.utteranceID,
            controllerID: controllerID, documentID: textDocumentProxy.documentIdentifier, state: .attempted,
            at: ProcessInfo.processInfo.systemUptime)
        try files.writeReceipt(receipt)
        inserting = true
        textDocumentProxy.insertText(InsertionSpacing.text(result.text, before: textDocumentProxy.documentContextBeforeInput,
            replacingSelection: !(textDocumentProxy.selectedText ?? "").isEmpty))
        inserting = false
        receipt.state = .inserted
        do { try files.writeReceipt(receipt); message.text = "Text inserted" }
        catch { message.text = "Insertion may have succeeded; acknowledgment failed. Use recovery only if text is missing."; return }
        recover.isHidden = true
    }
    @objc private func insertRecovery() {
        guard visible else { return }
        do {
            let files = try store()
            guard let snapshot = try files.readSession(), snapshot.version == 1,
                  let result = snapshot.result else { return }
            let receipt = try files.readReceipt()
            if receipt?.sessionID == snapshot.sessionID && receipt?.resultID == result.id && receipt?.state == .inserted { return }
            try insert(result, session: snapshot.sessionID, files: files)
        }
        catch { message.text = "Recovery error: \(error.localizedDescription)" }
    }
    @objc private func addSpace() { gate.cancel(); textDocumentProxy.insertText(" ") }
    @objc private func addReturn() { gate.cancel(); textDocumentProxy.insertText("\n") }
    /// Deletes one character on touch-down, then repeats while held; `.common` keeps it firing during tracking.
    @objc private func beginDelete() {
        endDelete(); deleteOnce()
        let timer = Timer(fire: Date().addingTimeInterval(0.5), interval: 0.08, repeats: true) { [weak self] _ in
            self?.deleteOnce()
        }
        RunLoop.main.add(timer, forMode: .common); deleteRepeat = timer
    }
    private func deleteOnce() { gate.cancel(); textDocumentProxy.deleteBackward() }
    @objc private func endDelete() { deleteRepeat?.invalidate(); deleteRepeat = nil }
}

/// Accessibility activation is a discrete action, not a physical held touch.
private final class DeleteKeyButton: UIButton {
    var onAccessibilityActivate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityActivate else { return super.accessibilityActivate() }
        onAccessibilityActivate()
        return true
    }
}
