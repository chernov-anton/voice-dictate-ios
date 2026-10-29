import Foundation

/// The companion's "Stay ready" choice, persisted in the app's own defaults.
/// Only the app reads it; the keyboard sees the resulting `availabilityEndsAt` in the session snapshot.
public enum AvailabilitySetting {
    public static let choices: [TimeInterval] = [300, 900, 3600]
    public static let defaultSeconds: TimeInterval = 300
    static let key = "availabilitySeconds"

    /// The saved choice, or the default when nothing (or an unsupported value) is stored.
    public static func load(from defaults: UserDefaults) -> TimeInterval {
        let stored = defaults.double(forKey: key)
        return choices.contains(stored) ? stored : defaultSeconds
    }

    public static func save(_ seconds: TimeInterval, to defaults: UserDefaults) {
        guard choices.contains(seconds) else { return }
        defaults.set(seconds, forKey: key)
    }
}
