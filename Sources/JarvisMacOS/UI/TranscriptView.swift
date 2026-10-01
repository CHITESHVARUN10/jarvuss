import SwiftUI

/// Mock `.transcript`: 520pt max width, min-height 64, radius lg, inset bg,
/// hairline border, 18/20 padding — text, plan tags, live wave.
struct TranscriptView: View {
    let lastSpeech: String
    let currentCommand: String
    let audioLevel: Double
    let state: AppState.AssistantState

    private var isActive: Bool {
        state != .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(displayText)
                .font(.system(size: 14))
                .foregroundStyle(lastSpeech.isEmpty && currentCommand.isEmpty ? JColor.ink4 : JColor.ink)
                .lineSpacing(4)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.3), value: lastSpeech)

            if !currentCommand.isEmpty {
                planTags
            }

            if isActive {
                WaveformView(level: audioLevel, state: state)
                    .frame(height: 14)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 520, minHeight: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: JRadius.lg, style: .continuous)
                .fill(isActive ? JColor.raised : JColor.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JRadius.lg, style: .continuous)
                .strokeBorder(isActive ? JColor.lineStrong : JColor.line, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.3), value: isActive)
    }

    private var displayText: String {
        if !lastSpeech.isEmpty { return lastSpeech }
        if !currentCommand.isEmpty { return "Running plan…" }
        return "Ready when you are"
    }

    /// Mock `.t-plan` + `.tag`: 23pt mono chips in accent-soft with an index.
    private var planTags: some View {
        HStack(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { idx, tag in
                HStack(spacing: 5) {
                    Text("\(idx + 1)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(JColor.accent.opacity(0.5))
                    Text(tag)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(JColor.accent)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(
                    RoundedRectangle(cornerRadius: JRadius.xs, style: .continuous)
                        .fill(JColor.accentSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: JRadius.xs, style: .continuous)
                        .strokeBorder(JColor.accent.opacity(0.30), lineWidth: 1)
                )
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: currentCommand)
    }

    /// The running command split into readable plan steps.
    private var tags: [String] {
        currentCommand
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { $0.count > 22 ? String($0.prefix(21)) + "…" : $0 }
    }
}

/// Mock `.t-wave`: 2pt bars, 14pt tall, accent when live.
struct WaveformView: View {
    let level: Double
    let state: AppState.AssistantState

    private let barCount = 22
    @State private var phases: [Double] = (0..<22).map { Double($0) * 0.4 }
    @State private var timer: Timer?

    private var barColor: Color {
        state == .recording ? JColor.danger : JColor.accent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(barColor.opacity(0.55))
                    .frame(width: 2, height: barHeight(for: i))
                    .animation(.easeInOut(duration: 0.12), value: phases[i])
            }
        }
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
    }

    private func barHeight(for i: Int) -> CGFloat {
        let base: CGFloat = 2
        let sinVal = CGFloat((sin(phases[i]) + 1) / 2)
        let levelBump = CGFloat(level) * 7
        return base + sinVal * 8 + levelBump * (i % 3 == 1 ? 1.2 : 0.8)
    }

    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
            for i in 0..<barCount {
                phases[i] += Double.random(in: 0.15...0.35)
            }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
