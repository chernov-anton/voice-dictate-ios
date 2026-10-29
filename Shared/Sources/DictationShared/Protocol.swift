import Foundation

public struct Command: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case start, stop }
    public var version = 1
    public var sessionID: UUID
    public var commandID = UUID()
    public var controllerID: UUID
    public var utteranceID: UUID
    public var issuedAt: TimeInterval
    public var kind: Kind
    public init(sessionID: UUID, utteranceID: UUID, issuedAt: TimeInterval, kind: Kind, controllerID: UUID = UUID()) {
        self.sessionID = sessionID; self.utteranceID = utteranceID
        self.issuedAt = issuedAt; self.kind = kind; self.controllerID = controllerID
    }
}
public struct CommandOutcome: Codable, Sendable {
    public let commandID: UUID
    public let accepted: Bool
    public let reason: String?
}
public struct DictationResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let utteranceID: UUID
    public let text: String
    public init(utteranceID: UUID, text: String) {
        id = UUID(); self.utteranceID = utteranceID; self.text = text
    }
}
public struct SessionSnapshot: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case ready, recording, transcribing, cleaning, failed, resultReady, ended }
    public var version = 1
    public var sessionID: UUID
    public var phase: Phase = .ready
    public var heartbeatAt: TimeInterval
    public var microphoneAvailable = true
    public var utteranceID: UUID?
    public var recordingControllerID: UUID?
    public var availabilityEndsAt: TimeInterval?
    public var recordingStartedAt: TimeInterval?
    public var lastCommandOutcome: CommandOutcome?
    public var result: DictationResult?
    public var endReason: String?
    public var warning: String?
    public func alreadyFinishing(_ command: Command) -> Bool {
        command.kind == .stop && command.sessionID == sessionID && command.utteranceID == utteranceID &&
        [.transcribing, .cleaning, .resultReady].contains(phase)
    }
    public func isFresh(at now: TimeInterval) -> Bool {
        version == 1 && heartbeatAt.isFinite && now.isFinite && now >= heartbeatAt && now - heartbeatAt < 3
    }
}
public struct InsertionReceipt: Codable, Sendable {
    public enum State: String, Codable, Sendable { case attempted, inserted }
    public var version = 1
    public let sessionID: UUID
    public let resultID: UUID
    public let utteranceID: UUID
    public let controllerID: UUID
    public let documentID: UUID
    public var state: State
    public let at: TimeInterval
    public init(sessionID: UUID, resultID: UUID, utteranceID: UUID, controllerID: UUID, documentID: UUID, state: State, at: TimeInterval) {
        self.sessionID = sessionID; self.resultID = resultID; self.utteranceID = utteranceID
        self.controllerID = controllerID; self.documentID = documentID; self.state = state; self.at = at
    }
}
