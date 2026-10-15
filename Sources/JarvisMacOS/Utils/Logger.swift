import Foundation

final class Logger {
    private let fileManager = Foundation.FileManager.default
    private let logURL: URL

    init(logURL: URL? = nil) {
        let support = logURL?.deletingLastPathComponent() ?? RuntimeConfiguration.dataDirectory
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.logURL = logURL ?? support.appendingPathComponent("commands.log")
        if !fileManager.fileExists(atPath: self.logURL.path) {
            fileManager.createFile(atPath: self.logURL.path, contents: nil)
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
