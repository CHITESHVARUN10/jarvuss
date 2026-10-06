import AppKit
import Darwin

/// Watchdog for the app's own memory. A runaway (Metal buffers, a stuck
/// model load, an unbounded cache) should cost a relaunch, not drag the
/// whole Mac into swap — so past the ceiling the app logs why, terminates
/// itself gracefully, and hard-exits if graceful termination stalls.
///
/// The metric is `phys_footprint`, not RSS: it is what macOS counts against
/// the process (RSS double-counts shared/Metal pages and overstates it).
final class MemoryGuard {
    static let shared = MemoryGuard()

    /// UserDefaults key: whole GB, 0 = watchdog off.
    /// `JARVIS_MEMORY_LIMIT_GB` overrides for one-off runs (0 disables).
    static let limitDefaultsKey = "jarvis.memoryLimitGB"
    static let checkIntervalSeconds: TimeInterval = 5

    private let queue = DispatchQueue(label: "jarvis.memory-guard", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var terminating = false

    // MARK: - Pure helpers (unit-tested)

    /// Default ceiling: a quarter of physical RAM, clamped to 2–8 GB —
    /// 8 GB Macs → 2, 16 → 4, 24 → 6, 64 → 8.
    static func defaultLimitGB(physicalMemoryBytes: UInt64) -> Int {
        let physicalGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
        return min(8, max(2, physicalGB / 4))
    }

    static func limitBytes(forGB gb: Int) -> UInt64? {
        gb <= 0 ? nil : UInt64(gb) * 1024 * 1024 * 1024
    }

    /// The ceiling currently in force, or nil when the watchdog is off.
    static var configuredLimitBytes: UInt64? {
        if let env = ProcessInfo.processInfo.environment["JARVIS_MEMORY_LIMIT_GB"] {
            return limitBytes(envValue: env)
        }
        let stored = UserDefaults.standard.object(forKey: limitDefaultsKey) as? Int
        let gb = stored ?? defaultLimitGB(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        return limitBytes(forGB: gb)
    }

    /// Env override parsing: whole or FRACTIONAL GB ("0.25" = 256 MB) so the
    /// kill path stays demonstrable without pressuring a real machine;
    /// 0/off/nonsense disables.
    static func limitBytes(envValue: String) -> UInt64? {
        guard let gb = Double(envValue.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }
        return gb <= 0 ? nil : UInt64(gb * 1024 * 1024 * 1024)
    }

    static func shouldTerminate(footprintBytes: UInt64, limitBytes: UInt64) -> Bool {
        footprintBytes >= limitBytes
    }

    /// Current physical footprint in bytes (0 when the kernel call fails).
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.checkIntervalSeconds,
                       repeating: Self.checkIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
        NSLog("[Memory] guard started — limit %@", Self.limitDescription)
    }

    private func check() {
        guard let limit = Self.configuredLimitBytes else { return }
        let footprint = Self.footprintBytes()
        guard footprint > 0,
              Self.shouldTerminate(footprintBytes: footprint, limitBytes: limit) else { return }
        terminate(footprint: footprint, limit: limit)
    }

    private func terminate(footprint: UInt64, limit: UInt64) {
        guard !terminating else { return }
        terminating = true
        let message = "footprint \(Self.gbString(footprint)) GB exceeded the "
            + "\(Self.gbString(limit)) GB limit — terminating"
        NSLog("[Memory] %@", message)
        Self.appendLog(message)
        DispatchQueue.main.async { NSApp.terminate(nil) }
        // Backstop: graceful termination can stall exactly when memory is the
        // problem — the process must not survive the watchdog.
        queue.asyncAfter(deadline: .now() + 3) { exit(1) }
    }

    private static var limitDescription: String {
        guard let limit = configuredLimitBytes else { return "off" }
        return "\(gbString(limit)) GB"
    }

    private static func gbString(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1024 / 1024 / 1024)
    }

    /// Durable breadcrumb next to the other Jarvis logs — the reason for the
    /// exit must outlive the exit.
    private static func appendLog(_ message: String) {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jarvis/logs") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("memory.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
