import Foundation

/// FIFO admission for local inference. Waiting and running requests remain
/// children of their caller, so cancellation releases both queue and HTTP work.
actor InferenceGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied {
            occupied = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
