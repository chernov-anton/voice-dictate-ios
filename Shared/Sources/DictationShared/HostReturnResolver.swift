/// Picks the app to return to after a keyboard-triggered activation from timed samples of the system's
/// "current keyboard host" value. The value lags behind the URL receipt and can be stale, so a value that
/// merely repeats the receipt snapshot is trusted only after `staleGrace`.
public struct HostReturnResolver: Sendable {
    public enum Decision: Equatable, Sendable {
        case pending
        case target(String)
        case giveUp
    }
    public static let staleGrace: Double = 1.5
    public static let timeout: Double = 3.0

    private let ownPrefixes: [String]
    private let receipt: String?
    private var decided: Decision = .pending

    /// `ownBundleIDs` are this app and its keyboard; anything prefixed by one of them is never a target.
    public init(ownBundleIDs: [String], receipt: String?) {
        ownPrefixes = ownBundleIDs.filter { !$0.isEmpty }
        self.receipt = receipt
    }

    private func isForeign(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !ownPrefixes.contains(where: { value.hasPrefix($0) }) else { return nil }
        return value
    }

    /// Feeds one sample taken `elapsed` seconds after the URL receipt. The first non-pending decision sticks.
    public mutating func offer(_ sample: String?, at elapsed: Double) -> Decision {
        if decided != .pending { return decided }
        if let value = isForeign(sample), value != isForeign(receipt) || elapsed >= Self.staleGrace {
            decided = .target(value)
        } else if elapsed >= Self.timeout {
            decided = .giveUp
        }
        return decided
    }
}
