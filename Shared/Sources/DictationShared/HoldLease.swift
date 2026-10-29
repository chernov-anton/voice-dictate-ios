import Foundation

public struct HoldLease: Codable, Sendable {
    public let sessionID: UUID
    public let utteranceID: UUID
    public let controllerID: UUID
    public let at: TimeInterval
    public let held: Bool
    public init(sessionID: UUID, utteranceID: UUID, controllerID: UUID, at: TimeInterval, held: Bool) {
        self.sessionID = sessionID; self.utteranceID = utteranceID
        self.controllerID = controllerID; self.at = at; self.held = held
    }
    public func isLive(for snapshot: SessionSnapshot, now: TimeInterval) -> Bool {
        held && sessionID == snapshot.sessionID && utteranceID == snapshot.utteranceID &&
        controllerID == snapshot.recordingControllerID && at.isFinite && now.isFinite &&
        now >= at && now - at < 1
    }
}
