import SwiftUI

/// Single source of truth for the app's visual language.
/// Calm indigo-tinted neutrals, one accent, three semantic state colors.
enum JarvisColor {
    // Surfaces
    static let canvas        = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let surface       = Color.white.opacity(0.04)
    static let surfaceRaised = Color.white.opacity(0.07)
    static let hairline      = Color.white.opacity(0.08)

    // Text
    static let textPrimary   = Color.white.opacity(0.88)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary  = Color.white.opacity(0.35)

    // Accent + semantics
    static let accent    = Color(red: 0.53, green: 0.55, blue: 0.99)
    static let ok        = Color(red: 0.35, green: 0.85, blue: 0.65)
    static let attention = Color(red: 0.95, green: 0.75, blue: 0.35)
    static let danger    = Color(red: 0.95, green: 0.40, blue: 0.50)
}

enum JarvisType {
    static let title   = Font.system(size: 13, weight: .semibold)
    static let body    = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    static let micro   = Font.system(size: 10, weight: .regular)
    static let data    = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let dataSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
}

enum JarvisSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 32
}

enum JarvisRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

/// Quiet, tint-per-intent button. `color` carries the semantic intent
/// (accent / ok / danger / neutral); the body stays a calm neutral chip.
struct JarvisButtonStyle: ButtonStyle {
    let color: Color
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? JarvisType.caption : JarvisType.body)
            .foregroundStyle(configuration.isPressed ? color.opacity(0.6) : color)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shared quiet input field background.
struct QuietFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(JarvisType.body)
            .textFieldStyle(.plain)
            .foregroundStyle(JarvisColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .strokeBorder(JarvisColor.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func quietField() -> some View { modifier(QuietFieldStyle()) }
}

/// Barely-there dot grid for the main canvas — texture without decoration.
/// 1pt dots on a 28pt grid at ~5% white, hit-testing off.
struct SubtleGridView: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let dot = Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1))
                    context.fill(dot, with: .color(.white.opacity(0.05)))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
