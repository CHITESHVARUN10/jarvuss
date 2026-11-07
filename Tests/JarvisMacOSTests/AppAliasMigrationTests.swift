import XCTest
@testable import JarvisMacOS

final class AppAliasMigrationTests: XCTestCase {
    func testEveryExistingAliasWorksWithoutEnablingTheRustPipeline() {
        TestSupport.pinRustPipelineOff()
        defer { TestSupport.unpinRustPipeline() }
        let aliases: [(String, String)] = [
            ("chrome", "Google Chrome"),
            ("google chrome", "Google Chrome"),
            ("googlechrom", "Google Chrome"),
            ("spotify", "Spotify"),
            ("whatsapp", "WhatsApp"),
            ("safari", "Safari"),
            ("apple safari", "Safari"),
            ("photos", "Photos"),
            ("apple photos", "Photos"),
            ("photo", "Photos"),
            ("fotos", "Photos"),
            ("brave", "Brave Browser"),
            ("brave browser", "Brave Browser"),
            ("browser", "Brave Browser"),
            ("web browser", "Brave Browser"),
            ("firefox", "Firefox"),
            ("mozilla firefox", "Firefox"),
            ("fox", "Firefox"),
            ("edge", "Microsoft Edge"),
            ("microsoft edge", "Microsoft Edge"),
            ("ms edge", "Microsoft Edge"),
            ("arc", "Arc"),
            ("arc browser", "Arc"),
            ("mail", "Mail"),
            ("apple mail", "Mail"),
            ("email", "Mail"),
            ("messages", "Messages"),
            ("imessage", "Messages"),
            ("message", "Messages"),
            ("calendar", "Calendar"),
            ("apple calendar", "Calendar"),
            ("notes", "Notes"),
            ("apple notes", "Notes"),
            ("note", "Notes"),
            ("music", "Music"),
            ("apple music", "Music"),
            ("maps", "Maps"),
            ("apple maps", "Maps"),
            ("map", "Maps"),
            ("app store", "App Store"),
            ("appstore", "App Store"),
            ("city", "City"),
            ("github", "GitHub Desktop"),
            ("github desktop", "GitHub Desktop"),
            ("git hub", "GitHub Desktop"),
            ("git hub desktop", "GitHub Desktop"),
            ("githab desktop", "GitHub Desktop"),
            ("get her desktop", "GitHub Desktop"),
            ("getha desktop", "GitHub Desktop"),
            ("get desktop", "GitHub Desktop"),
            ("gate desktop", "GitHub Desktop"),
            ("get up desktop", "GitHub Desktop"),
            ("gita desktop", "GitHub Desktop"),
            ("system settings", "System Settings"),
            ("settings", "System Settings"),
            ("system setting", "System Settings"),
            ("vscode", "Visual Studio Code"),
            ("vs code", "Visual Studio Code"),
            ("visual studio code", "Visual Studio Code"),
            ("visual code", "Visual Studio Code"),
            ("finder", "Finder"),
            ("terminal", "Terminal")
        ]
        for (alias, expected) in aliases {
            XCTAssertEqual(AppAliasResolver.knownAppName(alias), expected, alias)
            XCTAssertEqual(AppAliasResolver.resolve(alias), expected, alias)
            XCTAssertEqual(AppAliasResolver.resolveSpoken("  " + alias.uppercased() + "!  "), expected, alias)
        }
    }

    func testExactLookupDoesNotBecomeFuzzyAndUnknownInputIsPreserved() {
        XCTAssertNil(AppAliasResolver.knownAppName("spotfy"))
        XCTAssertEqual(AppAliasResolver.resolve("spotfy"), "Spotify")
        XCTAssertEqual(AppAliasResolver.resolve("  "), "  ")
        XCTAssertEqual(AppAliasResolver.resolveSpoken("  "), "")
        XCTAssertEqual(AppAliasResolver.resolve(" UnknownApplicationXYZ! "), " UnknownApplicationXYZ! ")
        XCTAssertEqual(AppAliasResolver.resolveSpoken(" UnknownApplicationXYZ! "), "UnknownApplicationXYZ")
        XCTAssertEqual(AppAliasResolver.knownAppName("c.h.r.o.m.e"), "Google Chrome")
    }
}
