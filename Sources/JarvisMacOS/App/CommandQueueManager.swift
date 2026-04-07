import Foundation

// MARK: - Priority

enum CommandPriority: Int, Comparable {
    case high   = 2   // time/date, stop/cancel, media, volume
    case normal = 1   // open app, browser
    case low    = 0   // logs, background

    static func < (lhs: CommandPriority, rhs: CommandPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Queued command

struct QueuedCommand: Identifiable {
    let id: UUID = UUID()
    let text: String
    let priority: CommandPriority
    let handler: () async -> Void
}

// MARK: - CommandQueueManager

/// Single-active-execution command queue with priority, deduplication, and time-window
/// duplicate suppression.
///
/// Deduplication rules:
///   1. If the same command text was EXECUTED within `deduplicationWindow` seconds → drop.
///   2. If the same command text is ALREADY PENDING in queue → drop.
///   3. HIGH priority commands skip the queue and cancel whatever is running.
@MainActor
final class CommandQueueManager: ObservableObject {

    static let maxQueueSize = 3

    /// How long (seconds) to suppress a repeated identical command after execution.
    private let deduplicationWindow: TimeInterval = 1.2

    @Published private(set) var isExecuting = false
    @Published private(set) var currentCommandText: String = ""

    private var activeTask: Task<Void, Never>?
    private var queue: [QueuedCommand] = []

    // ── Time-based deduplication state ───────────────────────────────
    private var lastExecutedText: String = ""
    private var lastExecutedAt: Date = .distantPast

    // ── High-priority cycle guard ─────────────────────────────────
    // Multiple high-priority interrupts within `highPriorityCooldown` are
    // collapsed to one. This prevents rapid-fire cancellations (e.g., voice
    // echo loop triggering volume commands repeatedly).
    private var lastHighPriorityAt: Date = .distantPast
    private let highPriorityCooldown: TimeInterval = 0.5

    // External log sink — set this to append to AppState.logs
    var onLog: ((String) -> Void)?

    // MARK: - Enqueue

    /// Submit a command for execution.
    /// - Returns: true if accepted, false if dropped.
    @discardableResult
    func enqueue(
        text: String,
        priority: CommandPriority = .normal,
        handler: @escaping () async -> Void
    ) -> Bool {

        // ── Time-window duplicate suppression ────────────────────────
        // If the exact same command was executed within `deduplicationWindow`,
        // silently drop it. This prevents double-firing from debounce edge-cases.
        let now = Date()
        if text == lastExecutedText &&
           now.timeIntervalSince(lastExecutedAt) < deduplicationWindow {
            log("[Queue] Skipped duplicate (within \(String(format: "%.1f", deduplicationWindow))s): '\(text)'")
            return false
        }

        let cmd = QueuedCommand(text: text, priority: priority, handler: handler)

        // ── HIGH priority: cancel current AND clear queue ───────────────
        if priority == .high {
            // Cycle guard: ignore additional high-priority interrupts within
            // `highPriorityCooldown` to prevent rapid-fire cancellation instability.
            let now = Date()
            if now.timeIntervalSince(lastHighPriorityAt) < highPriorityCooldown {
                log("[Queue] High-priority '\(text)' suppressed — cooldown active (\(String(format: "%.2f", now.timeIntervalSince(lastHighPriorityAt)))s < \(highPriorityCooldown)s)")
                return false
            }
            lastHighPriorityAt = now

            let dropped = queue.map { "'\($0.text)'" }.joined(separator: ", ")
            if !dropped.isEmpty {
                log("[Queue] cleared due to high-priority '\(text)': \(dropped)")
            }
            queue.removeAll()
            cancelCurrent(reason: "superseded by high-priority '\(text)'")
            queue.append(cmd)
            log("[Queue] HIGH priority queued: '\(text)'")
            drainIfIdle()
            return true
        }

        // ── Pending-queue duplicate suppression ───────────────────────
        if queue.contains(where: { $0.text == text }) {
            log("[Queue] Skipped duplicate (already pending): '\(text)'")
            return false
        }

        // ── Queue capacity management ─────────────────────────────────
        if queue.count >= Self.maxQueueSize {
            if let oldestLowIdx = queue.lastIndex(where: { $0.priority == .low }) {
                log("[Queue] Buffer full — dropped old low-priority: '\(queue[oldestLowIdx].text)'")
                queue.remove(at: oldestLowIdx)
            } else {
                log("[Queue] Buffer full (size \(Self.maxQueueSize)) — dropped: '\(text)'")
                return false
            }
        }

        queue.append(cmd)
        log("[Queue] Enqueued (\(priority)): '\(text)' [queue size: \(queue.count)]")
        drainIfIdle()
        return true
    }

    // MARK: - Cancel current

    func cancelCurrent(reason: String = "user request") {
        guard let task = activeTask else { return }
        task.cancel()
        activeTask = nil
        log("[Queue] Cancelled current task — \(reason)")
        isExecuting = false
        currentCommandText = ""
    }

    func cancelAll() {
        cancelCurrent(reason: "cancel all")
        let dropped = queue.map { "'\($0.text)'" }.joined(separator: ", ")
        if !dropped.isEmpty { log("[Queue] Cleared queue: \(dropped)") }
        queue.removeAll()
    }

    // MARK: - Queue drain

    private func drainIfIdle() {
        guard !isExecuting, !queue.isEmpty else { return }
        executeNext()
    }

    private func executeNext() {
        guard !queue.isEmpty else {
            isExecuting = false
            currentCommandText = ""
            return
        }

        let cmd = queue.removeFirst()
        isExecuting = true
        currentCommandText = cmd.text

        // Record execution for time-based deduplication
        lastExecutedText = cmd.text
        lastExecutedAt = Date()

        log("[Execution] started: '\(cmd.text)'")

        activeTask = Task { [weak self] in
            guard let self else { return }

            await cmd.handler()

            await MainActor.run {
                if !Task.isCancelled {
                    self.log("[Execution] finished: '\(cmd.text)'")
                }
                self.activeTask = nil
                self.isExecuting = false
                self.currentCommandText = ""
                self.drainIfIdle()
            }
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        onLog?(message)
    }
}

// MARK: - Priority classification

extension CommandPriority {
    /// Classify a raw command string into a priority level.
    static func classify(_ text: String) -> CommandPriority {
        let lower = text.lowercased()

        // Time / date — always high
        let timeTerms = [
            "what time", "what is the time", "tell me the time", "current time",
            "what day", "what date", "what month", "what year",
            "stop", "cancel", "abort"
        ]
        if timeTerms.contains(where: { lower.contains($0) }) { return .high }

        // Media — high (execute immediately, no waiting for other commands)
        let mediaTerms = [
            "play", "pause", "next", "previous", "prev", "skip", "resume",
            "next song", "next track", "previous song", "liked songs",
        ]
        if mediaTerms.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return .high
        }

        // Volume — always high (user expects instant feedback)
        let volumeTerms = [
            "mute", "unmute",
            "increase volume", "decrease volume",
            "increase sound", "decrease sound",
            "increase audio", "decrease audio",
            "volume up", "volume down",
            "sound up", "sound down",
            "turn up", "turn down",
            "louder", "quieter", "lower volume", "lower sound",
            "set volume", "sound off", "sound on",
            "raise volume", "raise the volume",
            "reduce volume", "reduce the volume",
        ]
        if volumeTerms.contains(where: { lower.contains($0) }) { return .high }

        // Close app — high so it's never delayed behind a queue
        if lower.hasPrefix("close ") { return .high }

        return .normal
    }
}
