import SwiftUI

/// Rail navigation sections, in mock order. About is pinned to the rail bottom.
enum RailSection: String, CaseIterable, Identifiable {
    case assistant
    case voice
    case insights
    case routines
    case system
    case connections
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant:   return "Assistant"
        case .voice:       return "Voice"
        case .insights:    return "Insights"
        case .routines:    return "Routines"
        case .system:      return "System"
        case .connections: return "Connections"
        case .about:       return "About"
        }
    }

    var icon: String {
        switch self {
        case .assistant:   return "message"
        case .voice:       return "mic"
        case .insights:    return "chart.xyaxis.line"
        case .routines:    return "bolt"
        case .system:      return "gearshape"
        case .connections: return "cable.connector"
        case .about:       return "info.circle"
        }
    }

    /// Sections shown in the main nav column (about is pinned to the bottom).
    static var main: [RailSection] {
        [.assistant, .voice, .insights, .routines, .system, .connections]
    }
}

struct RailView: View {
    @ObservedObject var appState: AppState
    @Binding var section: RailSection
    @State private var hovered: RailSection?

    var body: some View {
        VStack(spacing: 6) {
            // Mock `.rail-mark`: 34pt rounded square, gradient, accent shadow.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [JColor.accent, Color(red: 0.357, green: 0.384, blue: 0.910)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: "sun.max")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: JColor.accent.opacity(0.5), radius: 7, x: 0, y: 4)

            Spacer(minLength: 18)

            VStack(spacing: 4) {
                ForEach(RailSection.main) { item in
                    railButton(for: item)
                }
            }

            Spacer(minLength: 18)

            railButton(for: .about)
        }
        .padding(.vertical, 14)
        .frame(width: 64)
        .background(JColor.base)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(JColor.line),
            alignment: .trailing
        )
    }

    private func railButton(for item: RailSection) -> some View {
        let isOn = section == item
        let isHovered = hovered == item && !isOn

        return Button {
            section = item
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isOn ? JColor.accentSoft : (isHovered ? JColor.inset : Color.clear))
                    .frame(width: 40, height: 40)

                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? JColor.accent : (isHovered ? JColor.ink2 : JColor.ink3))
                    .frame(width: 40, height: 40)

                if isOn {
                    // Mock `.rail-btn.on::before`: 3pt accent bar flush to the rail edge.
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(JColor.accent)
                        .frame(width: 3, height: 18)
                        .offset(x: -12)
                }

                if showsBadge(for: item) {
                    // Mock `.badge-dot`: top/right 7pt, ringed in the rail bg.
                    Circle()
                        .fill(JColor.warn)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(JColor.base, lineWidth: 2))
                        .offset(x: 27, y: -13)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    /// Voice: profile not ready. Connections: Spotify expired/missing or PG off.
    private func showsBadge(for item: RailSection) -> Bool {
        switch item {
        case .voice:
            return !appState.voiceProfileReady
        case .connections:
            return appState.spotifyExpired || !appState.postgresConfigured
        default:
            return false
        }
    }
}
