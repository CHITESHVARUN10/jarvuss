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
                HStack {
                    Label {
                        Text("LIVE TRANSCRIPT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.85))
                    } icon: {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.85))
                    }
                    Spacer()
                    if !lastSpeech.isEmpty {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.75, green: 0.55, blue: 1.0))
                    }
                }

                Text(lastSpeech.isEmpty ? "Awaiting voice input..." : "\"\(lastSpeech)\"")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(lastSpeech.isEmpty
                        ? Color.white.opacity(0.25)
                        : Color.white.opacity(0.90))
                    .lineLimit(3)
                    .animation(.easeOut(duration: 0.3), value: lastSpeech)
                    .textSelection(.enabled)

                if !currentCommand.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.08))

                    HStack(alignment: .top, spacing: 8) {
                        Text("CMD")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.65))
                            .padding(.top, 1)

                        Text(currentCommand)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.75))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.75))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
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
        state == .recording
            ? Color(red: 1.0, green: 0.38, blue: 0.55)
            : Color(red: 0.55, green: 0.62, blue: 1.0)
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
