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
    let deliveryID: UUID
    let handler: () async -> Void
}

// MARK: - CommandQueueManager

/// Single-active-execution queue. Only repeated delivery IDs are suppressed;
/// separate requests with identical text retain their intended side effects.
/// A different high-priority command can interrupt the current plan.
@MainActor
final class CommandQueueManager: ObservableObject {

    static let maxQueueSize = 3

    @Published private(set) var isExecuting = false
    @Published private(set) var currentCommandText: String = ""

    private var activeTask: Task<Void, Never>?
    private var currentDeliveryID: UUID?
    /// Monotonic token identifying the current execution slot. A superseded
    /// task compares its own token before mutating queue state.
    private var generation: Int = 0
    private var queue: [QueuedCommand] = []

    private var acceptedDeliveries: Set<UUID> = []
    private var deliveryOrder: [UUID] = []

    // External log sink — set this to append to AppState.logs
    var onLog: ((String) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Enqueue

    /// Submit a command for execution.
    /// - Returns: true if accepted, false if dropped.
    @discardableResult
    func enqueue(
        text: String,
        priority: CommandPriority = .normal,
        deliveryID: UUID = UUID(),
        handler: @escaping () async -> Void
    ) -> Bool {

        guard !acceptedDeliveries.contains(deliveryID) else {
            log("[Queue] Skipped repeated delivery: \(deliveryID)")
            return false
        }

        let cmd = QueuedCommand(text: text, priority: priority, deliveryID: deliveryID, handler: handler)

        // ── HIGH priority: cancel current AND clear queue ───────────────
        if priority == .high && text != currentCommandText {
            let dropped = queue.map { "'\($0.text)'" }.joined(separator: ", ")
            if !dropped.isEmpty {
                log("[Queue] cleared due to high-priority '\(text)': \(dropped)")
            }
            queue.removeAll()
            cancelCurrent(reason: "superseded by high-priority '\(text)'")
            queue.append(cmd)
            recordDelivery(deliveryID)
            log("[Queue] HIGH priority queued: '\(text)'")
            drainIfIdle()
            return true
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
        recordDelivery(deliveryID)
        log("[Queue] Enqueued (\(priority)): '\(text)' [queue size: \(queue.count)]")
        drainIfIdle()
        return true
    }

    private func recordDelivery(_ deliveryID: UUID) {
        acceptedDeliveries.insert(deliveryID)
        deliveryOrder.append(deliveryID)
        if deliveryOrder.count > 256 { acceptedDeliveries.remove(deliveryOrder.removeFirst()) }

    }

    // MARK: - Cancel current

    func cancelCurrent(reason: String = "user request") {
        guard let task = activeTask else { return }
        task.cancel()
        activeTask = nil
        currentDeliveryID = nil
        // Bump the generation so the superseded task's completion block can
        // no longer clear `isExecuting`/`activeTask` while its replacement
        // is still running (that used to let two commands overlap).
        generation += 1
        log("[Queue] Cancelled current task — \(reason)")
        isExecuting = false
        currentCommandText = ""
        onCancel?()
    }

    func cancelAll() {
        cancelCurrent(reason: "cancel all")
        let dropped = queue.map { "'\($0.text)'" }.joined(separator: ", ")
        if !dropped.isEmpty { log("[Queue] Cleared queue: \(dropped)") }
        queue.removeAll()
    }

    /// Test clients may cancel their own delivery without interrupting a
    /// different user command that has since taken its place.
    func cancelDelivery(_ id: UUID) {
        queue.removeAll { $0.deliveryID == id }
        guard currentDeliveryID == id else { return }
        cancelCurrent(reason: "test run cancelled")
        drainIfIdle()
    }

    // MARK: - Queue drain

    private func drainIfIdle() {
        guard !isExecuting, !queue.isEmpty else { return }
        executeNext()
    }

    /// How long a handler may run before the watchdog releases its slot.
    /// Without this, one wedged handler (a child process blocked on a system
    /// dialog) left `isExecuting == true` forever and every later command
    /// queued behind a ghost. Internal so tests can shorten it.
    static var executionWatchdogSeconds: TimeInterval = 90

    private func executeNext() {
        guard !queue.isEmpty else {
            isExecuting = false
            currentCommandText = ""
            return
        }

        let cmd = queue.removeFirst()
        isExecuting = true
        currentCommandText = cmd.text
        currentDeliveryID = cmd.deliveryID

        log("[Execution] started: '\(cmd.text)'")

        generation += 1
        let myGeneration = generation

        activeTask = Task { [weak self] in
            guard let self else { return }

            await cmd.handler()

            await MainActor.run {
                // A superseded task must not touch the bookkeeping of the
                // command that replaced it.
                guard myGeneration == self.generation else { return }
                if !Task.isCancelled {
                    self.log("[Execution] finished: '\(cmd.text)'")
                }
                self.activeTask = nil
                self.currentDeliveryID = nil
                self.isExecuting = false
                self.currentCommandText = ""
                self.drainIfIdle()
            }
        }

        // Cancel before releasing the slot. Executors check cancellation
        // between actions, so an expired plan cannot resume its side effects.
        let seconds = Self.executionWatchdogSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                guard let self, myGeneration == self.generation, self.isExecuting else { return }
                self.log("[Execution] watchdog: '\(cmd.text)' exceeded \(Int(seconds)) s — releasing the queue slot")
                self.activeTask?.cancel()
                self.onCancel?()
                self.generation += 1
                self.activeTask = nil
                self.currentDeliveryID = nil
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
        // One policy owner; the routing migration flag cannot change queue semantics.
        switch coreClassifyCommandPriority(text: text) {
        case .high: return .high
        case .normal: return .normal
        }
    }
}
