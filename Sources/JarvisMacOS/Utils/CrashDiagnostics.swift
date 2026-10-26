import AppKit
import Darwin
import MachO
import CDDCShim

struct DiagnosticBuild: Codable {
    let revision: String
    let builtAt: String
    let executableUUID: String
    let executablePath: String
    let os: String

    static let current: DiagnosticBuild = {
        DiagnosticBuild(
            revision: Bundle.main.object(forInfoDictionaryKey: "JarvisBuildRevision") as? String ?? "development",
            builtAt: Bundle.main.object(forInfoDictionaryKey: "JarvisBuildTimestamp") as? String ?? "unpackaged",
            executableUUID: loadedExecutableUUID(),
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString)
    }()

    private static func loadedExecutableUUID() -> String {
        guard let header = _dyld_get_image_header(0) else { return "unknown" }
        let bytes = UnsafeRawPointer(header)
        var offset = header.pointee.magic == MH_MAGIC_64
            ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        let end = offset + Int(header.pointee.sizeofcmds)
        for _ in 0..<header.pointee.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { break }
            let command = bytes.advanced(by: offset).load(as: load_command.self)
            let size = Int(command.cmdsize)
            guard size >= MemoryLayout<load_command>.size, offset + size <= end else { break }
            if command.cmd == LC_UUID, size >= MemoryLayout<uuid_command>.size {
                return UUID(uuid: bytes.advanced(by: offset).load(as: uuid_command.self).uuid).uuidString
            }
            offset += size
        }
        return "unknown"
    }
}

struct DiagnosticSession: Codable {
    let id: String
    let pid: Int32
    let startedAt: Date
    let build: DiagnosticBuild
    var status: String = "running"
    var endedAt: Date?
    var exitReason: String?
    var crashReports: [String] = []
}

struct AppleCrashSummary: Codable {
    let filename: String
    let pid: Int32
    let executableUUID: String
    let exception: String
    let signal: String
    let termination: String
    let frames: [String]

    static func parse(_ data: Data, filename: String) -> AppleCrashSummary? {
        // Modern .ips files contain a metadata JSON line followed by the body.
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            ?? data.firstIndex(of: 10).flatMap { index in
                try? JSONSerialization.jsonObject(with: data.suffix(from: data.index(after: index))) as? [String: Any]
            }
        guard let body,
              body["procName"] as? String == "Jarvis"
                || (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String == "local.jarvis.macos"
        else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let image = images.first(where: { $0["name"] as? String == "Jarvis" }) ?? images.first ?? [:]
        let threads = body["threads"] as? [[String: Any]] ?? []
        let index = body["faultingThread"] as? Int ?? -1
        let frames = threads.indices.contains(index)
            ? (threads[index]["frames"] as? [[String: Any]] ?? []).prefix(12).compactMap { $0["symbol"] as? String }
            : []
        return AppleCrashSummary(filename: filename, pid: (body["pid"] as? NSNumber)?.int32Value ?? -1,
            executableUUID: image["uuid"] as? String ?? "unknown",
            exception: exception["type"] as? String ?? "unknown",
            signal: exception["signal"] as? String ?? "unknown",
            termination: termination["indicator"] as? String ?? termination["namespace"] as? String ?? "unknown",
            frames: Array(frames))
    }
}

/// Durable breadcrumbs/output plus Apple's original crash report. No signal
/// handlers: preserve OS unwinding, exception details and debugger behavior.
final class CrashDiagnostics: @unchecked Sendable {
    static let shared = CrashDiagnostics()
    let directory: URL
    private let reportsDirectory: URL
    private let lock = NSLock()
    private let collector = DispatchQueue(label: "jarvis.crash-collection", qos: .utility)
    private var session: DiagnosticSession?
    private var sessionDirectory: URL?
    private var events: FileHandle?
    private var maintenance: DispatchSourceTimer?
    private var capturesOutput = false
    private let appleDirectory: URL
    private let processIsAlive: (Int32) -> Bool

    init(directory: URL = RuntimeConfiguration.dataDirectory.appendingPathComponent("logs/diagnostics"),
         appleDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
         processIsAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.directory = directory
        self.reportsDirectory = directory.appendingPathComponent("crashes")
        self.appleDirectory = appleDirectory
        self.processIsAlive = processIsAlive
    }

    func start(captureOutput: Bool = true, installExceptionHandler: Bool = true, scheduleMaintenance: Bool = true) {
        lock.lock()
        guard session == nil else { lock.unlock(); return }
        do {
            let record = DiagnosticSession(id: UUID().uuidString, pid: getpid(), startedAt: Date(), build: .current)
            let folder = directory.appendingPathComponent("sessions/\(record.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let eventURL = folder.appendingPathComponent("events.jsonl")
            FileManager.default.createFile(atPath: eventURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            events = try FileHandle(forWritingTo: eventURL)
            session = record
            sessionDirectory = folder
            try Self.save(record, to: folder.appendingPathComponent("session.json"))
            if captureOutput { capturesOutput = redirectOutput(to: folder.appendingPathComponent("runtime.log")) }
            if installExceptionHandler { JarvisInstallExceptionLogging() }
        } catch { NSLog("[Jarvis][Diagnostics] Could not initialize: %@", error.localizedDescription) }
        lock.unlock()
        record("session_started", fields: ["uuid": DiagnosticBuild.current.executableUUID,
            "revision": DiagnosticBuild.current.revision, "path": DiagnosticBuild.current.executablePath])
        guard scheduleMaintenance else { return }
        collector.async { [weak self] in self?.collectReportsAndRecoverSessions(); self?.pruneSessions() }
        // Apple may finish writing an .ips shortly AFTER the next launch.
        let timer = DispatchSource.makeTimerSource(queue: collector)
        timer.schedule(deadline: .now() + 10, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.collectReportsAndRecoverSessions()
            self?.rotateOutputIfNeeded()
        }
        maintenance = timer
        timer.resume()
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, let events else { return }
        let payload: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()),
            "event": event, "session": session.id, "fields": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        // Synchronous bounded writes survive an immediate subsequent crash.
        do { try events.write(contentsOf: data + [10]) }
        catch { NSLog("[Jarvis][Diagnostics] Event write failed: %@", error.localizedDescription) }
    }

    func markExit(reason: String? = nil) {
        record(reason == nil ? "clean_exit" : "planned_exit", fields: reason.map { ["reason": $0] } ?? [:])
        lock.lock()
        defer { lock.unlock() }
        guard var current = session, let folder = sessionDirectory else { return }
        if current.status == "planned_exit", reason == nil { return }
        current.status = reason == nil ? "clean_exit" : "planned_exit"
        current.exitReason = reason
        current.endedAt = Date()
        session = current
        try? Self.save(current, to: folder.appendingPathComponent("session.json"))
        try? events?.synchronize()
    }

    var summary: String {
        let crashes = (try? Data(contentsOf: reportsDirectory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([AppleCrashSummary].self, from: $0) } ?? []
        let build = DiagnosticBuild.current
        var lines = ["Jarvis revision: \(build.revision)", "Built: \(build.builtAt)",
            "Executable UUID: \(build.executableUUID)", "Executable: \(build.executablePath)",
            "OS: \(build.os)", "Logs: \(directory.path)"]
        if let crash = crashes.first {
            lines += ["Latest report: \(crash.filename)", "Crashed UUID: \(crash.executableUUID)",
                "Exception: \(crash.exception) / \(crash.signal)", "Termination: \(crash.termination)",
                "Report matches current binary: \(crash.executableUUID.caseInsensitiveCompare(build.executableUUID) == .orderedSame)"]
            lines += crash.frames
        } else { lines.append("No macOS crash report collected yet.") }
        return lines.joined(separator: "\n")
    }

    // Internal for regression tests with isolated temporary directories.
    func collectReportsAndRecoverSessions() {
        let fm = FileManager.default
        let reportURLs = ((try? fm.contentsOfDirectory(at: appleDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Jarvis-") && $0.pathExtension == "ips" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(20)
        var summaries: [AppleCrashSummary] = []
        for url in reportURLs {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 20 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let summary = AppleCrashSummary.parse(data, filename: url.lastPathComponent) else { continue }
            let destination = reportsDirectory.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) { try? fm.copyItem(at: url, to: destination) }
            summaries.append(summary)
        }
        // Retain previously copied reports after macOS rotates the originals.
        if let data = try? Data(contentsOf: reportsDirectory.appendingPathComponent("index.json")),
           let existing = try? JSONDecoder().decode([AppleCrashSummary].self, from: data) {
            let freshNames = Set(summaries.map(\.filename))
            summaries += existing.filter { !freshNames.contains($0.filename) }
        }
        summaries = Array(summaries.sorted { $0.filename > $1.filename }.prefix(20))
        try? Self.save(summaries, to: reportsDirectory.appendingPathComponent("index.json"))
        let kept = Set(summaries.map(\.filename))
        for url in (try? fm.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "ips" && !kept.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        for folder in sessionFolders() {
            let manifest = folder.appendingPathComponent("session.json")
            guard var previous = try? Self.loadSession(manifest), previous.pid != getpid(),
                  !processIsAlive(previous.pid) else { continue }
            let matches = summaries.filter { $0.pid == previous.pid
                && $0.executableUUID.caseInsensitiveCompare(previous.build.executableUUID) == .orderedSame }
            if !matches.isEmpty { previous.status = "crashed" }
            else if previous.status == "running" { previous.status = "unclean_exit" }
            previous.crashReports = matches.map(\.filename)
            try? Self.save(previous, to: manifest)
        }
    }

    private func redirectOutput(to url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        fflush(stdout); fflush(stderr)
        guard dup2(fd, STDOUT_FILENO) >= 0, dup2(fd, STDERR_FILENO) >= 0 else { return false }
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        return true
    }

    private func rotateOutputIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard capturesOutput, let folder = sessionDirectory else { return }
        let url = folder.appendingPathComponent("runtime.log")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 8 * 1024 * 1024 else { return }
        let previous = folder.appendingPathComponent("runtime-previous.log")
        try? FileManager.default.removeItem(at: previous)
        do {
            try FileManager.default.moveItem(at: url, to: previous)
            capturesOutput = redirectOutput(to: url)
        } catch { NSLog("[Jarvis][Diagnostics] Log rotation failed: %@", error.localizedDescription) }
    }

    private func sessionFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sessions"),
            includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }
    private func pruneSessions() {
        for folder in sessionFolders().dropFirst(20) {
            guard let old = try? Self.loadSession(folder.appendingPathComponent("session.json")),
                  !processIsAlive(old.pid) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    private static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func loadSession(_ url: URL) throws -> DiagnosticSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSession.self, from: Data(contentsOf: url))
    }
    deinit { maintenance?.cancel(); try? events?.close() }
}
