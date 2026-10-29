import Foundation

public struct ProbeSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var tick: Int
    public var uptime: TimeInterval
    public var elapsed: TimeInterval
    public var audioCallbacks: UInt64
    public var echoedPing: UUID?
    public var endReason: String?
    public var endedAt: TimeInterval?
    public var active: Bool
    public init(sessionID: UUID, tick: Int, uptime: TimeInterval, elapsed: TimeInterval, audioCallbacks: UInt64, echoedPing: UUID?, active: Bool) {
        self.sessionID = sessionID; self.tick = tick; self.uptime = uptime
        self.elapsed = elapsed; self.audioCallbacks = audioCallbacks
        self.echoedPing = echoedPing; self.active = active
    }
    public static func canActivate(isBackground: Bool, channels: UInt32, sampleRate: Double) -> Bool {
        !isBackground && channels > 0 && sampleRate.isFinite && sampleRate > 0
    }
    public func unavailableReason(at now: TimeInterval) -> String? {
        if !active {
            return "Ended: \(endReason ?? "Session ended") at uptime \(Int(endedAt ?? uptime))s"
        }
        guard now >= uptime else { return "Unavailable: clock/session changed. Reactivate in the app." }
        if now - uptime >= 3 {
            return "Companion stopped responding (heartbeat \(Int(now - uptime))s old)"
        }
        if audioCallbacks == 0 { return "Waiting for microphone audio callbacks" }
        return nil
    }
    public func isFresh(at now: TimeInterval) -> Bool {
        active && audioCallbacks > 0 && now >= uptime && now - uptime < 3
    }
    public static func withinSession(start: TimeInterval, now: TimeInterval) -> Bool {
        now >= start && now - start < 300
    }
}

public struct ProbePing: Codable, Sendable {
    public let sessionID: UUID
    public let id: UUID
    public init(sessionID: UUID, id: UUID) { self.sessionID = sessionID; self.id = id }
}
