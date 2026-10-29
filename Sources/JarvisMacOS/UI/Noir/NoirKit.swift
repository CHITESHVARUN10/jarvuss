import SwiftUI
import AppKit

// MARK: - Palette

/// Noir tokens, 1:1 with HTMLS/jarvis-noir.html.
enum NoirPalette {
    static let desktop = Color(hex: 0x090A0B)
    static let sidebar = Color(hex: 0x141517)
    static let base    = Color(hex: 0x191A1C)
    static let surface = Color(hex: 0x1E1F22)
    static let raised  = Color(hex: 0x242528)
    static let footer  = Color(hex: 0x17181A)

    static let line       = Color.white.opacity(0.075)
    static let lineStrong = Color.white.opacity(0.13)
    static let hairline   = Color.white.opacity(0.06)

    static let text      = Color(hex: 0xEFEEE9)
    static let secondary = Color(hex: 0xB2B2B7)
    static let muted     = Color(hex: 0x929399)
    static let faint     = Color(hex: 0x6E6F78)
    static let navLabel  = Color(hex: 0x8C8D95)

    static let accent     = Color(hex: 0xB9B6E9)
    static let accentSoft = Color(hex: 0xB9B6E9).opacity(0.10)
    static let accentEdge = Color(hex: 0xB9B6E9).opacity(0.22)

    static let green  = Color(hex: 0xA3C8AE)
    static let orange = Color(hex: 0xDDBD90)
    static let red    = Color(hex: 0xE19B9B)

    static let fieldBg = Color(hex: 0x18191B)
    static let logBg   = Color(hex: 0x17181A)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Type helpers

enum NoirType {
    static let pageTitle = Font.system(size: 29, weight: .regular)
    static let h2        = Font.system(size: 12, weight: .medium)
    static let body      = Font.system(size: 12, weight: .regular)
    static let small     = Font.system(size: 11, weight: .regular)
    static let micro     = Font.system(size: 10, weight: .regular)
    static let mono      = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - Eyebrow

struct NoirEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(NoirPalette.muted)
    }
}

// MARK: - Page scaffold

struct NoirPageHead: View {
    let eyebrow: String
    let title: String
    let sub: String
    var trailing: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirEyebrow(text: eyebrow)
            HStack(alignment: .center, spacing: 20) {
                Text(title)
                    .font(NoirType.pageTitle)
                    .tracking(-0.9)
                    .foregroundStyle(NoirPalette.text)
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            .padding(.top, 9)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 9)
        }
        .padding(.bottom, 28)
    }
}

struct NoirPage<Content: View>: View {
    let eyebrow: String
    let title: String
    let sub: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                NoirPageHead(eyebrow: eyebrow, title: title, sub: sub, trailing: trailing)
                content()
            }
            .padding(.top, 40)
            .padding(.horizontal, 42)
            .padding(.bottom, 44)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(NoirScrollbarInstaller())
        }
        .scrollIndicators(.visible)
    }
}

/// SwiftUI's overlay scroller auto-hides on macOS, which leaves long settings
/// pages with no visible thumb. This installs a persistent, draggable scroll
/// indicator inside the page's NSScrollView.
private struct NoirScrollbarInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleInstall(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleInstall(from: nsView)
    }

    private func scheduleInstall(from view: NSView) {
        DispatchQueue.main.async { install(from: view) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { install(from: view) }
    }

    private func install(from view: NSView) {
        let windowScroll = view.window?.contentView.flatMap { findScrollView(in: $0) }
        guard let scroll = nearestScrollView(from: view) ?? windowScroll else { return }
        let identifier = NSUserInterfaceItemIdentifier("noir.scrollbar")
        guard !scroll.subviews.contains(where: { $0.identifier == identifier }) else { return }

        let overlay = NoirScrollOverlay(scrollView: scroll)
        overlay.identifier = identifier
        overlay.frame = NSRect(x: max(0, scroll.bounds.width - 10),
                               y: 0,
                               width: 10,
                               height: scroll.bounds.height)
        overlay.autoresizingMask = [NSView.AutoresizingMask.minXMargin, NSView.AutoresizingMask.height]
        scroll.addSubview(overlay)
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
    }

    private func nearestScrollView(from view: NSView) -> NSScrollView? {
        var node = view.superview
        while let current = node {
            if let scroll = current as? NSScrollView { return scroll }
            node = current.superview
        }
        return nil
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
    }
}

/// Always-visible 4pt track with a proportional thumb. Click the track to
/// jump, drag the thumb to scroll. The thumbnail is intentionally quiet so
/// the page still reads as a static settings surface.
private final class NoirScrollOverlay: NSView {
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var dragOffset: CGFloat?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private struct Metrics {
        let track: NSRect
        let thumb: NSRect
        let maxScroll: CGFloat
    }

    private func metrics() -> Metrics? {
        guard let scrollView,
              let document = scrollView.documentView else { return nil }
        let documentHeight = document.frame.height
        let viewportHeight = scrollView.contentView.bounds.height
        guard documentHeight > viewportHeight + 1, bounds.height > 24 else { return nil }

        let track = NSRect(x: (bounds.width - 5) / 2, y: 6, width: 5, height: bounds.height - 12)
        let thumbHeight = max(36, track.height * (viewportHeight / documentHeight))
        let maxScroll = documentHeight - viewportHeight
        let progress = min(max(scrollView.contentView.bounds.origin.y / maxScroll, 0), 1)
        let thumbY = track.minY + (track.height - thumbHeight) * progress
        let thumb = NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight)
        return Metrics(track: track, thumb: thumb, maxScroll: maxScroll)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let metrics = metrics() else { return }

        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: metrics.track, xRadius: 2.5, yRadius: 2.5).fill()

        NSColor.white.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: metrics.thumb, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let metrics = metrics() else { return }
        let point = convert(event.locationInWindow, from: nil)

        if metrics.thumb.contains(point) {
            dragOffset = point.y - metrics.thumb.minY
        } else {
            dragOffset = metrics.thumb.height / 2
            scroll(toThumbY: point.y - dragOffset!, metrics: metrics)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let metrics = metrics(), let dragOffset else { return }
        let point = convert(event.locationInWindow, from: nil)
        scroll(toThumbY: point.y - dragOffset, metrics: metrics)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    private func scroll(toThumbY rawY: CGFloat, metrics: Metrics) {
        guard let scrollView else { return }
        let travel = max(1, metrics.track.height - metrics.thumb.height)
        let y = min(max(rawY, metrics.track.minY), metrics.track.maxY - metrics.thumb.height)
        let progress = (y - metrics.track.minY) / travel
        let target = progress * metrics.maxScroll

        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: target
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsDisplay = true
    }
}

// MARK: - Section heading

struct NoirSectionHeading: View {
    let title: String
    var trailing: AnyView? = nil
    var minHeight: CGFloat? = nil

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NoirPalette.text)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .frame(minHeight: minHeight)
        .padding(.top, 25)
        .padding(.bottom, 12)
    }
}

// MARK: - Card

struct NoirCard<Content: View>: View {
    var padded: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padded ? 21 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NoirPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NoirPalette.line, lineWidth: 1)
        )
    }
}

// MARK: - Settings

struct NoirSettingRow<Control: View>: View {
    let title: String
    var sub: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(NoirPalette.text)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11))
                        .lineSpacing(3)
                        .foregroundStyle(NoirPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 66)
        .padding(.horizontal, 19)
        .padding(.vertical, 14)
    }
}

/// Settings rows separated by hairlines. Pair with `NoirCard { ... }`.
struct NoirSettingList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
    }
}

struct NoirDivider: View {
    var body: some View {
        Rectangle()
            .fill(NoirPalette.line)
            .frame(height: 1)
    }
}

// MARK: - Tags

struct NoirTag: View {
    enum Kind { case neutral, green, amber, red, accent }

    let text: String
    var kind: Kind = .neutral
    var icon: String?

    private var fg: Color {
        switch kind {
        case .neutral: return NoirPalette.secondary
        case .green:   return NoirPalette.green
        case .amber:   return NoirPalette.orange
        case .red:     return NoirPalette.red
        case .accent:  return NoirPalette.accent
        }
    }

    private var bg: Color {
        switch kind {
        case .green:  return NoirPalette.green.opacity(0.04)
        case .amber:  return NoirPalette.orange.opacity(0.04)
        case .accent: return NoirPalette.accentSoft
        default:      return .clear
        }
    }

    private var border: Color {
        switch kind {
        case .green:  return NoirPalette.green.opacity(0.13)
        case .amber:  return NoirPalette.orange.opacity(0.13)
        case .red:    return NoirPalette.red.opacity(0.20)
        case .accent: return NoirPalette.accent.opacity(0.20)
        default:      return NoirPalette.line
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
    }
}

// MARK: - Switch

struct NoirSwitch: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? NoirPalette.accent : Color(hex: 0x3C3D41))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(isOn ? NoirPalette.accent : Color(hex: 0x4B4C51), lineWidth: 1)
                    )
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(isOn ? Color(hex: 0x25232E) : Color(hex: 0xACADB0))
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 3)
            }
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Buttons

struct NoirButtonStyle: ButtonStyle {
    enum Intent { case standard, primary, quiet, danger }

    var intent: Intent = .standard
    var small: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 11 : 12, weight: .medium))
            .foregroundStyle(foreground)
            .frame(minHeight: small ? 27 : 33)
            .padding(.horizontal, small ? 10 : 13)
            .padding(.vertical, small ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var foreground: Color {
        switch intent {
        case .standard: return NoirPalette.text
        case .primary:  return Color(hex: 0x22212E)
        case .quiet:    return NoirPalette.secondary
        case .danger:   return NoirPalette.red
        }
    }

    private func background(pressed: Bool) -> Color {
        switch intent {
        case .standard: return Color(hex: pressed ? 0x34353B : 0x292A2E)
        case .primary:  return Color(hex: pressed ? 0xCFCCF4 : 0xB9B6E9)
        case .quiet:    return pressed ? Color.white.opacity(0.04) : .clear
        case .danger:   return Color(hex: 0x342829)
        }
    }

    private var border: Color {
        switch intent {
        case .standard: return NoirPalette.lineStrong
        case .primary:  return NoirPalette.accent
        case .quiet:    return NoirPalette.line
        case .danger:   return Color(hex: 0x513839)
        }
    }
}

struct NoirIconButton: View {
    let icon: String
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? NoirPalette.text : NoirPalette.muted)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.06) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(help ?? icon)
    }
}

// MARK: - Fields

struct NoirFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(NoirPalette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NoirPalette.fieldBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(NoirPalette.lineStrong, lineWidth: 1)
            )
    }
}

extension View {
    func noirField() -> some View { modifier(NoirFieldStyle()) }

    func noirFieldLabel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.secondary)
            self
        }
    }
}

// MARK: - Select (menu picker)

struct NoirSelect<Value: Equatable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var width: CGFloat? = nil

    @State private var isOpen = false

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "—"
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(NoirPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NoirPalette.muted)
            }
            .padding(.horizontal, 10)
            .frame(width: width ?? 160, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NoirPalette.fieldBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(NoirPalette.lineStrong, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let selected = option.value == selection
                    Button {
                        selection = option.value
                        isOpen = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(option.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(selected ? NoirPalette.accent : NoirPalette.secondary)
                            Spacer(minLength: 8)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(NoirPalette.accent)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? NoirPalette.accentSoft : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(width: max(160, width ?? 160))
            .background(NoirPalette.raised)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Segmented control

struct NoirSegmented: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let on = selection == option
                Button { selection = option } label: {
                    Text(option)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(on ? NoirPalette.text : NoirPalette.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? Color(hex: 0x2F3035) : .clear)
                        )
                        .shadow(color: on ? .black.opacity(0.19) : .clear, radius: 1.5, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: 0x121315))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(NoirPalette.line, lineWidth: 1)
        )
    }
}

// MARK: - Brand mark

struct NoirBrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x4E4D5C), Color(hex: 0x24242C)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.23), lineWidth: 1)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.63, weight: .light))
                .foregroundStyle(Color(hex: 0xE4E1F6))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

// MARK: - Toast

@MainActor
final class ToastCenter: ObservableObject {
    @Published var message: String?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String) {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { message = text }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.message = nil }
        }
    }
}

struct NoirToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .lineSpacing(3)
            .foregroundStyle(NoirPalette.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0x303036))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(NoirPalette.accent.opacity(0.27), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.31), radius: 12, y: 8)
            .transition(.opacity.combined(with: .offset(y: 12)))
    }
}

// MARK: - Assistant feed (presentation-only)

@MainActor
final class AssistantFeed: ObservableObject {
    struct Item: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var succeeded: Bool? = nil
    }

    @Published var items: [Item] = []

    func addUser(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(Item(role: .user, text: trimmed))
    }

    func addAssistant(_ text: String, succeeded: Bool? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(Item(role: .assistant, text: trimmed, succeeded: succeeded))
    }

    func reset() {
        items.removeAll()
    }
}
