import SwiftUI

struct TranscriptView: View {
    let lastSpeech: String
    let currentCommand: String
    let audioLevel: Double
    let state: AppState.AssistantState

    var body: some View {
        VStack(spacing: 12) {
            // Waveform bars
            if state == .recording || state == .listening {
                WaveformView(level: audioLevel, state: state)
                    .frame(height: 32)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
            }

            // Transcript card
            VStack(alignment: .leading, spacing: 10) {
                Text(lastSpeech.isEmpty ? "Awaiting voice input…" : lastSpeech)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(lastSpeech.isEmpty
                        ? JarvisColor.textTertiary
                        : JarvisColor.textPrimary)
                    .lineLimit(3)
                    .animation(.easeOut(duration: 0.3), value: lastSpeech)
                    .textSelection(.enabled)

                if !currentCommand.isEmpty {
                    Divider()
                        .overlay(JarvisColor.hairline)

                    HStack(alignment: .top, spacing: 8) {
                        Text("CMD")
                            .font(JarvisType.dataSmall)
                            .foregroundStyle(JarvisColor.ok)
                            .padding(.top, 1)

                        Text(currentCommand)
                            .font(JarvisType.data)
                            .foregroundStyle(JarvisColor.ok)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: JarvisRadius.lg, style: .continuous)
                        .fill(JarvisColor.canvas)
                    RoundedRectangle(cornerRadius: JarvisRadius.lg, style: .continuous)
                        .strokeBorder(JarvisColor.hairline, lineWidth: 1)
                }
            )
        }
    }
}

struct WaveformView: View {
    let level: Double
    let state: AppState.AssistantState

    private let barCount = 18
    @State private var phases: [Double] = (0..<18).map { Double($0) * 0.4 }
    @State private var timer: Timer?

    private var barColor: Color {
        state == .recording ? JarvisColor.danger : JarvisColor.accent
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor.opacity(0.6 + 0.4 * sin(phases[i])))
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(.easeInOut(duration: 0.12), value: phases[i])
            }
        }
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
    }

    private func barHeight(for i: Int) -> CGFloat {
        let base: CGFloat = 4
        let sinVal = CGFloat((sin(phases[i]) + 1) / 2)
        let levelBump = CGFloat(level) * 20
        return base + sinVal * 22 + levelBump * (i % 3 == 1 ? 1.2 : 0.8)
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
