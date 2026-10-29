import Foundation
import Security
import DictationCore
import DictationShared

/// One app-only Keychain item makes replacing keys and their associated settings atomic.
/// No access-group override: the keyboard cannot retrieve this item.
struct ConfigurationStore {
    struct Stored: Codable {
        let credentials: APICredentials
        let settings: DictationSettings
    }
    enum StorageError: String, LocalizedError {
        case unavailable = "Could not access configuration. Unlock the phone and try again."
        case unreadable = "Configuration is unreadable. Import it again."
        case save = "Could not save configuration. Your previous configuration was kept."
        var errorDescription: String? { rawValue }
    }
    private func query() throws -> [String: Any] {
        guard let prefix = Identifiers.prefix else { throw StorageError.unavailable }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Identifiers.keychainService(prefix: prefix),
                kSecAttrAccount as String: "api-configuration",
                kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Stored? {
        var request = try query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.unavailable }
        guard let data = result as? Data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw StorageError.unreadable
        }
        return stored
    }
    @discardableResult func importData(_ data: Data) throws -> Stored {
        let imported = try ImportedConfiguration.decode(data)
        let stored = Stored(credentials: imported.credentials, settings: imported.settings)
        let encoded = try JSONEncoder().encode(stored)
        let values: [String: Any] = [kSecValueData as String: encoded,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let item = try query()
        var status = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.save }
        return stored
    }
    @discardableResult func importFile(_ url: URL) throws -> Stored {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Stream a bounded read so an accidentally selected large file cannot exhaust memory.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        return try importData(data)
    }
}
