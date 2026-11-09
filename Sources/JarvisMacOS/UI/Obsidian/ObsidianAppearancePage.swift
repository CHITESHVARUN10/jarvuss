import SwiftUI

struct ObsidianAppearancePage: View {
    @State private var appearance = AppAppearance.shared
    @State private var glassDemo = false
    @Environment(\.obsidianWindowWidth) private var windowWidth
    var body: some View {
        @Bindable var appearance = appearance
        NoirPage(eyebrow: "", title: "Appearance", sub: "Customize the accent, assistant orb, and glass finish.") {
            NoirSectionHeading(title: "Accent color", minHeight: 20)
            AccentChoices()
            NoirSectionHeading(title: "Assistant")
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Assistant orb", sub: "Shown in the main app, never in recording overlays.") {
                        Picker("Assistant orb", selection: $appearance.orbStyle) {
                            ForEach(AssistantOrbStyle.allCases) { style in Text(style.title).tag(style) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 190)
                        .accessibilityIdentifier("appearance.orbStyle")
                    }
                    NoirDivider()
                    VStack(spacing: 5) {
                        AssistantOrbView().frame(width: min(300, max(220, windowWidth * 0.14)), height: min(300, max(220, windowWidth * 0.14)))
                        Text(appearance.orbStyle.title).obsidianFont(size: 13, weight: .medium).foregroundStyle(NoirPalette.text)
                        Text(appearance.orbStyle.detail).obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 4).padding(.bottom, 22)
                }
            }
            NoirSectionHeading(title: "Interface")
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Interface text", sub: "Choose Extra Small through Extra Large. Changes apply immediately.") {
                        Picker("Interface text size", selection: $appearance.textSize) {
                            ForEach(InterfaceTextSize.allCases) { size in Text(size.title).tag(size) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 160)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Glass opacity", sub: "Lower values reveal more of the background behind dialogs and recording panels.") {
                        percentSlider($appearance.glassOpacity, range: 0.35...1, label: "Glass opacity")
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Border contrast", sub: "Separation between controls and surfaces.") {
                        percentSlider($appearance.borderContrast, range: 0.75...1.5, label: "Border contrast")
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Animate orb", sub: "Respects Reduce Motion and pauses when the window is hidden.") {
                        NoirSwitch(isOn: $appearance.animateOrb)
                    }
                }
            }
            NoirSectionHeading(title: "Recording overlay", trailing: AnyView(Button("Test glass") { glassDemo = true }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))))
            ZStack {
                HStack(spacing: 16) {
                    sampleWindow("Projects"); sampleWindow("Portfolio")
                }.padding(18)
                ObsidianRecordingPreview()
                    .frame(width: 350)
                    .padding(.vertical, 28)
            }
            .background(LinearGradient(colors: [NoirPalette.accent.opacity(0.18), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NoirPalette.line, lineWidth: 1))
            HStack {
                Button("Reset appearance") { appearance.reset() }.buttonStyle(.plain).foregroundStyle(NoirPalette.accent)
                Spacer()
                Text("Saved on this Mac").foregroundStyle(NoirPalette.muted)
            }.obsidianFont(size: 10).padding(.top, 17)
        }
        .sheet(isPresented: $glassDemo) { ObsidianGlassDemo().presentationBackground(.clear) }
    }
    private func sampleWindow(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).obsidianFont(size: 14).foregroundStyle(.white.opacity(0.7))
            Capsule().fill(NoirPalette.accent.opacity(0.5)).frame(width: 80, height: 4)
            Capsule().fill(.white.opacity(0.14)).frame(height: 4)
            Capsule().fill(.white.opacity(0.1)).frame(height: 4)
        }.padding(17).frame(maxWidth: .infinity).frame(height: 128)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
    private func percentSlider(_ value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Text("\(Int((value.wrappedValue * 100).rounded()))%").obsidianFont(size: 11, design: .monospaced).foregroundStyle(NoirPalette.secondary).frame(width: 38, alignment: .trailing)
            Slider(value: value, in: range).tint(NoirPalette.accent).frame(width: 140).accessibilityLabel(label)
        }
    }
}

private struct ObsidianRecordingPreview: View {
    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "mic").foregroundStyle(NoirPalette.accent)
                Text("Dictation · recording")
                Spacer()
                Text("0:00").monospacedDigit().foregroundStyle(NoirPalette.secondary)
            }.obsidianFont(size: 10)
            RecordingWaveformPreview().frame(height: 35)
            HStack {
                Label("On-device recording", systemImage: "lock").foregroundStyle(NoirPalette.secondary)
                Text("⌘⇧D").foregroundStyle(NoirPalette.muted)
                Spacer()
                Text("Preview").foregroundStyle(NoirPalette.secondary)
            }.obsidianFont(size: 9)
        }.padding(16)
            .background(GlassPanelBackground(behindWindow: false))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
    }
}

private struct ObsidianGlassDemo: View {
    @State private var appearance = AppAppearance.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var appearance = appearance
        VStack(alignment: .leading, spacing: 20) {
            Text("Glass preview").obsidianFont(size: 15, weight: .medium)
            Text("Adjust the opacity to see the app behind this dialog. Recording panels use the same finish.").obsidianFont(size: 12).foregroundStyle(NoirPalette.secondary)
            HStack {
                Text("Glass opacity").obsidianFont(size: 12)
                Slider(value: $appearance.glassOpacity, in: 0.35...1).tint(NoirPalette.accent).accessibilityLabel("Dialog glass opacity")
                Text("\(Int((appearance.glassOpacity * 100).rounded()))%").obsidianFont(size: 11, design: .monospaced).frame(width: 38)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(NoirButtonStyle(intent: .primary)) }
        }.padding(24).frame(width: 430).foregroundStyle(NoirPalette.text)
            .background(GlassPanelBackground()).preferredColorScheme(.dark)
    }
}

/// Six accents on wide windows, three on compact windows. No fixed content cap.
private struct AccentChoices: View {
    @State private var appearance = AppAppearance.shared
    var body: some View {
        AccentSwatchLayout {
            ForEach(AccentTheme.allCases) { theme in
                Button { appearance.accent = theme } label: {
                    HStack(spacing: 9) {
                        Circle().fill(theme.color.gradient).frame(width: 23, height: 23)
                        Text(theme.title).obsidianFont(size: 12)
                        Spacer(minLength: 0)
                        if appearance.accent == theme { Image(systemName: "checkmark").obsidianFont(size: 10) }
                    }
                    .foregroundStyle(NoirPalette.text).padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 7).fill(NoirPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(appearance.accent == theme ? theme.color : NoirPalette.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(theme.title) accent")
                    .accessibilityAddTraits(appearance.accent == theme ? .isSelected : [])
            }
        }
    }
}
private struct AccentSwatchLayout: Layout {
    private func columns(_ width: CGFloat) -> Int { width >= 900 ? 6 : width >= 420 ? 3 : 2 }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let rows = (subviews.count + columns(width) - 1) / columns(width)
        return CGSize(width: width, height: CGFloat(rows) * 48 + CGFloat(max(0, rows - 1)) * 9)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = columns(bounds.width), width = (bounds.width - CGFloat(count - 1) * 9) / CGFloat(count)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % count) * (width + 9), y: bounds.minY + CGFloat(index / count) * 57), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: 48))
        }
    }
}

private struct RecordingWaveformPreview: View {
    var body: some View {
        let color = NoirPalette.accent
        Canvas { context, size in
            for index in 0..<64 {
                let i = Double(index)
                let height = 7 + pow(sin(i * 1.7), 2) * 18 + pow(sin(i * 0.3), 2) * 10
                let rect = CGRect(x: (size.width - 2) * i / 63, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }.accessibilityHidden(true)
    }
}
