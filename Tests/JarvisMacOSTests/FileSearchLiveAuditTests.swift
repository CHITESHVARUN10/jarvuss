import XCTest
import AppKit
@testable import JarvisMacOS

/// Opt-in local verification. Private commands/paths live in an external
/// manifest, never in source control or training data. Normal CI skips it.
@MainActor
final class FileSearchLiveAuditTests: XCTestCase {
    private struct Manifest: Decodable {
        let locations: [FileSearchLocation]
        let cases: [Case]
        let actualOpenPaths: [String]
    }
    private struct Case: Decodable {
        let command: String
        let requiredPaths: [String]
        let exactPaths: [String]?
        let success: Bool
        let followup: String?
    }

    func testCommandsAgainstLocalManifest() async throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_FILE_SEARCH_AUDIT_MANIFEST"] else {
            throw XCTSkip("Set JARVIS_FILE_SEARCH_AUDIT_MANIFEST to an owner-local audit manifest")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let suite = "jarvis-live-files-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let locations = FileSearchLocationStore(defaults: defaults)
        locations.locations = manifest.locations
        var opened: [String] = []
        let controller = FileSearchController(locations: locations, presentsUI: false, openFile: { url in
            opened.append(url.path)
            return manifest.actualOpenPaths.contains(url.path) ? NSWorkspace.shared.open(url) : true
        })
        let executor = ActionExecutor(ollamaClient: AuditNoLLM(), fileSearchController: controller)
        let planner = ActionPlanner(ollamaClient: AuditNoLLM(), intentModelRouter: AuditNoIntent(), intentLog: IntentRouterLog(enabled: false))
        let previous = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        setenv("JARVIS_RUST_PIPELINE", "1", 1)
        defer {
            if let previous { setenv("JARVIS_RUST_PIPELINE", previous, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") }
        }
        XCTAssertTrue(JarvisFlags.useRustPipeline)
        var report: [[String: Any]] = []
        for (index, item) in manifest.cases.enumerated() {
            let started = Date()
            guard let command = CommandValidator.validate(item.command) else { XCTFail("Invalid audit command at case \(index)"); continue }
            guard case .allowed = SafetyGuard.validate(rawCommand: command) else { XCTFail("Audit command blocked at case \(index)"); continue }
            let plan = await planner.plan(from: command)
            guard plan.count == 1, case .searchFiles(let request) = plan[0] else {
                XCTFail("Audit case \(index): expected native file search, received \(plan)")
                report.append(["index": index, "command": item.command, "failure": "routing"])
                continue
            }
            let execution = await executor.execute(plan: plan, onStepStart: { _ in }, onStepComplete: { _ in })
            let found = Set(controller.results.map { $0.url.path })
            let missing = Set(item.requiredPaths).subtracting(found)
            let exact = item.exactPaths.map { Set($0) == found } ?? true
            let passed = execution.first?.success == item.success && missing.isEmpty && exact && !controller.searching
            XCTAssertTrue(passed, "Audit case \(index) failed (missing \(missing.count), exact \(exact), status \(controller.status))")
            if item.success {
                if let roots = try? locations.resolve(request.scopes) {
                    XCTAssertTrue(controller.results.allSatisfy { SpotlightSearchSession.isWithinRoots($0.url, roots: roots) })
                }
            }
            var row: [String: Any] = ["index": index, "command": item.command, "passed": passed,
                "milliseconds": Int(Date().timeIntervalSince(started) * 1000), "results": found.count,
                "missing": Array(missing), "paths": Array(found).sorted()]
            if let followup = item.followup, !controller.results.isEmpty {
                let followupPlan = await planner.plan(from: followup)
                if followupPlan.count == 1, case .fileResult(let selection) = followupPlan[0],
                   selection.operation == .open, controller.results.indices.contains(selection.index - 1) {
                    let expected = controller.results[selection.index - 1].url.path
                    let openedBefore = opened.count
                    let response = await executor.execute(plan: followupPlan, onStepStart: { _ in }, onStepComplete: { _ in })
                    XCTAssertTrue(response.first?.success == true)
                    XCTAssertEqual(opened.count, openedBefore + 1)
                    XCTAssertEqual(opened.last, expected)
                    XCTAssertFalse(controller.hasContext)
                    row["followup_passed"] = response.first?.success == true && opened.last == expected && !controller.hasContext
                } else { XCTFail("Invalid audit follow-up at case \(index)") }
            }
            report.append(row)
        }
        let destination = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("results.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        print("Local file-search audit: \(report.count) cases; report: \(destination.path)")
    }
}

private struct AuditNoLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("File search unexpectedly reached the LLM"); return "" }
}
private struct AuditNoIntent: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("File search unexpectedly reached the model"); return nil }
}
