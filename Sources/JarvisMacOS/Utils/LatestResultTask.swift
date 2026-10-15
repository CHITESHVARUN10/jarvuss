import Foundation

/// Main-queue session work. Cancellation is supplemented by a generation
/// check because external work may return even after it has been cancelled.
final class LatestResultTask<Value> {
    private(set) var generation = UUID()
    private var task: Task<Void, Never>?

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func start(operation: @escaping () async -> Value,
               completion: @escaping @MainActor (Value) -> Void) {
        invalidate()
        let token = generation
        task = Task { @MainActor [weak self] in
            let result = await operation()
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.task = nil
            completion(result)
        }
    }

    deinit { task?.cancel() }
}
