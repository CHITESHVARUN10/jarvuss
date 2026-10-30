import Foundation
import Network

struct CommandTestRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParsingError: Error { case invalid, tooLarge }
    static func parse(_ data: Data) throws -> CommandTestRequest? {
        guard data.count <= 82_000 else { throw ParsingError.tooLarge }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw ParsingError.tooLarge }; return nil
        }
        guard boundary.lowerBound <= 16_384,
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw ParsingError.invalid }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])),
              first[1].hasPrefix("/"), !first[1].contains("?"), !first[1].contains("#") else { throw ParsingError.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ParsingError.invalid }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { throw ParsingError.invalid }; headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw ParsingError.invalid }
        let length: Int
        if let header = headers["content-length"] {
            guard let size = Int(header), size >= 0, size <= 65_536 else { throw ParsingError.tooLarge }; length = size
        } else { guard first[0] == "GET" else { throw ParsingError.invalid }; length = 0 }
        let available = data.count - boundary.upperBound
        guard available >= length else { return nil }
        guard available == length else { throw ParsingError.invalid }
        return CommandTestRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[boundary.upperBound...]))
    }
}

struct CommandTestResponse {
    let status: Int
    let contentType: String
    let body: Data
    static func json(_ status: Int = 200, _ value: Any) -> Self {
        Self(status: status, contentType: "application/json", body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    var bytes: Data {
        let name = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Unavailable"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(name)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

final class CommandTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "jarvis.command-test-http")
    private let handler: @Sendable (CommandTestRequest) async -> CommandTestResponse
    private var connections: [UUID: NWConnection] = [:] // confined to queue
    private var startupCompleted = false // confined to queue
    init(handler: @escaping @Sendable (CommandTestRequest) async -> CommandTestResponse) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startupCompleted else { return }
                switch state {
                case .ready:
                    self.startupCompleted = true
                    if let port = self.listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: CommandTestRequest.ParsingError.invalid) }
                case .failed(let error): self.startupCompleted = true; continuation.resume(throwing: error)
                case .cancelled: self.startupCompleted = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id)
        }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, ended, error in
            guard let self else { connection.cancel(); return }
            var all = buffer; if let bytes { all.append(bytes) }
            do {
                if let request = try CommandTestRequest.parse(all) {
                    Task {
                        let reply = await self.handler(request)
                        connection.send(content: reply.bytes, completion: .contentProcessed { _ in connection.cancel() })
                        self.queue.async { self.connections.removeValue(forKey: id) }
                    }
                } else if ended || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, buffer: all) }
            } catch {
                let status: Int
                if case CommandTestRequest.ParsingError.tooLarge = error { status = 413 } else { status = 400 }
                let reply = CommandTestResponse.json(status, ["error": "Invalid or oversized request"])
                connection.send(content: reply.bytes, completion: .contentProcessed { _ in connection.cancel() })
                self.connections.removeValue(forKey: id)
            }
        }
    }
}

extension CommandTestHarness {
    func handle(_ request: CommandTestRequest) async -> CommandTestResponse {
        guard isRunning, request.headers["host"] == "127.0.0.1:\(port)",
              request.headers["origin"] == nil || request.headers["origin"] == origin else {
            return .json(403, ["error": "Test mode is off or origin is not allowed"])
        }
        if request.method == "GET", request.path == "/" {
            let bundled = Bundle.main.url(forResource: "command-test-runner", withExtension: "html")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("htmls/command-test-runner.html")
            guard let data = try? Data(contentsOf: bundled ?? source) else { return .json(404, ["error": "Runner HTML is missing; rebuild the app"] ) }
            return CommandTestResponse(status: 200, contentType: "text/html; charset=utf-8", body: data)
        }
        guard request.headers["x-jarvis-test-token"] == token else { return .json(403, ["error": "Open the runner from Jarvis to authorize this test session"] ) }
        if request.method == "GET", request.path == "/api/state" {
            return .json(200, ["enabled": isRunning, "revision": DiagnosticBuild.current.revision, "rust_pipeline": JarvisFlags.useRustPipeline,
                               "log_directory": directory.path, "modes": ["execute", "plan", "intent", "dictation"]])
        }
        if request.method == "GET", request.path == "/api/runs" || request.path == "/api/export" {
            guard let data = try? Self.encode(runs) else { return .json(500, ["error": "Could not encode runs"]) }
            return CommandTestResponse(status: 200, contentType: "application/json", body: data)
        }
        guard request.method == "POST", request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .json(400, ["error": "Use a JSON request body"])
        }
        do {
            if request.path == "/api/run", let command = object["command"] as? String, let mode = object["mode"] as? String {
                let run = try submit(command: command, mode: mode)
                return .json(202, ["id": run.id.uuidString])
            }
            if request.path == "/api/cancel" { cancelActive(); return .json(200, ["cancel_requested": true]) }
            if request.path == "/api/review", let rawID = object["id"] as? String, let id = UUID(uuidString: rawID),
               let verdict = object["verdict"] as? String, let notes = object["notes"] as? String {
                try review(id: id, verdict: verdict, notes: notes)
                return .json(200, ["saved": true])
            }
            return .json(404, ["error": "Unknown test endpoint"])
        } catch { return .json(409, ["error": error.localizedDescription]) }
    }
}
