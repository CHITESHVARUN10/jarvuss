import Foundation
import Security

/// Shares non-secret settings and the Keychain service with the Python
/// backend. Saved connection edits override launch-time environment defaults.
enum RuntimeConfiguration {
    static let keychainService = "local.jarvis.credentials"

    static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["JARVIS_DATA_DIR"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
    }

    static func mergedValues(defaults: [String: String] = DotEnvLoader.mergedEnv(),
                             settingsURL: URL? = nil,
                             secretReader: (String) -> String? = keychainValue) -> [String: String] {
        var values = defaults
        let file = settingsURL ?? dataDirectory.appendingPathComponent("connection_settings.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, value) in saved where key != "PGPASSWORD"
                && !["SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"].contains(key) {
                values[key] = value
            }
        }
        if let password = secretReader("PGPASSWORD") { values["PGPASSWORD"] = password }
        return values
    }

    static func keychainValue(_ account: String) -> String? {
        do { return try readKeychainValue(account) }
        catch { NSLog("[Config] Keychain read unavailable (%d)", (error as NSError).code); return nil }
    }

    static func readKeychainValue(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }
}
