import AppKit
import Observation
import SwiftUI

enum AccentTheme: String, CaseIterable, Identifiable {
    case cobalt, violet, mint, coral, amber, silver
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .cobalt: return 0x8CA5FF
        case .violet: return 0xB7A1FF
        case .mint: return 0x7CD8BD
        case .coral: return 0xF399A5
        case .amber: return 0xEAC18B
        case .silver: return 0xD3D9E6
        }
    }
    var foregroundHex: UInt32 {
        Self.contrast(0x080C18, hex) >= Self.contrast(0xFFFFFF, hex) ? 0x080C18 : 0xFFFFFF
    }
    static func contrast(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((hex >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(lhs), b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    var color: Color { Color(hex: hex) }
    var nsColor: NSColor { NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1) }
}

enum AssistantOrbStyle: String, CaseIterable, Identifiable {
    case liquid, halo, aurora, lattice, prism
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .liquid: return "Polished, fluid chrome"
        case .halo: return "A dark core with orbital rings"
        case .aurora: return "Soft layers of moving light"
        case .lattice: return "A precise particle structure"
        case .prism: return "Faceted, reflective geometry"
        }
    }
}

/// Appearance is independent of command/model settings and never resets them.
/// Observation tracks token reads inside SwiftUI bodies, including floating HUDs.
@Observable final class AppAppearance {
    static let shared = AppAppearance()
    private let defaults: UserDefaults
    var accent: AccentTheme { didSet { defaults.set(accent.rawValue, forKey: "jarvis.appearance.accent") } }
    var textSize: InterfaceTextSize { didSet { defaults.set(textSize.rawValue, forKey: "jarvis.appearance.textSize") } }
    var orbStyle: AssistantOrbStyle { didSet { defaults.set(orbStyle.rawValue, forKey: "jarvis.appearance.orb") } }
    private var storedGlassOpacity: Double
    private var storedBorderContrast: Double
    var glassOpacity: Double {
        get { storedGlassOpacity }
        set {
            storedGlassOpacity = Self.clamped(newValue, to: 0.35...1, fallback: 0.74)
            defaults.set(storedGlassOpacity, forKey: "jarvis.appearance.glass")
        }
    }
    var borderContrast: Double {
        get { storedBorderContrast }
        set {
            storedBorderContrast = Self.clamped(newValue, to: 0.75...1.5, fallback: 1)
            defaults.set(storedBorderContrast, forKey: "jarvis.appearance.contrast")
        }
    }
    var animateOrb: Bool { didSet { defaults.set(animateOrb, forKey: "jarvis.appearance.motion") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = AccentTheme(rawValue: defaults.string(forKey: "jarvis.appearance.accent") ?? "") ?? .cobalt
        textSize = InterfaceTextSize(rawValue: defaults.string(forKey: "jarvis.appearance.textSize") ?? "") ?? .standard
        orbStyle = AssistantOrbStyle(rawValue: defaults.string(forKey: "jarvis.appearance.orb") ?? "") ?? .liquid
        storedGlassOpacity = Self.clamped((defaults.object(forKey: "jarvis.appearance.glass") as? NSNumber)?.doubleValue ?? 0.74, to: 0.35...1, fallback: 0.74)
        storedBorderContrast = Self.clamped((defaults.object(forKey: "jarvis.appearance.contrast") as? NSNumber)?.doubleValue ?? 1, to: 0.75...1.5, fallback: 1)
        animateOrb = (defaults.object(forKey: "jarvis.appearance.motion") as? NSNumber)?.boolValue ?? true
    }
    func reset() {
        accent = .cobalt; orbStyle = .liquid; textSize = .standard; glassOpacity = 0.74; borderContrast = 1; animateOrb = true
    }
    private static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

private struct NativeGlassMaterial: NSViewRepresentable {
    var behindWindow: Bool
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .hudWindow
        view.blendingMode = behindWindow ? .behindWindow : .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
    }
}

struct GlassPanelBackground: View {
    var behindWindow = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let opacity = reduceTransparency ? 1 : AppAppearance.shared.glassOpacity
        ZStack {
            if !reduceTransparency { NativeGlassMaterial(behindWindow: behindWindow) }
            Color(hex: 0x10131B).opacity(opacity)
            LinearGradient(colors: [.white.opacity(0.07), .clear, NoirPalette.accent.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }
}

private struct ObsidianWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1240
}
extension EnvironmentValues {
    var obsidianWindowWidth: CGFloat {
        get { self[ObsidianWindowWidthKey.self] }
        set { self[ObsidianWindowWidthKey.self] = newValue }
    }
}
