import XCTest
@testable import JarvisMacOS

final class SharedPolicyTests: XCTestCase {
    private struct Fixture: Decodable {
        let text: String
        let actions: [String]?
        let priority: String
        let safety: String
    }

    func testSharedSwiftAndRustPolicyFixtures() throws {
        TestSupport.pinRustPipelineOff()
        defer { TestSupport.unpinRustPipeline() }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "command_policy", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        let planner = ActionPlanner()
        func verdict(_ value: SafetyVerdict) -> String {
            switch value {
            case .allowed: return "allowed"
            case .blocked: return "blocked"
            case .installPreview: return "install"
            }
        }
        for fixture in fixtures {
            XCTAssertEqual(verdict(SafetyGuard.validate(rawCommand: fixture.text)), fixture.safety, fixture.text)
            XCTAssertEqual(verdict(RustPipeline.map(coreCheckSafety(raw: fixture.text))), fixture.safety, fixture.text)
            XCTAssertEqual(CommandPriority.classify(fixture.text) == .high ? "high" : "normal", fixture.priority, fixture.text)
            if let expected = fixture.actions {
                let swift: [PlannedAction]
                switch FastPathRouter.route(fixture.text) {
                case .execute(let actions): swift = actions
                case .needsModel: swift = planner.rulePlanForTesting(fixture.text) ?? []
                }
                let rust = RustPipeline.map(corePlanAfterModel(cleaned: fixture.text).actions)
                XCTAssertEqual(swift.map(\.description), expected, "Swift: \(fixture.text)")
                XCTAssertEqual(rust.map(\.description), expected, "Rust: \(fixture.text)")
            }
        }
    }
}
