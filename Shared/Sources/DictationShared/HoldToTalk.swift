import Foundation

/// Release can precede Start acknowledgement. Never overwrite an unacknowledged Start.
public struct HoldToTalk {
    public private(set) var sessionID: UUID?
    public private(set) var utteranceID: UUID?
    public private(set) var released = false
    private var stopSent = false
    public init() {}
    /// The finger is down on the pad for an utterance (Start sent or pending) and not yet lifted.
    public var isHeld: Bool { utteranceID != nil && !released }
    public mutating func begin(sessionID: UUID, utteranceID: UUID) {
        self.sessionID = sessionID; self.utteranceID = utteranceID
        released = false; stopSent = false
    }
    public mutating func release() { released = true }
    public mutating func stopIfReady(snapshot: SessionSnapshot, awaitingAcknowledgement: Bool, now: TimeInterval, controllerID: UUID) -> Command? {
        guard released, !stopSent, !awaitingAcknowledgement,
              snapshot.sessionID == sessionID, snapshot.utteranceID == utteranceID,
              snapshot.phase == .recording, let utteranceID else { return nil }
        stopSent = true
        return Command(sessionID: snapshot.sessionID, utteranceID: utteranceID, issuedAt: now, kind: .stop, controllerID: controllerID)
    }
    public mutating func stopWriteFailed() { stopSent = false }
    public mutating func reset() { self = Self() }
}
