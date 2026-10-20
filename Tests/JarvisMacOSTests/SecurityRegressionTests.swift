import XCTest
@testable import JarvisMacOS

final class SecurityRegressionTests: XCTestCase {
    func testAppNameIsDataNotAppleScriptSource() {
        let payload = "myapp\" & (do shell script \"touch /tmp/should-not-run\") & \""
        let arguments = AppController.quitArguments(appName: payload)
        XCTAssertEqual(arguments.last, payload)
        XCTAssertFalse(arguments[1].contains(payload))
        XCTAssertFalse(arguments[1].contains("do shell script"))
        XCTAssertEqual(arguments[2], "--")
        XCTAssertEqual(AppController.quitArguments(appName: "Safari")[1], arguments[1])
    }

    func testCreationUsesExplicitDirectoryAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("files")
        let manager = JarvisFileManager(creationDirectory: destination)
        XCTAssertTrue(manager.createFileResult(named: "notes.txt").success)
        let target = destination.appendingPathComponent("notes.txt")
        try Data("keep this".utf8).write(to: target)
        XCTAssertFalse(manager.createFileResult(named: "notes.txt").success)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep this")
        XCTAssertTrue(manager.createFolderResult(named: "nested/folder").success)
        XCTAssertFalse(manager.createFileResult(named: "../escape.txt").success)
        XCTAssertFalse(manager.createFileResult(named: "/escape.txt").success)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertFalse(manager.createFileResult(named: "link/escape.txt").success)
        XCTAssertEqual(JarvisFileManager().creationDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Jarvis").standardizedFileURL.path)
    }

    func testSearchTextStaysInOneQueryItem() throws {
        let query = "cats & dogs = C++ #tag 100%"
        let url = try XCTUnwrap(ActionExecutor.searchURL(base: "https://www.google.com/search?q=", query: query))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(parts.fragment)
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "q", value: query)])
        XCTAssertTrue(url.absoluteString.contains("%2B%2B"))
    }

    func testHTTPRejectionsDoNotBecomeOfflineVerificationFallbacks() {
        for status in [400, 401, 403, 422, 500, 503] {
            let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/verify")!,
                statusCode: status, httpVersion: nil, headerFields: nil)!
            do {
                try VoiceAuthClient.validate(response)
                XCTFail("HTTP rejection must remain an error")
            } catch {
                let classified = VoiceAuthClient.classify(error)
                XCTAssertFalse(VoiceAuthClient.isUnavailable(classified))
                guard case VoiceAuthClientError.rejected(let code) = classified else {
                    XCTFail("HTTP status lost"); continue
                }
                XCTAssertEqual(code, status)
            }
        }
        XCTAssertTrue(VoiceAuthClient.isUnavailable(VoiceAuthClient.classify(URLError(.cannotConnectToHost))))
        XCTAssertTrue(VoiceAuthClient.classify(URLError(.cancelled)) is CancellationError)
    }

    func testLocalTokenRotatesAndNeverGoesToRemoteEndpoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token")
        var local = URLRequest(url: URL(string: "http://127.0.0.1:8000/health")!)
        XCTAssertThrowsError(try BackendAccess.authorize(&local, tokenURL: file))
        let first = String(repeating: "a", count: 43)
        try first.write(to: file, atomically: true, encoding: .utf8)
        try BackendAccess.authorize(&local, tokenURL: file)
        XCTAssertEqual(local.value(forHTTPHeaderField: BackendAccess.header), first)
        let second = String(repeating: "b", count: 43)
        try second.write(to: file, atomically: true, encoding: .utf8)
        try BackendAccess.authorize(&local, tokenURL: file)
        XCTAssertEqual(local.value(forHTTPHeaderField: BackendAccess.header), second)
        var remote = URLRequest(url: URL(string: "https://example.com:8000/health")!)
        try BackendAccess.authorize(&remote, tokenURL: file)
        XCTAssertNil(remote.value(forHTTPHeaderField: BackendAccess.header))
    }
}

@MainActor
final class RouterRecoveryTests: XCTestCase {
    func testBothPreemptionTimeoutsReleaseTheVADMute() {
        for action in [false, true] {
            var callbacks: [@MainActor () -> Void] = []
            var failed = 0
            let router = STTRouter(currentPhase: { .Preparing }, cancelCapture: {},
                startModal: { _ in XCTFail("Not ready") }, startFailed: { failed += 1 },
                scheduleRetry: { callbacks.append($0) })
            XCTAssertTrue(router.claimForCommand())
            XCTAssertTrue(action ? router.preemptCommandForAction() : router.preemptCommandForPill())
            XCTAssertTrue(router.pillSuppressesCommandVAD)
            while !callbacks.isEmpty { callbacks.removeFirst()() }
            XCTAssertEqual(failed, 1)
            XCTAssertFalse(router.pillSuppressesCommandVAD)
            XCTAssertTrue(router.claimForCommand(), "A failed pill must not leave live mode deaf")
        }
    }

    func testCancellationInvalidatesRetryButKeepsAnActivePillMuted() {
        var callbacks: [@MainActor () -> Void] = []
        let router = STTRouter(currentPhase: { .Preparing }, cancelCapture: {},
            startModal: { _ in XCTFail("Cancelled retry ran") }, startFailed: {},
            scheduleRetry: { callbacks.append($0) })
        XCTAssertTrue(router.claimForCommand())
        XCTAssertTrue(router.preemptCommandForPill())
        router.cancelPendingModalStarts()
        callbacks.forEach { $0() }
        XCTAssertFalse(router.pillSuppressesCommandVAD)
        XCTAssertTrue(router.claimForPill())
        router.pillSuppressesCommandVAD = true
        router.cancelPendingModalStarts()
        XCTAssertTrue(router.pillSuppressesCommandVAD, "An active pill must retain VAD ownership")
    }
}
