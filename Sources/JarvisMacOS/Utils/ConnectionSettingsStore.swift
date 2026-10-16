import Foundation
import Security
import Darwin

/// Writes the shared connection settings the backend's runtime_config.py and
/// Swift's RuntimeConfiguration both read: non-secrets in
/// `connection_settings.json` (atomic, 0700 dir), secrets in the Keychain
/// (service "local.jarvis.credentials"). Mirrors the backend's key model so
/// either side can write and both sides read the same values.
enum ConnectionSettingsStore {
    static var settingsURL: URL {
        RuntimeConfiguration.dataDirectory.appendingPathComponent("connection_settings.json")
    }

    /// Keys routed to the Keychain instead of the JSON file.
    static let secretKeys: Set<String> = [
        "PGPASSWORD", "SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN",
    ]

    /// Persists a merged edit: non-secrets into the JSON store, secrets into
    /// the Keychain. Empty-string secret values mean "keep the stored one".
    static func save(_ values: [String: String]) throws {
        let dir = RuntimeConfiguration.dataDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Both processes use the same advisory lock for read/merge/write.
        let descriptor = open(dir.appendingPathComponent("connection_settings.lock").path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }

        var existing: [String: String] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            // Never silently replace a damaged settings file and lose other connections.
            existing = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: settingsURL))
        }
        existing = existing.filter { !secretKeys.contains($0.key) }
        for (key, value) in values {
            if secretKeys.contains(key) {
                if !value.isEmpty { try keychainSet(account: key, value: value) }
            } else {
                existing[key] = value
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(existing)
        try payload.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    // MARK: - Keychain upsert

    static func keychainSet(account: String, value: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RuntimeConfiguration.keychainService,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }
}
