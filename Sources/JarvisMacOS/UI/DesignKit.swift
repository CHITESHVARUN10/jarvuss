import SwiftUI

/// Mock-faithful design tokens + reusable panel components.
///
/// Exact values come from `htmls/index.html`:
///   --bg-base #0b0b11 · --bg-raised #101017 · --bg-overlay #14141d
///   --line white .07 · --line-strong white .12 · --line-focus accent .55
///   --ink .94 / .62 / .40 / .24
///   --accent #7e85ff · --ok #4fd6a4 · --warn #f0b95c · --danger #f26680
///   radii xs 6 · sm 9 · md 13 · lg 18 · xl 24
enum JColor {
    // Backgrounds
    static let base    = Color(red: 0.043, green: 0.043, blue: 0.067)
    static let raised  = Color(red: 0.063, green: 0.063, blue: 0.090)
    static let overlay = Color(red: 0.078, green: 0.078, blue: 0.114)
    static let inset   = Color.white.opacity(0.028)

    // Lines
    static let line       = Color.white.opacity(0.07)
    static let lineStrong = Color.white.opacity(0.12)

    // Text
    static let ink   = Color.white.opacity(0.94)
    static let ink2  = Color.white.opacity(0.62)
    static let ink3  = Color.white.opacity(0.40)
    static let ink4  = Color.white.opacity(0.24)

    // Accent + semantics
    static let accent = Color(red: 0.494, green: 0.522, blue: 1.0)
    static let ok     = Color(red: 0.310, green: 0.839, blue: 0.643)
    static let warn   = Color(red: 0.941, green: 0.725, blue: 0.361)
    static let danger = Color(red: 0.949, green: 0.400, blue: 0.502)

    static let accentSoft = Color(red: 0.494, green: 0.522, blue: 1.0).opacity(0.14)
    static let okSoft     = ok.opacity(0.13)
    static let warnSoft   = warn.opacity(0.13)
    static let dangerSoft = danger.opacity(0.13)
}

enum JType {
    static let panelTitle = Font.system(size: 17, weight: .semibold)
    static let panelSub   = Font.system(size: 12, weight: .regular)
    static let label      = Font.system(size: 10.5, weight: .semibold)
    static let cardTitle  = Font.system(size: 13, weight: .medium)
    static let rowTitle   = Font.system(size: 12.5, weight: .regular)
    static let rowSub     = Font.system(size: 11, weight: .regular)
    static let kv         = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let display    = Font.system(size: 30, weight: .regular)
}

enum JRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 9
    static let md: CGFloat = 13
    static let lg: CGFloat = 18
    static let xl: CGFloat = 24
}

// MARK: - Panel head

/// Mock `.panel-head`: title + sub. The panel itself owns the sticky fade.
///
/// The optional trailing view is wrapped in `AnyView` at the call site.
/// NOTE: pass `trailing:` as an already-built `AnyView` on its own line —
/// never inline a multi-line trailing closure here, Swift mis-parses it.
struct JPanelHead<Trailing: View>: View {
    let title: String
    let sub: String
    var trailing: Trailing?

    init(title: String, sub: String, trailing: Trailing?) {
        self.title = title
        self.sub = sub
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(JType.panelTitle)
                    .foregroundStyle(JColor.ink)
                Text(sub)
                    .font(JType.panelSub)
                    .foregroundStyle(JColor.ink3)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
        // Mock `.panel-head`: sticky, with a gradient fade into the pane body.
        .background(
            LinearGradient(
                stops: [
                    .init(color: JColor.base, location: 0),
                    .init(color: JColor.base, location: 0.72),
                    .init(color: JColor.base.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Section label

/// Mock `.lbl`: 10.5/600 uppercase, +9% tracking, ink-4.
struct JLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(JType.label)
            .tracking(1)
            .foregroundStyle(JColor.ink4)
    }
}

// MARK: - Card

/// Mock `.card`: raised bg, 1px line, radius 13, padding 15. `.card.flush` has no padding.
struct JCard<Content: View>: View {
    var flush: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(flush ? 0 : 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .fill(JColor.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                .strokeBorder(JColor.line, lineWidth: 1)
        )
    }
}

extension JPanelHead where Trailing == EmptyView {
    init(title: String, sub: String) {
        self.init(title: title, sub: sub, trailing: nil)
    }
}

/// Mock `.card-h`: icon + title row inside a card.
struct JCardHead<Accessory: View>: View {
    let icon: String
    let title: String
    var accessory: Accessory?

    init(icon: String, title: String, accessory: Accessory?) {
        self.icon = icon
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(JColor.ink3)
            Text(title)
                .font(JType.cardTitle)
                .foregroundStyle(JColor.ink)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.bottom, 13)
    }
}

// MARK: - Row

/// Mock `.row`: 11pt vertical padding, top hairline, title + optional sub,
/// optional trailing view.
struct JRow<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    var first: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(JType.rowTitle)
                    .foregroundStyle(JColor.ink2)
                if let sub {
                    Text(sub)
                        .font(JType.rowSub)
                        .foregroundStyle(JColor.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, first ? 0 : 11)
        .padding(.bottom, 11)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(JColor.line)
                    .frame(height: 1)
            }
        }
    }
}

extension JCardHead where Accessory == EmptyView {
    init(icon: String, title: String) {
        self.init(icon: icon, title: title, accessory: nil)
    }
}

/// Mock `.row.act`: a tappable row — padding 13/15 (mock inline style on the
/// Connections rows), title in full ink, hover fill, optional trailing view.
struct JActionRow<Accessory: View>: View {
    let title: String
    var sub: String? = nil
    var icon: String? = nil
    var first: Bool = false
    var showChevron: Bool = true
    var accessory: Accessory?
    let action: () -> Void

    init(title: String, sub: String? = nil, icon: String? = nil, first: Bool = false,
         showChevron: Bool = true, accessory: Accessory?, action: @escaping () -> Void) {
        self.title = title
        self.sub = sub
        self.icon = icon
        self.first = first
        self.showChevron = showChevron
        self.accessory = accessory
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 11) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(JColor.ink3)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(JType.rowTitle)
                        .foregroundStyle(JColor.ink)
                    if let sub {
                        Text(sub)
                            .font(JType.rowSub)
                            .foregroundStyle(JColor.ink4)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                accessory
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(JColor.ink4)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(JRowButtonStyle(first: first))
    }
}

/// Row hit-area styling: plain button with an inset hover fill and a top hairline.
private struct JRowButtonStyle: ButtonStyle {
    let first: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.028) : Color.clear)
            .overlay(alignment: .top) {
                if !first {
                    Rectangle()
                        .fill(JColor.line)
                        .frame(height: 1)
                        .padding(.horizontal, 15)
                }
            }
    }
}

extension JActionRow where Accessory == EmptyView {
    init(title: String, sub: String? = nil, icon: String? = nil, first: Bool = false,
         showChevron: Bool = true, action: @escaping () -> Void) {
        self.init(title: title, sub: sub, icon: icon, first: first,
                  showChevron: showChevron, accessory: nil, action: action)
    }
}

// MARK: - Chip

/// Mock `.chip`: 21pt pill, mono 10.5, tinted soft fill + 25% border.
struct JChip: View {
    enum Kind {
        case ok, warn, danger, neutral, accent

        var text: Color {
            switch self {
            case .ok:      return JColor.ok
            case .warn:    return JColor.warn
            case .danger:  return JColor.danger
            case .accent:  return JColor.accent
            case .neutral: return JColor.ink3
            }
        }

        var fill: Color {
            switch self {
            case .ok:      return JColor.okSoft
            case .warn:    return JColor.warnSoft
            case .danger:  return JColor.dangerSoft
            case .accent:  return JColor.accentSoft
            case .neutral: return JColor.inset
            }
        }

        var border: Color {
            switch self {
            case .ok:      return JColor.ok.opacity(0.25)
            case .warn:    return JColor.warn.opacity(0.25)
            case .danger:  return JColor.danger.opacity(0.25)
            case .accent:  return JColor.accent.opacity(0.30)
            case .neutral: return JColor.line
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(kind.text)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(
                Capsule(style: .continuous)
                    .fill(kind.fill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(kind.border, lineWidth: 1)
            )
    }
}

// MARK: - Switch

/// Mock `.sw`: 34×20 pill switch, accent when on.
struct JSwitch: View {
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)?

    /// `binding:` label avoids the `JSwitch($x)` trailing-closure ambiguity.
    init(binding: Binding<Bool>, onChange: ((Bool) -> Void)? = nil) {
        self._isOn = binding
        self.onChange = onChange
    }

    var body: some View {
        Button {
            let next = !isOn
            isOn = next
            onChange?(next)
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? JColor.accent : Color.white.opacity(0.10))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(isOn ? Color.white : JColor.ink3)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2.5)
            }
            .animation(.easeOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stepper

/// Mock `.stepper`: 26pt − / + buttons (radius 7, inset) around a mono value.
struct JStepper: View {
    let value: String
    let onDown: () -> Void
    let onUp: () -> Void
    var downDisabled: Bool = false
    var upDisabled: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            stepButton("−", disabled: downDisabled, action: onDown)

            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(JColor.ink)
                .frame(minWidth: 46)

            stepButton("+", disabled: upDisabled, action: onUp)
        }
    }

    private func stepButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(disabled ? JColor.ink4 : JColor.ink3)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(JColor.inset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(JColor.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Segmented

/// Mock `.seg`: 3pt inset track, 26pt buttons, radius 6, active = overlay bg.
struct JSegment<T: Hashable>: View {
    let options: [(value: T, title: String)]
    @Binding var selection: T
    var onChange: ((T) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                    onChange?(option.value)
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(selection == option.value ? JColor.ink : JColor.ink4)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option.value ? JColor.overlay : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous)
                .fill(JColor.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous)
                .strokeBorder(JColor.line, lineWidth: 1)
        )
    }
}

// MARK: - Buttons

/// Mock `.btn`: default / primary / ghost / danger, sm + block modifiers.
struct JButtonStyle: ButtonStyle {
    enum Intent { case standard, primary, ghost, danger }

    var intent: Intent = .standard
    var size: ControlSize = .regular
    var block: Bool = false

    private var isSmall: Bool { size == .small || size == .mini }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isSmall ? 11.5 : 12, weight: .medium))
            .foregroundStyle(foreground(pressed: configuration.isPressed))
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: isSmall ? 27 : 32)
            .padding(.horizontal, isSmall ? 10 : 13)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous)
                    .strokeBorder(border(), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func foreground(pressed: Bool) -> Color {
        switch intent {
        case .standard: return pressed ? JColor.ink : JColor.ink2
        case .primary:  return Color(red: 0.04, green: 0.04, blue: 0.07)
        case .ghost:    return JColor.ink3
        case .danger:   return JColor.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch intent {
        case .standard: return pressed ? Color.white.opacity(0.07) : JColor.inset
        case .primary:  return pressed ? JColor.accent.opacity(0.85) : JColor.accent
        case .ghost:    return Color.clear
        case .danger:   return JColor.dangerSoft
        }
    }

    private func border() -> Color {
        switch intent {
        case .standard: return JColor.line
        case .primary:  return JColor.accent
        case .ghost:    return Color.clear
        case .danger:   return JColor.danger.opacity(0.3)
        }
    }
}

extension View {
    func jButton(intent: JButtonStyle.Intent = .standard, size: ControlSize = .regular, block: Bool = false) -> some View {
        buttonStyle(JButtonStyle(intent: intent, size: size, block: block))
    }
}

// MARK: - Field

/// Mock `.fld-i`: inset text field.
struct JFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .regular))
            .textFieldStyle(.plain)
            .foregroundStyle(JColor.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous)
                    .fill(JColor.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JRadius.sm, style: .continuous)
                    .strokeBorder(JColor.line, lineWidth: 1)
            )
    }
}

extension View {
    func jField() -> some View { modifier(JFieldStyle()) }

    func fieldLabel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JColor.ink3)
            self
        }
    }
}

// MARK: - Refresh icon

/// Shared flush-right plain refresh icon (matches the Stats/Display headers).
struct JRefreshButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JColor.ink3)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }
}
