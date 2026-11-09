import Foundation

/// A bounded shared budget across intent, voice and optional generation.
/// Interactive jobs precede formatting; optional work is refused under pressure.
actor InferenceBudget {
    static let shared = InferenceBudget()
    enum Kind: Int, Sendable { case optional = 0, interactive = 1 }
    enum AdmissionError: Error { case pressure, full }
    private struct Waiter {
        let id: UUID
        let kind: Kind
        let continuation: CheckedContinuation<UUID, Error>
    }
    private let capacity: Int
    private var active: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var pressured = false
    private var speechActive = false
    init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    func acquire(_ kind: Kind = .interactive) async throws -> UUID {
        try Task.checkCancellation()
        if kind == .optional && (pressured || speechActive) { throw AdmissionError.pressure }
        let id = UUID()
        if active.count < capacity { active.insert(id); return id }
        guard waiters.count < 8 else { throw AdmissionError.full }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, kind: kind, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        drain()
    }
    func setPressure(_ value: Bool) { pressured = value; rejectOptionalIfNeeded(); drain() }
    func setSpeechActive(_ value: Bool) { speechActive = value; rejectOptionalIfNeeded(); drain() }
    private func rejectOptionalIfNeeded() {
        guard pressured || speechActive else { return }
        let rejected = waiters.filter { $0.kind == .optional }
        waiters.removeAll { $0.kind == .optional }
        for waiter in rejected { waiter.continuation.resume(throwing: AdmissionError.pressure) }
    }
    private func drain() {
        while active.count < capacity, !waiters.isEmpty {
            let index = waiters.firstIndex { $0.kind == .interactive } ?? 0
            let waiter = waiters.remove(at: index)
            active.insert(waiter.id); waiter.continuation.resume(returning: waiter.id)
        }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
    func run<T>(_ kind: Kind = .interactive, operation: () async throws -> T) async throws -> T {
        let permit = try await acquire(kind)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(permit); return result
        } catch { release(permit); throw error }
    }
}
