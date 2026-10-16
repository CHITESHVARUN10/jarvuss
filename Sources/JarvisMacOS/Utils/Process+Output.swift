import Foundation

struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    func append(_ data: Data, isError: Bool, limit: Int?) {
        lock.withLock {
            if isError {
                error.append(data)
                if let limit, error.count > limit { error.removeFirst(error.count - limit) }
            } else {
                output.append(data)
                if let limit, output.count > limit { output.removeFirst(output.count - limit) }
            }
        }
    }
    func result(status: Int32, diagnostic: String) -> ProcessOutput {
        lock.withLock {
            ProcessOutput(status: status,
                stdout: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: [String(decoding: error, as: UTF8.self), diagnostic]
                    .filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension Process {
    /// Drain both pipes while the child runs. Waiting before reading can
    /// deadlock as soon as either pipe fills, even for a healthy child.
    func runCapturingOutput(timeout: TimeInterval, input: Data? = nil, outputLimit: Int? = nil) throws -> ProcessOutput {
        let output = Pipe()
        let error = Pipe()
        standardOutput = output
        standardError = error
        let inputPipe = input.map { _ in Pipe() }
        standardInput = inputPipe ?? FileHandle.nullDevice
        try run()
        if let inputPipe, let input {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        let buffer = ProcessOutputBuffer()
        let readers = DispatchGroup()
        for (pipe, isError) in [(output, false), (error, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    buffer.append(chunk, isError: isError, limit: outputLimit.map { max(0, $0) })
                }
            }
        }
        let exited = waitUntilExit(timeout: timeout)
        if readers.wait(timeout: .now() + 2) == .timedOut {
            // A descendant may have inherited a pipe. It cannot extend the
            // parent's deadline indefinitely.
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
        let diagnostic = exited ? "" : (Task<Never, Never>.isCancelled ? "Process cancelled" : "Process timed out")
        return buffer.result(status: exited ? terminationStatus : -1, diagnostic: diagnostic)
    }

    /// Process waiting and pipe reads must never run on the UI actor.
    func runCapturingOutputAsync(timeout: TimeInterval) async throws -> ProcessOutput {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try self.runCapturingOutput(timeout: timeout, outputLimit: 1_048_576)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
