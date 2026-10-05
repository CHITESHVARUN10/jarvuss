import AppKit
import CoreText
import SwiftUI

/// Card typography: the dictation card's three families with graceful
/// fallbacks. The fonts ship inside the app bundle
/// (`Contents/Resources/Fonts`, registered via `ATSApplicationFontsPath`);
/// every style stays legible when a file is missing (dev builds, trimmed
/// bundles) by falling back to a system face.
enum JarvisFonts {

    /// Registers `Resources/Fonts` at process scope. The packaged app gets
    /// this for free from `ATSApplicationFontsPath`; this covers `swift run`
    /// and any launch where the plist path is not consulted.
    static func registerBundledFonts() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let fontsURL = resourceURL.appendingPathComponent("Fonts", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsURL, includingPropertiesForKeys: nil) else { return }
        let urls = files.filter { $0.pathExtension.lowercased() == "ttf" }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
    }

    private static func resolves(_ name: String) -> Bool {
        NSFont(name: name, size: 12) != nil
    }

    /// Instrument Serif — the hero transcript face.
    static func serif(_ size: CGFloat) -> Font {
        resolves("Instrument Serif")
            ? .custom("Instrument Serif", size: size)
            : .system(size: size, weight: .regular, design: .serif)
    }

    /// Instrument Sans — buttons and labels.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        resolves("Instrument Sans")
            ? .custom("Instrument Sans", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    /// JetBrains Mono — the tag and meta lines.
    static func mono(_ size: CGFloat) -> Font {
        resolves("JetBrains Mono")
            ? .custom("JetBrains Mono", size: size)
            : .system(size: size, weight: .regular, design: .monospaced)
    }
}
