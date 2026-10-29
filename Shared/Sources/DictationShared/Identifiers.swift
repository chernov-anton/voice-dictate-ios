import Foundation

/// Identifiers derived from the `VOICEDICTATE_ID_PREFIX` build setting (see VoiceDictate.xcconfig),
/// which project.yml writes into each target's Info.plist as `VoiceDictateIDPrefix`.
public enum Identifiers {
    public static let prefix: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "VoiceDictateIDPrefix") as? String
        return value?.isEmpty == false ? value : nil
    }()

    /// The App Group as Xcode signs it; SideStore may append `.<TEAMID>` (see `AppGroup`).
    public static func appGroupBase(prefix: String) -> String { "group.\(prefix).voicedictate.ios" }

    /// Keychain service of the companion's configuration item.
    public static func keychainService(prefix: String) -> String { "\(prefix).voicedictate.configuration" }

    /// os_log subsystem shared by the companion and the keyboard.
    public static let logSubsystem = "voicedictate"
}
