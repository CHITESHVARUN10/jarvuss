import Foundation

final class Logger {
    private let fileManager = Foundation.FileManager.default
    private let logURL: URL

    init() {
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let logsDir = root.appendingPathComponent("logs", isDirectory: true)

        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        logURL = logsDir.appendingPathComponent("commands.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
    }

    @discardableResult
    func log(event: String) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(event)"
        let persisted = line + "\n"

        print(line)

        guard let data = persisted.data(using: .utf8) else { return line }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }

        return line
    }

    func log(command: String) {
        _ = log(event: "COMMAND: \(command)")
    }
}
