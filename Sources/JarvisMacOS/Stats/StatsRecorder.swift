import Foundation

struct DayBucket: Codable {
    var day: String
    var talkSecs: Double = 0
    var sessions: Int = 0
    var charsDictated: Int = 0
    var tokensPromptEst: Int = 0
    var tokensCompletionEst: Int = 0
    var copies: Int = 0
    var commandsRun: Int = 0
    var commandsFailed: Int = 0
    var timeSavedSecs: Double = 0

    static func dayString(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .iso8601)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

final class StatsBufferStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
        self.fileURL = baseDir.appendingPathComponent("usage_buffer.json", isDirectory: false)
    }

    func load() -> [DayBucket] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([DayBucket].self, from: data) else { return [] }
        return decoded
    }

    func save(_ buckets: [DayBucket]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(buckets)
        try data.write(to: fileURL, options: .atomic)
    }

    func merge(_ bucket: DayBucket) {
        var buckets = load()
        if let idx = buckets.firstIndex(where: { $0.day == bucket.day }) {
            var existing = buckets[idx]
            existing.talkSecs += bucket.talkSecs
            existing.sessions += bucket.sessions
            existing.charsDictated += bucket.charsDictated
            existing.tokensPromptEst += bucket.tokensPromptEst
            existing.tokensCompletionEst += bucket.tokensCompletionEst
            existing.copies += bucket.copies
            existing.commandsRun += bucket.commandsRun
            existing.commandsFailed += bucket.commandsFailed
            existing.timeSavedSecs += bucket.timeSavedSecs
            buckets[idx] = existing
        } else {
            buckets.append(bucket)
        }
        try? save(buckets)
    }

    func clear(days: [String]) {
        let remaining = load().filter { !days.contains($0.day) }
        try? save(remaining)
    }
}

final class StatsRecorder {
    static let shared = StatsRecorder()

    private let lock = NSLock()
    private var today = DayBucket(day: DayBucket.dayString())
    private let buffer = StatsBufferStore()
    private var lastFlushAt = Date.distantPast
    var onFlush: ((DayBucket) -> Void)?

    private init() {}

    static func tokens(forChars chars: Int) -> Int {
        max(0, (chars + 3) / 4)
    }

    static func timeSavedForDictation(chars: Int, speechSecs: Double) -> Double {
        let words = Double(chars) / 5.0
        let typingSecs = words / 40.0 * 60.0
        return max(0, typingSecs - speechSecs)
    }

    static func timeSavedForCommand() -> Double {
        15.0
    }

    private func rollDayIfNeeded() {
        let day = DayBucket.dayString()
        if today.day != day {
            flush()
            today = DayBucket(day: day)
        }
    }

    func recordDictation(speechSecs: Double, chars: Int) {
        lock.lock()
        defer { lock.unlock() }
        rollDayIfNeeded()
        var delta = DayBucket(day: today.day)
        delta.talkSecs = speechSecs
        delta.sessions = 1
        delta.charsDictated = chars
        delta.timeSavedSecs = Self.timeSavedForDictation(chars: chars, speechSecs: speechSecs)
        apply(delta)
    }

    func recordCopy(chars: Int) {
        lock.lock()
        defer { lock.unlock() }
        rollDayIfNeeded()
        var delta = DayBucket(day: today.day)
        delta.copies = 1
        delta.charsDictated = chars
        apply(delta)
    }

    func recordLLM(promptChars: Int, responseChars: Int) {
        lock.lock()
        defer { lock.unlock() }
        rollDayIfNeeded()
        var delta = DayBucket(day: today.day)
        delta.tokensPromptEst = Self.tokens(forChars: promptChars)
        delta.tokensCompletionEst = Self.tokens(forChars: responseChars)
        apply(delta)
    }

    func recordCommand(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        rollDayIfNeeded()
        var delta = DayBucket(day: today.day)
        if success {
            delta.commandsRun = 1
            delta.timeSavedSecs = Self.timeSavedForCommand()
        } else {
            delta.commandsFailed = 1
        }
        apply(delta)
    }

    private func apply(_ delta: DayBucket) {
        today.talkSecs += delta.talkSecs
        today.sessions += delta.sessions
        today.charsDictated += delta.charsDictated
        today.tokensPromptEst += delta.tokensPromptEst
        today.tokensCompletionEst += delta.tokensCompletionEst
        today.copies += delta.copies
        today.commandsRun += delta.commandsRun
        today.commandsFailed += delta.commandsFailed
        today.timeSavedSecs += delta.timeSavedSecs
        buffer.merge(delta)
        if Date().timeIntervalSince(lastFlushAt) > 60 {
            lastFlushAt = Date()
            let snapshot = today
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.onFlush?(snapshot)
            }
        }
    }

    func snapshot() -> DayBucket {
        lock.lock()
        defer { lock.unlock() }
        return today
    }

    func flush() {
        lock.lock()
        let snapshot = today
        lock.unlock()
        lastFlushAt = Date()
        onFlush?(snapshot)
    }

    func bufferedDays() -> [DayBucket] {
        buffer.load()
    }

    func markBackfilled(days: [String]) {
        buffer.clear(days: days)
    }
}
