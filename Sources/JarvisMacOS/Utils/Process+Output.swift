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
    func set(_ data: Data, isError: Bool) {
        lock.withLock {
            if isError { error = data } else { output = data }
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
    func runCapturingOutput(timeout: TimeInterval) throws -> ProcessOutput {
        let output = Pipe()
        let error = Pipe()
        standardOutput = output
        standardError = error
        standardInput = FileHandle.nullDevice
        try run()
        let buffer = ProcessOutputBuffer()
        let readers = DispatchGroup()
        for (pipe, isError) in [(output, false), (error, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                buffer.set((try? pipe.fileHandleForReading.readToEnd()) ?? Data(), isError: isError)
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
}
