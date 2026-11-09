import XCTest
@testable import JarvisMacOS

final class AppAppearanceTests: XCTestCase {
    private func isolated(_ run: (UserDefaults) -> Void) {
        let name = "jarvis.appearance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        run(defaults)
    }
    func testAppearancePersistsAcrossInstances() {
        isolated { defaults in
            let settings = AppAppearance(defaults: defaults)
            settings.accent = .mint; settings.orbStyle = .halo; settings.textSize = .large
            settings.glassOpacity = 0.45; settings.borderContrast = 1.35; settings.animateOrb = false
            let restored = AppAppearance(defaults: defaults)
            XCTAssertEqual(restored.accent, .mint)
            XCTAssertEqual(restored.orbStyle, .halo)
            XCTAssertEqual(restored.textSize, .large)
            XCTAssertEqual(restored.glassOpacity, 0.45)
            XCTAssertEqual(restored.borderContrast, 1.35)
            XCTAssertFalse(restored.animateOrb)
        }
    }
    func testInvalidStoredPreferencesRecoverSafely() {
        isolated { defaults in
            defaults.set("unknown", forKey: "jarvis.appearance.accent")
            defaults.set("unknown", forKey: "jarvis.appearance.orb")
            defaults.set("unknown", forKey: "jarvis.appearance.textSize")
            defaults.set(-4, forKey: "jarvis.appearance.glass")
            defaults.set(900, forKey: "jarvis.appearance.contrast")
            let settings = AppAppearance(defaults: defaults)
            XCTAssertEqual(settings.accent, .cobalt)
            XCTAssertEqual(settings.orbStyle, .liquid)
            XCTAssertEqual(settings.textSize, .standard)
            XCTAssertEqual(settings.glassOpacity, 0.35)
            XCTAssertEqual(settings.borderContrast, 1.5)
            settings.glassOpacity = .nan
            settings.borderContrast = .infinity
            XCTAssertEqual(settings.glassOpacity, 0.74)
            XCTAssertEqual(settings.borderContrast, 1)
        }
    }
    func testResetPreservesUnrelatedCommandAndModelSettings() {
        isolated { defaults in
            defaults.set("existing-release", forKey: "jarvis.intent.release")
            defaults.set(true, forKey: "jarvis.actionPillRequiresVerify")
            let settings = AppAppearance(defaults: defaults)
            settings.accent = .coral; settings.orbStyle = .prism; settings.glassOpacity = 1
            settings.reset()
            XCTAssertEqual(settings.accent, .cobalt)
            XCTAssertEqual(settings.orbStyle, .liquid)
            XCTAssertEqual(settings.textSize, .standard)
            XCTAssertEqual(settings.glassOpacity, 0.74)
            XCTAssertEqual(defaults.string(forKey: "jarvis.intent.release"), "existing-release")
            XCTAssertTrue(defaults.bool(forKey: "jarvis.actionPillRequiresVerify"))
        }
    }
    func testAccentForegroundRemainsReadableForEveryTheme() {
        for theme in AccentTheme.allCases {
            XCTAssertGreaterThan(AccentTheme.contrast(theme.foregroundHex, theme.hex), 7, theme.title)
        }
    }
    func testTypographyScalesForWideWindowsWithoutUnboundedGrowth() {
        let compact = ObsidianTypography.pointSize(13, width: 900, preference: .standard)
        let wide = ObsidianTypography.pointSize(13, width: 1920, preference: .standard)
        XCTAssertGreaterThan(wide, compact)
        XCTAssertLessThanOrEqual(wide, 14)
        XCTAssertEqual(wide, ObsidianTypography.pointSize(13, width: 5000, preference: .standard))
        XCTAssertGreaterThan(ObsidianTypography.pointSize(13, width: 1920, preference: .large), wide)
        XCTAssertGreaterThanOrEqual(ObsidianTypography.pointSize(8, width: 900, preference: .standard), 10)
    }

    func testAllTextSizePresetsAreOrderedAndPersist() {
        let sizes = InterfaceTextSize.allCases.map { ObsidianTypography.pointSize(14, width: 1920, preference: $0) }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, 5)
        isolated { defaults in
            for size in InterfaceTextSize.allCases {
                AppAppearance(defaults: defaults).textSize = size
                XCTAssertEqual(AppAppearance(defaults: defaults).textSize, size)
            }
        }
    }

}
