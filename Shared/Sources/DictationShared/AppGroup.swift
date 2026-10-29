import Foundation

/// Resolves the App Group actually granted by the signing profile. Xcode signs
/// with the base identifier; SideStore re-signs with `<base>.<TEAMID>`.
public enum AppGroup {
    public enum Failure: Error, Equatable {
        case prefixMissing, profileMissing, profileMalformed, noMatchingGroup, ambiguousGroups
    }

    /// Resolved once per process from this bundle's embedded profile.
    public static let current: Result<String, Failure> = {
        guard let prefix = Identifiers.prefix else { return .failure(.prefixMissing) }
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        let data = url.flatMap { try? Data(contentsOf: $0) }
        #if targetEnvironment(simulator)
        let allowMissing = true
        #else
        let allowMissing = false
        #endif
        return resolve(base: Identifiers.appGroupBase(prefix: prefix), profile: data, allowMissingProfile: allowMissing)
    }()

    public static func containerURL() -> URL? {
        guard case .success(let id) = current else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Accepts exactly one profile group equal to `base` or `base.<alphanumeric>`.
    public static func resolve(base: String, profile: Data?, allowMissingProfile: Bool) -> Result<String, Failure> {
        guard let profile else { return allowMissingProfile ? .success(base) : .failure(.profileMissing) }
        guard let groups = applicationGroups(inProfile: profile) else { return .failure(.profileMalformed) }
        let matches = groups.filter { group in
            if group == base { return true }
            guard group.hasPrefix(base + ".") else { return false }
            let suffix = group.dropFirst(base.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(.noMatchingGroup)
        default: return .failure(.ambiguousGroups)
        }
    }

    /// A provisioning profile is CMS SignedData whose content is a plain XML plist;
    /// the signature is not verified here because the OS enforces entitlements.
    static func applicationGroups(inProfile data: Data) -> [String]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any] else { return nil }
        guard let raw = entitlements["com.apple.security.application-groups"] else { return [] }
        return raw as? [String]
    }
}
