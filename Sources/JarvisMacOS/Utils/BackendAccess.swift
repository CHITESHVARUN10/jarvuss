import Foundation

enum BackendAccessError: Error {
    case unavailable
}

/// Never send the local credential to remote configured endpoints or through
/// a redirect. Reading for each request also handles backend token rotation.
enum BackendAccess {
    static let header = "X-Jarvis-Token"

    static func authorize(_ request: inout URLRequest, tokenURL: URL? = nil) throws {
        guard let url = request.url, ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              url.port == 8000 else { return }
        guard url.scheme == "http" else { throw BackendAccessError.unavailable }
        let file = tokenURL ?? RuntimeConfiguration.dataDirectory.appendingPathComponent("backend_auth.token")
        guard let token = try? String(contentsOf: file, encoding: .utf8),
              token.count >= 32, token.count <= 128,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw BackendAccessError.unavailable
        }
        request.setValue(token, forHTTPHeaderField: header)
    }

    static func data(for original: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        var request = original
        try authorize(&request)
        return try await session.data(for: request, delegate: NoRedirects())
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
