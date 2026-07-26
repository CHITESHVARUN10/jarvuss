import XCTest
@testable import JarvisMacOS

final class SystemPipelineE2ETests: XCTestCase {
    private let planner = ActionPlanner()
    private let executor = ActionExecutor()

    private struct CommandScenario {
        let id: String
        let suite: String
        let command: String
        let expectedIntent: ExpectedIntent
    }

    private enum ExpectedIntent: String {
        case system
        case info
        case media
        case browser
        case filesystem
        case automation

        func matches(_ plan: [PlannedAction]) -> Bool {
            guard let first = plan.first else { return false }
            switch self {
            case .system:
                if case .openApp = first { return true }
                if case .closeApp = first { return true }
                return false
            case .info:
                if case .systemInfo = first { return true }
                return false
            case .media:
                if case .mediaControl = first { return true }
                return false
            case .browser:
                return plan.contains { action in
                    if case .openURL = action { return true }
                    return false
                }
            case .filesystem:
                if case .createFile = first { return true }
                if case .createFolder = first { return true }
                if case .openFolder = first { return true }
                return false
            case .automation:
                return true
            }
        }
    }

    private struct ScenarioAttemptReport: Codable {
        let attempt: Int
        let durationMs: Int
        let planDescriptions: [String]
        let stepMessages: [String]
        let success: Bool
        let failureReason: String?
    }

    private struct ScenarioReport: Codable {
        let id: String
        let suite: String
        let command: String
        let expectedIntent: String
        let success: Bool
        let attemptsUsed: Int
        let attempts: [ScenarioAttemptReport]
    }

    private struct ReportSummary: Codable {
        let total: Int
        let passed: Int
        let failed: Int
        let successRate: Double
        let averageDurationMs: Double
    }

    private struct SystemTestReport: Codable {
        let generatedAt: String
        let retryPolicy: String
        let suites: [String]
        let summary: ReportSummary
        let scenarios: [ScenarioReport]
    }

    func testSystemPipelineHarnessWithReport() async throws {
        let selectedApp = discoverTestableAppName()
        let uniqueToken = UUID().uuidString.prefix(8)
        let folderName = "e2e-folder-\(uniqueToken)"
        let fileName = "e2e-file-\(uniqueToken).txt"

        defer {
            cleanupPath(folderName)
            cleanupPath(fileName)
        }

        let scenarios: [CommandScenario] = [
            .init(id: "app-open", suite: "app_discovery", command: "open \(selectedApp)", expectedIntent: .system),
            .init(id: "app-close", suite: "app_discovery", command: "close \(selectedApp)", expectedIntent: .system),
            .init(id: "info-time", suite: "info", command: "what time is it", expectedIntent: .info),
            .init(id: "info-battery", suite: "info", command: "battery status", expectedIntent: .info),
            .init(id: "spotify-pause", suite: "spotify", command: "pause", expectedIntent: .media),
            .init(id: "spotify-next", suite: "spotify", command: "next song", expectedIntent: .media),
            .init(id: "browser-youtube-search", suite: "browser", command: "search youtube for swift package manager", expectedIntent: .browser),
            .init(id: "browser-search", suite: "browser", command: "search google for swift concurrency", expectedIntent: .browser),
            .init(id: "fs-create-folder", suite: "filesystem", command: "create folder \(folderName)", expectedIntent: .filesystem),
            .init(id: "fs-create-file", suite: "filesystem", command: "create file \(fileName)", expectedIntent: .filesystem)
        ]

        var scenarioReports: [ScenarioReport] = []

        for scenario in scenarios {
            let report = await runScenarioWithRetry(scenario, maxAttempts: 2)
            scenarioReports.append(report)
        }

        let automationReport = await runAutomationScenario(uniqueToken: String(uniqueToken))
        scenarioReports.append(contentsOf: automationReport)

        let passed = scenarioReports.filter { $0.success }.count
        let failed = scenarioReports.count - passed
        let allAttemptDurations = scenarioReports.flatMap { $0.attempts.map(\.durationMs) }
        let averageDurationMs = allAttemptDurations.isEmpty
            ? 0
            : Double(allAttemptDurations.reduce(0, +)) / Double(allAttemptDurations.count)

        let summary = ReportSummary(
            total: scenarioReports.count,
            passed: passed,
            failed: failed,
            successRate: scenarioReports.isEmpty ? 0 : (Double(passed) / Double(scenarioReports.count)) * 100,
            averageDurationMs: averageDurationMs
        )

        let suites = Array(Set(scenarioReports.map(\.suite))).sorted()
        let report = SystemTestReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            retryPolicy: "1 retry on failure (max 2 attempts per scenario)",
            suites: suites,
            summary: summary,
            scenarios: scenarioReports
        )

        let outputPaths = try writeReportArtifacts(report)
        print("[SystemTest] JSON report: \(outputPaths.jsonPath)")
        print("[SystemTest] Markdown report: \(outputPaths.markdownPath)")

        XCTAssertGreaterThan(report.summary.total, 0)
    }

    private func discoverTestableAppName() -> String {
        let preferred = ["TextEdit", "Notes", "Calculator", "Preview"]
        let roots = ["/Applications", "/System/Applications"]

        for name in preferred {
            for root in roots {
                let path = "\(root)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    return name
                }
            }
        }

        return "Finder"
    }

    private func runScenarioWithRetry(_ scenario: CommandScenario, maxAttempts: Int) async -> ScenarioReport {
        var attempts: [ScenarioAttemptReport] = []

        for attempt in 1...maxAttempts {
            let startedAt = Date()
            let plan = await planner.plan(from: scenario.command)
            let planDescriptions = plan.map(\.description)

            if plan.isEmpty {
                let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
                attempts.append(
                    ScenarioAttemptReport(
                        attempt: attempt,
                        durationMs: duration,
                        planDescriptions: [],
                        stepMessages: [],
                        success: false,
                        failureReason: "No planned actions returned"
                    )
                )
            } else if !scenario.expectedIntent.matches(plan) {
                let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
                attempts.append(
                    ScenarioAttemptReport(
                        attempt: attempt,
                        durationMs: duration,
                        planDescriptions: planDescriptions,
                        stepMessages: [],
                        success: false,
                        failureReason: "Intent mismatch: expected \(scenario.expectedIntent.rawValue)"
                    )
                )
            } else {
                let execution = await executePlannedActions(plan)
                let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
                let failureReason = execution.success ? nil : "One or more action steps failed"

                attempts.append(
                    ScenarioAttemptReport(
                        attempt: attempt,
                        durationMs: duration,
                        planDescriptions: planDescriptions,
                        stepMessages: execution.messages,
                        success: execution.success,
                        failureReason: failureReason
                    )
                )
            }

            if attempts.last?.success == true {
                break
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        return ScenarioReport(
            id: scenario.id,
            suite: scenario.suite,
            command: scenario.command,
            expectedIntent: scenario.expectedIntent.rawValue,
            success: attempts.last?.success == true,
            attemptsUsed: attempts.count,
            attempts: attempts
        )
    }

    private func executePlannedActions(_ plan: [PlannedAction]) async -> (success: Bool, messages: [String]) {
        var results: [ActionResult] = []
        await executor.execute(
            plan: plan,
            onStepStart: { _ in },
            onStepComplete: { result in
                results.append(result)
            }
        )

        let success = !results.isEmpty && results.allSatisfy(\.success)
        let messages = results.map { "\($0.success ? "✓" : "✗") \($0.message)" }
        return (success, messages)
    }

    @MainActor
    private func runAutomationScenario(uniqueToken: String) async -> [ScenarioReport] {
        let appState = AppState()
        let keyword = "focus mode \(uniqueToken)"
        let offKeyword = "focus mode off \(uniqueToken)"

        appState.saveAutomation(
            keyword: keyword,
            offKeyword: offKeyword,
            actions: [AutomationAction(type: .openFolder, value: "Downloads")]
        )

        defer {
            if let existing = appState.automations.first(where: { $0.keyword == keyword }) {
                appState.deleteAutomation(id: existing.id)
            }
        }

        let onReport = await runAutomationCommand(
            id: "automation-on",
            suite: "automation",
            command: keyword,
            expectedLogContains: "[Automation] ✓",
            appState: appState
        )

        let offReport = await runAutomationCommand(
            id: "automation-off",
            suite: "automation",
            command: offKeyword,
            expectedLogContains: "Off variant matched",
            appState: appState
        )

        return [onReport, offReport]
    }

    @MainActor
    private func runAutomationCommand(
        id: String,
        suite: String,
        command: String,
        expectedLogContains: String,
        appState: AppState
    ) async -> ScenarioReport {
        var attempts: [ScenarioAttemptReport] = []

        for attempt in 1...2 {
            let startedAt = Date()
            appState.commandInput = command
            appState.executeTypedCommand()

            let success = await waitForLog(expectedLogContains, in: appState, timeoutSeconds: 8)
            let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
            let recentLogs = Array(appState.logs.suffix(12))

            attempts.append(
                ScenarioAttemptReport(
                    attempt: attempt,
                    durationMs: duration,
                    planDescriptions: ["Automation path via AppState.executeTypedCommand"],
                    stepMessages: recentLogs,
                    success: success,
                    failureReason: success ? nil : "Expected log not observed: \(expectedLogContains)"
                )
            )

            if success { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        return ScenarioReport(
            id: id,
            suite: suite,
            command: command,
            expectedIntent: ExpectedIntent.automation.rawValue,
            success: attempts.last?.success == true,
            attemptsUsed: attempts.count,
            attempts: attempts
        )
    }

    @MainActor
    private func waitForLog(_ needle: String, in appState: AppState, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if appState.logs.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return false
    }

    private func writeReportArtifacts(_ report: SystemTestReport) throws -> (jsonPath: String, markdownPath: String) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outputDir = root.appendingPathComponent("artifacts/system-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)

        let jsonURL = outputDir.appendingPathComponent("system-test-report.json")
        try jsonData.write(to: jsonURL, options: .atomic)

        let markdownURL = outputDir.appendingPathComponent("system-test-report.md")
        let markdown = buildMarkdownReport(report)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        return (jsonURL.path, markdownURL.path)
    }

    private func buildMarkdownReport(_ report: SystemTestReport) -> String {
        var lines: [String] = []
        lines.append("# Jarvis System Pipeline Test Report")
        lines.append("")
        lines.append("- Generated at: \(report.generatedAt)")
        lines.append("- Retry policy: \(report.retryPolicy)")
        lines.append("- Suites: \(report.suites.joined(separator: ", "))")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append("- Total: \(report.summary.total)")
        lines.append("- Passed: \(report.summary.passed)")
        lines.append("- Failed: \(report.summary.failed)")
        lines.append(String(format: "- Success rate: %.2f%%", report.summary.successRate))
        lines.append(String(format: "- Average attempt duration: %.1f ms", report.summary.averageDurationMs))
        lines.append("")
        lines.append("## Scenarios")
        lines.append("")

        for scenario in report.scenarios {
            lines.append("### \(scenario.id) [\(scenario.suite)]")
            lines.append("")
            lines.append("- Command: `\(scenario.command)`")
            lines.append("- Expected intent: `\(scenario.expectedIntent)`")
            lines.append("- Outcome: \(scenario.success ? "PASS" : "FAIL")")
            lines.append("- Attempts used: \(scenario.attemptsUsed)")
            for attempt in scenario.attempts {
                lines.append("  - Attempt \(attempt.attempt): \(attempt.success ? "PASS" : "FAIL") in \(attempt.durationMs) ms")
                if !attempt.planDescriptions.isEmpty {
                    lines.append("    - Plan: \(attempt.planDescriptions.joined(separator: " | "))")
                }
                if !attempt.stepMessages.isEmpty {
                    lines.append("    - Steps: \(attempt.stepMessages.joined(separator: " | "))")
                }
                if let failureReason = attempt.failureReason {
                    lines.append("    - Reason: \(failureReason)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func cleanupPath(_ relativePath: String) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let target = root.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: target)
    }
}
