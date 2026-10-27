import XCTest
@testable import JarvisMacOS

final class CredentialBrokerTests: XCTestCase {
    func testAuthenticatedRequestsAreScopedCachedAndInvalidatedBySettingsEdits() throws {
        var stored = ["SPOTIFY_CLIENT_SECRET": "synthetic-value"]
        var reads: [String] = []
        var revision = "one"
        let broker = CredentialBroker(readSecret: { reads.append($0); return stored[$0] },
            writeSecret: { stored[$0] = $1 }, settingsRevision: { revision })
        let env = try broker.environment()
        defer { broker.stop() }
        func request(_ fields: [String: Any], authenticated: Bool = true) throws -> [String: Any] {
            var fields = fields
            fields["token"] = authenticated ? env["JARVIS_CREDENTIAL_TOKEN"] : "invalid"
            return try XCTUnwrap(JSONSerialization.jsonObject(with: broker.handle(JSONSerialization.data(withJSONObject: fields))) as? [String: Any])
        }
        XCTAssertFalse(try XCTUnwrap(request(["operation": "get", "keys": ["PGPASSWORD"]], authenticated: false)["ok"] as? Bool))
        XCTAssertFalse(try XCTUnwrap(request(["operation": "get", "keys": ["arbitrary-key"]])["ok"] as? Bool))
        XCTAssertTrue(reads.isEmpty)
        let query: [String: Any] = ["operation": "get", "keys": ["SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN"]]
        for _ in 0..<6 {
            let response = try request(query)
            XCTAssertEqual((response["values"] as? [String: Any])?["SPOTIFY_CLIENT_SECRET"] as? String, "synthetic-value")
        }
        XCTAssertEqual(reads.sorted(), ["SPOTIFY_ACCESS_TOKEN", "SPOTIFY_CLIENT_SECRET"])
        stored["SPOTIFY_CLIENT_SECRET"] = "updated-by-setup"
        revision = "two"
        XCTAssertEqual((try request(query)["values"] as? [String: Any])?["SPOTIFY_CLIENT_SECRET"] as? String, "updated-by-setup")
        _ = try request(["operation": "set", "values": ["SPOTIFY_ACCESS_TOKEN": "refreshed"]])
        XCTAssertEqual(stored["SPOTIFY_ACCESS_TOKEN"], "refreshed")
        _ = try request(["operation": "set", "values": ["SPOTIFY_ACCESS_TOKEN": ""]])
        XCTAssertEqual(stored["SPOTIFY_ACCESS_TOKEN"], "", "Token clearing must not mean keep the previous token")
        let permissions = try FileManager.default.attributesOfItem(atPath: env["JARVIS_CREDENTIAL_SOCKET"]!)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(env["JARVIS_CREDENTIAL_OWNER_PID"], String(getpid()))
    }

    func testDeniedAccessDoesNotRepeatPromptsOrExposeSecretsInErrors() throws {
        var reads = 0
        var revision = "one"
        let broker = CredentialBroker(readSecret: { _ in
            reads += 1
            throw NSError(domain: "private synthetic token must not appear", code: -128)
        }, writeSecret: { _, _ in XCTFail("Denial must not overwrite credentials") }, settingsRevision: { revision })
        let env = try broker.environment()
        defer { broker.stop() }
        let query = try JSONSerialization.data(withJSONObject: ["token": env["JARVIS_CREDENTIAL_TOKEN"]!, "operation": "get", "keys": ["SPOTIFY_CLIENT_SECRET"]])
        for _ in 0..<4 {
            let reply = broker.handle(query)
            XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("private synthetic"))
        }
        XCTAssertEqual(reads, 1)
        revision = "user-saved-connection"
        _ = broker.handle(query)
        XCTAssertEqual(reads, 2)
    }
    func testPythonHelperUsesTheNativeSocketForReadsAndRefreshedTokenWrites() async throws {
        var stored = ["SPOTIFY_CLIENT_SECRET": "synthetic-client-secret"]
        let broker = CredentialBroker(readSecret: { stored[$0] }, writeSecret: { stored[$0] = $1 }, settingsRevision: { "fixed" })
        let environment = try broker.environment()
        defer { broker.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", "-c", """
        import os
        import runtime_config as config
        def forbidden(*args, **kwargs):
            raise AssertionError('Python must never open Keychain')
        config.Keychain = forbidden
        store = config.RuntimeConfig()
        assert store.load({}, secret_keys={'SPOTIFY_CLIENT_SECRET'})['SPOTIFY_CLIENT_SECRET'] == 'synthetic-client-secret'
        store.save({'SPOTIFY_ACCESS_TOKEN': 'synthetic-refreshed', 'SPOTIFY_ACCESS_TOKEN_EXPIRES_AT': '123'})
        assert store.load({}, secret_keys={'SPOTIFY_ACCESS_TOKEN'})['SPOTIFY_ACCESS_TOKEN'] == 'synthetic-refreshed'
        bridge = config.AppCredentialStore(os.environ['JARVIS_CREDENTIAL_SOCKET'], 'wrong-token')
        try:
            bridge.get('PGPASSWORD')
        except RuntimeError:
            pass
        else:
            raise AssertionError('Unauthenticated request succeeded')
        """]
        var env = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
        env["PYTHONPATH"] = root.appendingPathComponent("backend").path
        env["JARVIS_DATA_DIR"] = directory.path
        process.environment = env
        let result = try await process.runCapturingOutputAsync(timeout: 15)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(stored["SPOTIFY_ACCESS_TOKEN"], "synthetic-refreshed")
        let publicSettings = try String(contentsOf: directory.appendingPathComponent("connection_settings.json"), encoding: .utf8)
        XCTAssertFalse(publicSettings.contains("synthetic-"))
    }

}
