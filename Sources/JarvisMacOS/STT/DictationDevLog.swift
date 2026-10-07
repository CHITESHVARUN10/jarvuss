import Foundation

/// Opt-in per-dictation diagnostics: the raw input, the rules and final text,
/// and where the time went (speech → STT → rules → polish → insert).
///
/// OFF by default; toggled in Assistant → Behaviour ("Dictation diagnostics")
/// or `JARVIS_DICTATION_DEV=1` for one-off runs. One JSONL line per dictation:
/// `~/Library/Application Support/Jarvis/logs/dictation_dev.jsonl`
///
/// This is the app-side half of the dictation quality test: the HTML harness
/// captures what you SAID (pasted output); this log captures the input the
/// engine heard, the rules text, and the timing breakdown — aligned by order
/// and timestamp.
enum DictationDevLog {
    static let defaultsKey = "jarvis.dictationDevLog"

    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["JARVIS_DICTATION_DEV"] {
            return env == "1" || env.lowercased() == "true"
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func append(_ fields: [String: Any]) {
        guard let data = line(from: fields) else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Jarvis/logs") else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("dictation_dev.jsonl")

            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Pure: one timestamped JSON line, or nil when the payload cannot be
    /// serialized — unit-tested so the format cannot drift silently.
    static func line(from fields: [String: Any]) -> Data? {
        var payload = fields
        payload["ts"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }
}
