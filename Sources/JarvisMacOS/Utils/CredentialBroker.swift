import Foundation
import Darwin

/// Only the signed native app accesses Keychain. The helper receives a
/// per-launch authenticated Unix socket; credentials never enter argv/files.
final class CredentialBroker: @unchecked Sendable {
    static let shared = CredentialBroker()
    private let lock = NSLock()
    private let cacheLock = NSLock()
    private var listener: Int32 = -1
    private var folder: URL?
    private var token = ""
    private var cached: [String: String] = [:]
    private var absent = Set<String>()
    private var blocked = Set<String>()
    private var revision: String = ""
    private let readSecret: (String) throws -> String?
    private let writeSecret: (String, String) throws -> Void
    private let settingsRevision: () -> String
    private let queue = DispatchQueue(label: "jarvis.credentials", qos: .userInitiated)

    init(readSecret: @escaping (String) throws -> String? = { try RuntimeConfiguration.readKeychainValue($0) },
         writeSecret: @escaping (String, String) throws -> Void = { try ConnectionSettingsStore.keychainSet(account: $0, value: $1) },
         settingsRevision: @escaping () -> String = {
             let attrs = try? FileManager.default.attributesOfItem(atPath: ConnectionSettingsStore.settingsURL.path)
             return "\(attrs?[.systemFileNumber] ?? 0)-\(attrs?[.modificationDate] ?? Date.distantPast)"
         }) {
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.settingsRevision = settingsRevision
    }

    func environment() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if listener < 0 {
            let dir = URL(fileURLWithPath: "/private/tmp/jvc-\(getuid())-\(UUID().uuidString.prefix(12))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let path = dir.appendingPathComponent("socket").path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { try? FileManager.default.removeItem(at: dir); throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
                close(fd); try? FileManager.default.removeItem(at: dir); throw POSIXError(.EIO)
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            listener = fd
            folder = dir
            token = UUID().uuidString + UUID().uuidString
            CrashDiagnostics.shared.record("credential_broker_started")
            let sessionToken = token
            queue.async { [weak self] in self?.serve(fd, sessionToken: sessionToken) }
        }
        return ["JARVIS_CREDENTIAL_SOCKET": folder!.appendingPathComponent("socket").path,
                "JARVIS_CREDENTIAL_TOKEN": token, "JARVIS_CREDENTIAL_OWNER_PID": String(getpid())]
    }

    private func serve(_ fd: Int32, sessionToken: String) {
        while true {
            lock.lock()
            let active = listener == fd && token == sessionToken
            lock.unlock()
            guard active else { return }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            defer { close(client) }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { continue }
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var suppress: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while data.count <= 65536 {
                let count = read(client, &buffer, min(buffer.count, 65537 - data.count))
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.contains(10) { break }
            }
            guard data.count <= 65536 else { continue }
            let response = handle(data)
            response.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let count = write(client, base.advanced(by: sent), raw.count - sent)
                    if count <= 0 { break }; sent += count
                }
            }
        }
    }

    /// Serialized by the server; internal for tests with fake credential storage.
    func handle(_ data: Data) -> Data {
        lock.lock()
        let expectedToken = token
        lock.unlock()
        cacheLock.lock(); defer { cacheLock.unlock() }
        var result: [String: Any] = ["ok": false, "error": "Credential request unavailable"]
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !expectedToken.isEmpty, request["token"] as? String == expectedToken {
            do {
                switch request["operation"] as? String {
                case "get":
                    guard let keys = request["keys"] as? [String], !keys.isEmpty,
                          Set(keys).isSubset(of: ConnectionSettingsStore.secretKeys) else { break }
                    let current = settingsRevision()
                    if revision != current { cached.removeAll(); absent.removeAll(); blocked.removeAll(); revision = current }
                    guard blocked.isDisjoint(with: keys) else { throw NSError(domain: "JarvisCredentials", code: 1) }
                    var values: [String: Any] = [:]
                    for key in Set(keys).sorted() {
                        if cached[key] == nil && !absent.contains(key) {
                            do {
                                if let value = try readSecret(key) { cached[key] = value }
                                else { absent.insert(key) }
                            } catch { blocked.insert(key); throw error }
                        }
                        values[key] = cached[key].map { $0 as Any } ?? NSNull()
                    }
                    result = ["ok": true, "values": values]
                case "set":
                    guard let updates = request["values"] as? [String: String],
                          Set(updates.keys).isSubset(of: ConnectionSettingsStore.secretKeys) else { break }
                    for (key, value) in updates {
                        try writeSecret(key, value)
                        cached[key] = value; absent.remove(key); blocked.remove(key)
                    }
                    result = ["ok": true]
                default: break
                }
            } catch {
                CrashDiagnostics.shared.record("credential_access_unavailable", fields: ["code": String((error as NSError).code)])
                // Never reflect secret values or query contents to logs/errors.
                result = ["ok": false, "error": "Jarvis could not access saved credentials. Unlock your login Keychain, then save the connection in Jarvis or restart Jarvis."]
            }
        }
        return ((try? JSONSerialization.data(withJSONObject: result)) ?? Data("{\"ok\":false}".utf8)) + [10]
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil; token = ""
    }
    deinit { if listener >= 0 { close(listener) }; if let folder { try? FileManager.default.removeItem(at: folder) } }
}
