import SwiftUI

enum InterfaceTextSize: String, CaseIterable, Identifiable {
    case extraSmall, small, standard = "default", large, extraLarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .extraSmall: return "Extra Small"
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
    var multiplier: CGFloat {
        switch self {
        case .extraSmall: return 0.85
        case .small: return 0.93
        case .standard: return 1
        case .large: return 1.12
        case .extraLarge: return 1.26
        }
    }
    var minimumPointSize: CGFloat {
        switch self {
        case .extraSmall: return 8
        case .small: return 9
        case .standard: return 10
        case .large: return 11
        case .extraLarge: return 12
        }
    }
}

enum ObsidianTypography {
    /// Adapt to available logical space, not physical monitor inches. Keep
    /// compact windows usable and bound growth on very wide displays.
    static func pointSize(_ base: CGFloat, width: CGFloat, preference: InterfaceTextSize) -> CGFloat {
        let progress = min(1, max(0, (width - 1100) / 820))
        return max(preference.minimumPointSize, base * preference.multiplier * (1 + 0.04 * progress))
    }
}

private struct ObsidianFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.obsidianWindowWidth) private var width
    func body(content: Content) -> some View {
        content.font(.system(size: ObsidianTypography.pointSize(size, width: width, preference: AppAppearance.shared.textSize), weight: weight, design: design))
    }
}
extension View {
    func obsidianFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ObsidianFont(size: size, weight: weight, design: design))
    }
}
