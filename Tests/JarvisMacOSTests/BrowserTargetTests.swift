import XCTest
@testable import JarvisMacOS

final class BrowserTargetTests: XCTestCase {

    private func fastPath(_ text: String) -> [PlannedAction]? {
        if case .execute(let actions) = FastPathRouter.route(text) {
            return actions
        }
        return nil
    }

    func testBrowserSiteUsesTargetedBrowser() {
        XCTAssertEqual(
            fastPath("open chatgpt in brave"),
            [.openURLInBrowser(url: "https://chatgpt.com", browser: "Brave Browser")]
        )
        XCTAssertEqual(
            fastPath("open chat gpt in google chrome"),
            [.openURLInBrowser(url: "https://chatgpt.com", browser: "Google Chrome")]
        )
    }

    func testSiteAliasesAndTypos() {
        XCTAssertEqual(
            fastPath("open versel in brave browser"),
            [.openURLInBrowser(url: "https://vercel.com", browser: "Brave Browser")]
        )
        XCTAssertEqual(
            fastPath("open cloud code in chrome"),
            [.openURLInBrowser(url: "https://code.claude.com", browser: "Google Chrome")]
        )
        XCTAssertEqual(
            fastPath("open command code in arc"),
            [.openURLInBrowser(url: "https://commandcode.ai", browser: "Arc")]
        )
    }

    func testSiteOnlyOpensDefaultBrowser() {
        XCTAssertEqual(fastPath("open chatgpt"), [.openURL("https://chatgpt.com")])
        XCTAssertEqual(fastPath("open vercel"), [.openURL("https://vercel.com")])
        XCTAssertEqual(fastPath("open github"), [.openURL("https://github.com")])
    }

    func testLocalReactDefaultsToBraveAnd5173() {
        XCTAssertEqual(
            fastPath("open react app"),
            [.openURLInBrowser(url: "http://localhost:5173", browser: "Brave Browser")]
        )
    }

    func testLocalPortAndExplicitBrowser() {
        XCTAssertEqual(
            fastPath("open react app on port 5174 in chrome"),
            [.openURLInBrowser(url: "http://localhost:5174", browser: "Google Chrome")]
        )
        XCTAssertEqual(
            fastPath("open localhost in port 3000"),
            [.openURLInBrowser(url: "http://localhost:3000", browser: "Brave Browser")]
        )
        XCTAssertEqual(
            fastPath("open localhost:8080 in firefox"),
            [.openURLInBrowser(url: "http://localhost:8080", browser: "Firefox")]
        )
    }

    func testIntentMapperSupportsBrowserArgument() {
        let mapped = IntentActionMapper.map([
            ["name": "url.open_in",
             "args": ["url": "https://chatgpt.com", "browser": "Brave Browser"]]
        ])
        XCTAssertEqual(mapped, [.openURLInBrowser(url: "https://chatgpt.com", browser: "Brave Browser")])
    }

    func testResolverRejectsUnknownWordsForBrowserTarget() {
        XCTAssertNil(OpenTargetResolver.parseOpenInBrowser("open the window in brave"))
    }
}
