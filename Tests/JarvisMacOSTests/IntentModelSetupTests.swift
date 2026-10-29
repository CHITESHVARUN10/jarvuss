import XCTest
@testable import JarvisMacOS

final class IntentModelSetupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-intent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRejectsUnsafeNamesDuplicateFilesOversizeAndIncompatibleReleases() throws {
        let fixture = try Fixture()
        var object = try JSONSerialization.jsonObject(with: fixture.release.manifestData) as! [String: Any]
        for (key, value) in [("format_version", 2), ("intent_schema_version", 99), ("max_target_len", 999)] {
            var invalid = object; invalid[key] = value
            let manifest = try JSONDecoder().decode(IntentModelRelease.self, from: JSONSerialization.data(withJSONObject: invalid))
            XCTAssertThrowsError(try manifest.validate())
        }
        for name in ["../credentials", "/Users/example/private", "plugin.py", "download.sh"] {
            var files = object["files"] as! [[String: Any]]; files[0]["name"] = name
            var invalid = object; invalid["files"] = files
            let manifest = try JSONDecoder().decode(IntentModelRelease.self, from: JSONSerialization.data(withJSONObject: invalid))
            XCTAssertThrowsError(try manifest.validate())
        }
        var files = object["files"] as! [[String: Any]]
        files[0] = files[1]; object["files"] = files
        XCTAssertThrowsError(try JSONDecoder().decode(IntentModelRelease.self, from: JSONSerialization.data(withJSONObject: object)).validate())
    }

    func testLicensedReleaseRequiresAndInstallsVerifiedNotices() async throws {
        let fixture = try Fixture()
        var object = try JSONSerialization.jsonObject(with: fixture.release.manifestData) as! [String: Any]
        object["license"] = "apache-2.0"
        XCTAssertThrowsError(try JSONDecoder().decode(IntentModelRelease.self, from: JSONSerialization.data(withJSONObject: object)).validate())
        var files = object["files"] as! [[String: Any]]
        let notice = Data("Sample Apache license notice".utf8)
        for name in ["LICENSE", "NOTICE"] {
            files.append(["name": name, "size_bytes": notice.count, "sha256": intentSHA256(notice)])
        }
        object["files"] = files
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let release = RemoteIntentRelease(commit: fixture.release.commit, manifest: try JSONDecoder().decode(IntentModelRelease.self, from: encoded), manifestData: encoded)
        let storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging()
        try fixture.write(to: stage)
        for name in ["LICENSE", "NOTICE"] { try notice.write(to: stage.appendingPathComponent(name)) }
        let receipt = try await storage.activate(release, staging: stage)
        let folder = root.appendingPathComponent("versions").appendingPathComponent(receipt.directory)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("LICENSE")), notice)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("NOTICE")), notice)
    }

    func testInstallVerifiesAndAtomicallyActivatesImmutableVersion() async throws {
        let fixture = try Fixture()
        let storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging()
        try fixture.write(to: stage)
        let receipt = try await storage.activate(fixture.release, staging: stage)
        XCTAssertEqual(receipt.version, "1.0.0")
        let local = await storage.inspect()
        XCTAssertEqual(local.receipt, receipt)
        XCTAssertTrue(local.installed)
        XCTAssertEqual(try JSONDecoder().decode(IntentModelReceipt.self, from: Data(contentsOf: root.appendingPathComponent("current.json"))), receipt)
    }

    func testActivationAcceptsEquivalentDirectoryURLsWithOrWithoutTrailingSlash() async throws {
        let fixture = try Fixture()
        let storage = IntentModelStorage(root: URL(fileURLWithPath: root.path, isDirectory: false))
        let stage = try await storage.createStaging(); try fixture.write(to: stage)
        let selected = try await storage.activate(fixture.release, staging: stage)
        XCTAssertEqual(selected.version, "1.0.0")
    }

    func testChecksumFailureAndMissingFileKeepPreviousInstallation() async throws {
        let fixture = try Fixture()
        let storage = IntentModelStorage(root: root)
        let initial = try await storage.createStaging(); try fixture.write(to: initial)
        let previous = try await storage.activate(fixture.release, staging: initial)
        for missing in [false, true] {
            let stage = try await storage.createStaging(); try fixture.write(to: stage)
            let file = stage.appendingPathComponent("encoder_model_quantized.onnx")
            if missing { try FileManager.default.removeItem(at: file) }
            else { try Data("changed encoder".utf8).write(to: file) }
            do { _ = try await storage.activate(fixture.release, staging: stage); XCTFail("Bad update must be rejected") }
            catch {}
            let local = await storage.inspect()
            XCTAssertEqual(local.receipt, previous)
        }
    }

    func testSymlinkAndMismatchedManifestCannotActivate() async throws {
        let fixture = try Fixture(), storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging(); try fixture.write(to: stage)
        let file = stage.appendingPathComponent("config.json")
        let elsewhere = root.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at: file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        do { _ = try await storage.activate(fixture.release, staging: stage); XCTFail("Symlink must fail") } catch {}
        let mismatch = RemoteIntentRelease(commit: fixture.release.commit, manifest: fixture.release.manifest, manifestData: Data("{}".utf8))
        XCTAssertThrowsError(try mismatch.validate())
        let local = await storage.inspect(); XCTAssertFalse(local.installed)
    }

    func testDamagedReceiptCannotEscapeModelStore() async throws {
        let receipt = IntentModelReceipt(commit: String(repeating: "a", count: 40), version: "1.0.0", directory: "../../other", manifestSHA256: String(repeating: "b", count: 64), generation: "test")
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("current.json"))
        let local = await IntentModelStorage(root: root).inspect()
        XCTAssertNil(local.receipt)
    }

    @MainActor
    func testMissingModelAutomaticallyDownloadsOnceWithoutBackend() async throws {
        let remote = try FakeRemote()
        let model = IntentModelSetup(storage: IntentModelStorage(root: root), remote: remote)
        model.startAutomaticSetup(); model.startAutomaticSetup()
        await model.waitForIdle()
        XCTAssertTrue(model.isInstalled)
        XCTAssertEqual(model.installedVersion, "1.0.0")
        XCTAssertFalse(model.updateAvailable)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(remote.checks, 1)
        XCTAssertEqual(remote.downloads, 6)
    }

    @MainActor
    func testUpdateChecksDoNotDownloadAndFailureKeepsInstalledVersion() async throws {
        let first = try Fixture(), storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging(); try first.write(to: stage)
        _ = try await storage.activate(first.release, staging: stage)
        let remote = try FakeRemote(version: "1.1.0"); remote.failDownload = true
        let model = IntentModelSetup(storage: storage, remote: remote)
        model.checkForUpdates(); await model.waitForIdle()
        XCTAssertTrue(model.updateAvailable)
        XCTAssertEqual(model.latestVersion, "1.1.0")
        XCTAssertEqual(remote.downloads, 0)
        model.installLatest(); await model.waitForIdle()
        XCTAssertEqual(model.installedVersion, "1.0.0")
        let local = await storage.inspect(); XCTAssertEqual(local.receipt?.version, "1.0.0")
        XCTAssertTrue(model.message.contains("still available"))
    }

    @MainActor
    func testExistingManagedModelWorksOfflineAndNeverAutoDowngrades() async throws {
        let first = try Fixture(version: "2.0.0"), storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging(); try first.write(to: stage)
        _ = try await storage.activate(first.release, staging: stage)
        let remote = try FakeRemote(version: "1.0.0")
        let model = IntentModelSetup(storage: storage, remote: remote)
        model.startAutomaticSetup(); await model.waitForIdle()
        XCTAssertTrue(model.isInstalled); XCTAssertEqual(remote.checks, 0)
        model.installLatest(); await model.waitForIdle()
        XCTAssertEqual(model.installedVersion, "2.0.0"); XCTAssertEqual(remote.downloads, 0)
        remote.failCheck = true
        model.checkForUpdates(); await model.waitForIdle()
        XCTAssertTrue(model.isInstalled); XCTAssertEqual(model.installedVersion, "2.0.0")
    }

    @MainActor
    func testCancellationDiscardsDownloadAndKeepsExistingModel() async throws {
        let fixture = try Fixture(), storage = IntentModelStorage(root: root)
        let stage = try await storage.createStaging(); try fixture.write(to: stage)
        let previous = try await storage.activate(fixture.release, staging: stage)
        let remote = try FakeRemote(version: "1.1.0"); remote.delayDownload = true
        let model = IntentModelSetup(storage: storage, remote: remote)
        model.installLatest()
        while !model.isDownloading { await Task.yield() }
        model.cancel(); await model.waitForIdle()
        let local = await storage.inspect()
        XCTAssertEqual(local.receipt, previous)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.message.contains("cancelled"))
        let remnants = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("download-") }
        XCTAssertTrue(remnants.isEmpty)
    }

    func testVersionOrderingIncludingLargeNumbersAndPrereleases() {
        XCTAssertTrue(versionIsOlder("1.9.0", than: "1.10.0"))
        XCTAssertTrue(versionIsOlder("1.0.0-beta.2", than: "1.0.0-beta.10"))
        XCTAssertTrue(versionIsOlder("1.0.0-beta", than: "1.0.0"))
        XCTAssertFalse(versionIsOlder("2.0.0", than: "1.100.0"))
        XCTAssertFalse(versionIsOlder("1.0.0", than: "1.0.0"))
        XCTAssertTrue(versionIsOlder("999999999999999999999.0.0", than: "1000000000000000000000.0.0"))
    }
}

private struct Fixture {
    let release: RemoteIntentRelease
    let data: [String: Data]
    init(version: String = "1.0.0") throws {
        let payloads = ["encoder_model_quantized.onnx": Data("example encoder".utf8), "decoder_model_merged_quantized.onnx": Data("example decoder".utf8),
                "config.json": Data(#"{"model_type":"t5"}"#.utf8), "added_tokens.json": Data("{}".utf8), "spiece.model": Data("example tokenizer".utf8), "model_meta.json": Data("{}".utf8)]
        data = payloads
        let object: [String: Any] = ["format_version": 1, "runtime": "jarvis-t5-onnx-v1", "version": version, "intent_schema_version": 3,
                                   "max_source_len": 128, "max_target_len": 448, "files": payloads.keys.sorted().map { ["name": $0, "size_bytes": payloads[$0]!.count, "sha256": intentSHA256(payloads[$0]!)] as [String: Any] }]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        release = RemoteIntentRelease(commit: String(repeating: "a", count: 40), manifest: try JSONDecoder().decode(IntentModelRelease.self, from: bytes), manifestData: bytes)
    }
    func write(to folder: URL) throws { for (name, bytes) in data { try bytes.write(to: folder.appendingPathComponent(name)) } }
}

private final class FakeRemote: IntentModelRemote, @unchecked Sendable {
    let fixture: Fixture
    var failDownload = false, failCheck = false, delayDownload = false
    var checks = 0, downloads = 0
    init(version: String = "1.0.0") throws { fixture = try Fixture(version: version) }
    func latest() async throws -> RemoteIntentRelease {
        checks += 1
        if failCheck { throw URLError(.notConnectedToInternet) }
        return fixture.release
    }
    func download(_ file: IntentModelRelease.File, release: RemoteIntentRelease, into directory: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        downloads += 1
        if delayDownload { try await Task.sleep(for: .seconds(30)) }
        if failDownload { throw URLError(.networkConnectionLost) }
        try fixture.data[file.name]!.write(to: directory.appendingPathComponent(file.name))
        progress(file.sizeBytes)
    }
}
