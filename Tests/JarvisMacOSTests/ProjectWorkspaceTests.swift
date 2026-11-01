import XCTest
@testable import JarvisMacOS

final class ProjectWorkspaceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func directory(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testRootScopeDuplicatesAliasesAndNormalization() throws {
        let root = try temporaryRoot()
        let first = try directory("work/Portfolio-Site", in: root)
        _ = try directory("personal/portfolio site", in: root)
        let locations = [ProjectLocation(name: "Work", path: root.appendingPathComponent("work").path, isRoot: true), ProjectLocation(name: "Personal", path: root.appendingPathComponent("personal").path, isRoot: true)]
        XCTAssertEqual(try ProjectDirectoryResolver.find("portfolio site", locations: locations).count, 2)
        XCTAssertEqual(try ProjectDirectoryResolver.find("Portfolio Site", root: "Work", locations: locations).first?.url, first)
        let alias = ProjectLocation(name: "website", path: first.path, isRoot: false)
        XCTAssertEqual(try ProjectDirectoryResolver.find("website", locations: [alias]).first?.url, first)
    }
    func testBoundedTraversalExcludesDependenciesHiddenAndSymlinkEscapes() throws {
        let root = try temporaryRoot(), outside = try temporaryRoot()
        _ = try directory("node_modules/hidden-project", in: root)
        _ = try directory(".cache/hidden-project", in: root)
        _ = try directory("one/two/three/too-deep", in: root)
        _ = try directory("escape-project", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut"), withDestinationURL: outside)
        let locations = [ProjectLocation(name: "projects", path: root.path, isRoot: true)]
        for query in ["hidden-project", "too-deep", "escape-project"] { XCTAssertTrue(try ProjectDirectoryResolver.find(query, locations: locations).isEmpty) }
        XCTAssertThrowsError(try ProjectDirectoryResolver.find("one", locations: locations, maxEntries: 0))
        XCTAssertThrowsError(try ProjectDirectoryResolver.find("../outside", locations: locations))
    }
    func testDirectProjectWinsWithoutScanningItsLargeSubtree() throws {
        let root = try temporaryRoot()
        let direct = try directory("portfolio", in: root)
        for n in 0..<10 { _ = try directory("portfolio/generated/nested/\(n)", in: root) }
        let result = try ProjectDirectoryResolver.find("portfolio", locations: [.init(name: "projects", path: root.path, isRoot: true)], maxEntries: 2)
        XCTAssertEqual(result.first?.url, direct)
    }
    @MainActor
    func testFailedDestinationDoesNotCreateRecentContext() async throws {
        let root = try temporaryRoot(); _ = try directory("portfolio", in: root)
        let suite = "jarvis-project-failure-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectLocationStore(defaults: defaults)
        store.locations = [.init(name: "projects", path: root.path, isRoot: true)]
        let controller = ProjectWorkspaceController(store: store, open: { _, _ in throw ProjectResolutionError.message("Fixture launch failure") })
        let first = await controller.execute(.init(operation: .openProject, app: .finder, project: "portfolio"))
        XCTAssertFalse(first.success)
        let followup = await controller.execute(.init(operation: .openProject, app: .terminal, project: "@recent"))
        XCTAssertFalse(followup.success); XCTAssertTrue(followup.message.contains("named project first"))
    }
    func testUnavailableRootDoesNotSearchElsewhere() {
        XCTAssertThrowsError(try ProjectDirectoryResolver.find("portfolio", locations: [.init(name: "offline", path: "/nonexistent-fixture-drive", isRoot: true)]))
        XCTAssertThrowsError(try ProjectDirectoryResolver.find("portfolio", root: "missing", locations: []))
    }
    @MainActor
    func testPersistenceAndRecentProjectScopeExpiryAndFailedOpen() async throws {
        let root = try temporaryRoot(), project = try directory("portfolio", in: root)
        let suite = "jarvis-workspace-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectLocationStore(defaults: defaults)
        store.locations = [.init(name: "projects", path: root.path, isRoot: true)]
        XCTAssertEqual(ProjectLocationStore(defaults: defaults).locations, store.locations)
        var clock = Date(), opened: [URL] = []
        let controller = ProjectWorkspaceController(store: store, choose: { _ in XCTFail("Unique match must not ask"); return nil }, open: { _, url in
            opened.append(url!); return "opened"
        }, now: { clock })
        var result = await controller.execute(.init(operation: .openProject, app: .vscode, project: "@recent"))
        XCTAssertFalse(result.success)
        result = await controller.execute(.init(operation: .openProject, app: .finder, project: "portfolio")); XCTAssertTrue(result.success)
        result = await controller.execute(.init(operation: .openProject, app: .terminal, project: "@recent")); XCTAssertTrue(result.success)
        XCTAssertEqual(opened, [project, project])
        clock.addTimeInterval(601)
        result = await controller.execute(.init(operation: .openProject, app: .vscode, project: "@recent")); XCTAssertFalse(result.success)
        result = await controller.execute(.init(operation: .openProject, app: .finder, project: "portfolio")); XCTAssertTrue(result.success)
        store.locations = []
        result = await controller.execute(.init(operation: .openProject, app: .vscode, project: "@recent")); XCTAssertFalse(result.success)
    }
    @MainActor
    func testAmbiguityChoosesExplicitlyAndCancellationNeverOpens() async throws {
        let root = try temporaryRoot()
        _ = try directory("work/portfolio", in: root); _ = try directory("personal/portfolio", in: root)
        let suite = "jarvis-project-choice-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectLocationStore(defaults: defaults)
        store.locations = [.init(name: "projects", path: root.path, isRoot: true)]
        var choiceCount = 0, opened = 0
        let controller = ProjectWorkspaceController(store: store, choose: { choices in choiceCount += 1; XCTAssertEqual(choices.count, 2); return nil }, open: { _, _ in opened += 1; return "opened" })
        let result = await controller.execute(.init(operation: .openProject, app: .finder, project: "portfolio"))
        XCTAssertFalse(result.success); XCTAssertEqual(choiceCount, 1); XCTAssertEqual(opened, 0)
        let chosen = ProjectWorkspaceController(store: store, choose: { $0.first }, open: { _, _ in opened += 1; return "opened" })
        let success = await chosen.execute(.init(operation: .openProject, app: .finder, project: "portfolio"))
        XCTAssertTrue(success.success); XCTAssertEqual(opened, 1)
    }
}
