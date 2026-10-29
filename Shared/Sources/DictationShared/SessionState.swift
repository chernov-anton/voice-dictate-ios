import Foundation

/// Session transitions reject completions from old sessions and utterances.
public struct SessionState {
    public private(set) var snapshot: SessionSnapshot
    private let started: TimeInterval
    private let availabilityDuration: TimeInterval
    private var recordingStarted: TimeInterval?
    private var outcomes: [UUID: CommandOutcome] = [:]
    private var outcomeOrder: [UUID] = []
    public init(now: TimeInterval, availabilityDuration: TimeInterval = 300) {
        self.availabilityDuration = availabilityDuration.isFinite ? max(1, availabilityDuration) : 300
        started = now
        snapshot = SessionSnapshot(sessionID: UUID(), heartbeatAt: now)
        snapshot.availabilityEndsAt = now + self.availabilityDuration
    }
    public mutating func apply(_ command: Command, now: TimeInterval) {
        tick(now: now)
        if let previous = outcomes[command.commandID] {
            snapshot.lastCommandOutcome = previous; return
        }
        var rejection: String?
        if command.version != 1 { rejection = "Unsupported command version" }
        else if command.sessionID != snapshot.sessionID { rejection = "Session changed" }
        else if !command.issuedAt.isFinite || !now.isFinite || now < command.issuedAt || now - command.issuedAt >= 3 {
            rejection = "Command expired"
        } else {
            switch command.kind {
            case .start:
                if ![.ready, .failed, .resultReady].contains(snapshot.phase) || !snapshot.microphoneAvailable { rejection = "Session is not ready" }
                else if command.utteranceID == snapshot.utteranceID { rejection = "Use a new recording ID" }
                else {
                    snapshot.result = nil; snapshot.endReason = nil; snapshot.warning = nil
                    snapshot.phase = .recording; snapshot.utteranceID = command.utteranceID
                    recordingStarted = now; snapshot.recordingStartedAt = now; snapshot.recordingControllerID = command.controllerID
                }
            case .stop:
                if snapshot.phase != .recording || snapshot.utteranceID != command.utteranceID { rejection = "Recording does not match" }
                else { finish(now: now) }
            }
        }
        let outcome = CommandOutcome(commandID: command.commandID, accepted: rejection == nil, reason: rejection)
        snapshot.lastCommandOutcome = outcome
        outcomes[command.commandID] = outcome; outcomeOrder.append(command.commandID)
        if outcomeOrder.count > 128 { outcomes.removeValue(forKey: outcomeOrder.removeFirst()) }
    }
    public mutating func tick(now: TimeInterval) {
        snapshot.heartbeatAt = now
        guard now.isFinite, now >= started else { end(reason: "Clock changed"); return }
        if snapshot.phase == .recording, let recordingStarted {
            if now - recordingStarted >= 300 { finish(now: now) }
        } else if now - started >= availabilityDuration {
            snapshot.microphoneAvailable = false
            if snapshot.phase == .ready { end(reason: "Microphone session expired") }
        }
    }
    private mutating func finish(now: TimeInterval) {
        guard snapshot.utteranceID != nil else { return }
        snapshot.phase = .transcribing; recordingStarted = nil; snapshot.recordingStartedAt = nil
        snapshot.microphoneAvailable = snapshot.microphoneAvailable && now - started < availabilityDuration
    }
    public mutating func warn(_ message: String) { snapshot.warning = message }
    public mutating func beginManualRetry(utteranceID: UUID) {
        guard !snapshot.microphoneAvailable, [.ended, .failed, .resultReady].contains(snapshot.phase) else { return }
        snapshot.utteranceID = utteranceID; snapshot.result = nil; snapshot.endReason = nil; snapshot.warning = nil
        snapshot.phase = .transcribing
    }
    public mutating func cleaning(sessionID: UUID, utteranceID: UUID) {
        guard matches(sessionID, utteranceID), snapshot.phase == .transcribing else { return }
        snapshot.phase = .cleaning
    }
    public mutating func complete(sessionID: UUID, utteranceID: UUID, text: String) {
        guard matches(sessionID, utteranceID), [.transcribing, .cleaning].contains(snapshot.phase) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(sessionID: sessionID, utteranceID: utteranceID, reason: "No speech detected."); return
        }
        snapshot.result = DictationResult(utteranceID: utteranceID, text: text)
        snapshot.phase = .resultReady
    }
    public mutating func fail(sessionID: UUID, utteranceID: UUID, reason: String) {
        guard matches(sessionID, utteranceID), [.recording, .transcribing, .cleaning].contains(snapshot.phase) else { return }
        snapshot.phase = .failed; snapshot.endReason = reason; recordingStarted = nil; snapshot.recordingStartedAt = nil
    }
    public mutating func disableMicrophone(reason: String) {
        snapshot.microphoneAvailable = false; snapshot.endReason = reason
        if snapshot.phase == .ready { snapshot.phase = .ended }
    }
    private func matches(_ session: UUID, _ utterance: UUID) -> Bool {
        snapshot.sessionID == session && snapshot.utteranceID == utterance
    }
    public mutating func consume(_ receipt: InsertionReceipt) {
        guard receipt.version == 1, receipt.state == .inserted,
              receipt.sessionID == snapshot.sessionID,
              receipt.resultID == snapshot.result?.id,
              receipt.utteranceID == snapshot.result?.utteranceID else { return }
        snapshot.result = nil; snapshot.utteranceID = nil
        snapshot.phase = snapshot.microphoneAvailable ? .ready : .ended
    }
    public mutating func end(reason: String) {
        snapshot.microphoneAvailable = false; snapshot.endReason = reason
        recordingStarted = nil; snapshot.recordingStartedAt = nil
        snapshot.phase = snapshot.result == nil ? .ended : .resultReady
    }
}
