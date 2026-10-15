import Foundation

struct DayBucket: Codable, Sendable {
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

/// Immutable upload identity makes database retries safe after a crash or a
/// failed local acknowledgement. A batch is removed only after acknowledgement.
struct StatsBatch: Codable, Identifiable, Sendable {
    let id: UUID
    let bucket: DayBucket

    init(id: UUID = UUID(), bucket: DayBucket) {
        self.id = id
        self.bucket = bucket
    }
}

extension DayBucket {
    mutating func add(_ delta: DayBucket) {
        talkSecs += delta.talkSecs
        sessions += delta.sessions
        charsDictated += delta.charsDictated
        tokensPromptEst += delta.tokensPromptEst
        tokensCompletionEst += delta.tokensCompletionEst
        copies += delta.copies
        commandsRun += delta.commandsRun
        commandsFailed += delta.commandsFailed
        timeSavedSecs += delta.timeSavedSecs
    }
}

/// Accessed only by StatsRecorder's serial queue.
final class StatsBufferStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? RuntimeConfiguration.dataDirectory.appendingPathComponent("usage_buffer.json")
    }

    func load() throws -> [StatsBatch] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if let batches = try? JSONDecoder().decode([StatsBatch].self, from: data) {
            return batches
        }
        // Migrate the old daily buffer once, retaining stable IDs on retry.
        let legacy = try JSONDecoder().decode([DayBucket].self, from: data)
        let batches = legacy.map { StatsBatch(bucket: $0) }
        try save(batches)
        return batches
    }

    func save(_ batches: [StatsBatch]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(batches).write(to: fileURL, options: .atomic)
    }
}

// All mutable state is confined to queue, including the upload callback.
final class StatsRecorder: @unchecked Sendable {
    static let shared = StatsRecorder()

    private let queue = DispatchQueue(label: "jarvis.stats.persistence", qos: .utility)
    private let buffer: StatsBufferStore
    private let now: @Sendable () -> Date
    private var today: DayBucket
    private var batches: [StatsBatch] = []
    private var pending: [String: DayBucket] = [:]
    private var pendingEvents = 0
    private var persistenceWork: DispatchWorkItem?
    private var retryTimer: DispatchSourceTimer?
    private var uploadInProgress = false
    private var lastUploadAt = Date.distantPast
    private var storageReadable = true
    private var upload: (@Sendable (StatsBatch) async -> Bool)?

    var onFlush: (@Sendable (StatsBatch) async -> Bool)? {
        get { queue.sync { upload } }
        set { queue.sync { upload = newValue } }
    }

    init(buffer: StatsBufferStore = StatsBufferStore(),
         now: @escaping @Sendable () -> Date = { Date() },
         retryInterval: TimeInterval = 60) {
        self.buffer = buffer
        self.now = now
        today = DayBucket(day: DayBucket.dayString(now()))
        do { batches = try buffer.load() }
        catch {
            // Do not overwrite a damaged/unreadable outbox with an empty one.
            storageReadable = false
            NSLog("[Stats] Could not read outbox: %@", error.localizedDescription)
        }
        if retryInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
            timer.setEventHandler { [weak self] in
                self?.persistPending()
                self?.uploadIfNeeded(force: true)
            }
            timer.resume()
            retryTimer = timer
        }
    }

    deinit {
        persistenceWork?.cancel()
        retryTimer?.cancel()
    }

    static func tokens(forChars chars: Int) -> Int { max(0, (chars + 3) / 4) }

    static func timeSavedForDictation(chars: Int, speechSecs: Double) -> Double {
        max(0, Double(chars) / 5.0 / 40.0 * 60.0 - speechSecs)
    }

    static func timeSavedForCommand() -> Double { 15.0 }

    func recordDictation(speechSecs: Double, chars: Int) {
        var delta = DayBucket(day: DayBucket.dayString(now()))
        delta.talkSecs = speechSecs
        delta.sessions = 1
        delta.charsDictated = chars
        delta.timeSavedSecs = Self.timeSavedForDictation(chars: chars, speechSecs: speechSecs)
        record(delta)
    }

    func recordCopy(chars: Int) {
        var delta = DayBucket(day: DayBucket.dayString(now()))
        delta.copies = 1
        record(delta)
    }

    func recordLLM(promptChars: Int, responseChars: Int) {
        var delta = DayBucket(day: DayBucket.dayString(now()))
        delta.tokensPromptEst = Self.tokens(forChars: promptChars)
        delta.tokensCompletionEst = Self.tokens(forChars: responseChars)
        record(delta)
    }

    func recordCommand(success: Bool) {
        var delta = DayBucket(day: DayBucket.dayString(now()))
        delta.commandsRun = success ? 1 : 0
        delta.commandsFailed = success ? 0 : 1
        delta.timeSavedSecs = success ? Self.timeSavedForCommand() : 0
        record(delta)
    }

    private func record(_ delta: DayBucket) {
        queue.async { [self] in
            // Day rollover only rotates the in-memory snapshot. No recursive
            // locking or callbacks while mutating persistence state.
            if today.day != delta.day { today = DayBucket(day: delta.day) }
            today.add(delta)
            var accumulated = pending[delta.day] ?? DayBucket(day: delta.day)
            accumulated.add(delta)
            pending[delta.day] = accumulated
            pendingEvents += 1
            if pendingEvents >= 64 {
                persistPending()
                uploadIfNeeded(force: false)
            } else if persistenceWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.persistenceWork = nil
                    self?.persistPending()
                    self?.uploadIfNeeded(force: false)
                }
                persistenceWork = work
                queue.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
    }

    private func persistPending() {
        guard storageReadable, !pending.isEmpty else { return }
        let additions = pending.values.sorted { $0.day < $1.day }.map { StatsBatch(bucket: $0) }
        do {
            try buffer.save(batches + additions)
            batches += additions
            pending.removeAll()
            pendingEvents = 0
        } catch {
            NSLog("[Stats] Retaining pending usage: %@", error.localizedDescription)
        }
    }

    private func uploadIfNeeded(force: Bool) {
        guard !uploadInProgress, let upload, !batches.isEmpty,
              force || now().timeIntervalSince(lastUploadAt) >= 60 else { return }
        uploadInProgress = true
        lastUploadAt = now()
        let submitted = batches
        Task { [weak self] in
            for batch in submitted {
                guard await upload(batch) else { break }
                await self?.acknowledge(batch.id)
            }
            self?.queue.async { [weak self] in self?.uploadInProgress = false }
        }
    }

    private func acknowledge(_ id: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let remaining = batches.filter { $0.id != id }
                do {
                    try buffer.save(remaining)
                    batches = remaining
                } catch {
                    // The same batch ID can safely be submitted again.
                    NSLog("[Stats] Could not persist acknowledgement: %@", error.localizedDescription)
                }
                continuation.resume()
            }
        }
    }

    func snapshot() -> DayBucket { queue.sync { today } }

    /// Persist immediately on shutdown; upload remains asynchronous. A failed
    /// or interrupted upload leaves its immutable batches available on relaunch.
    func flush() {
        queue.sync {
            persistenceWork?.cancel()
            persistenceWork = nil
            persistPending()
            uploadIfNeeded(force: true)
        }
    }

    func bufferedDays() -> [DayBucket] {
        queue.sync {
            var days = pending
            for batch in batches {
                var day = days[batch.bucket.day] ?? DayBucket(day: batch.bucket.day)
                day.add(batch.bucket)
                days[day.day] = day
            }
            return days.values.sorted { $0.day < $1.day }
        }
    }
}
