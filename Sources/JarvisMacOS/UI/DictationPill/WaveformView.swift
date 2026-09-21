import SwiftUI

/// Live audio-level waveform: 19 animated bars, calm and organic.
/// Gain follows the mic level; idle motion keeps the pill feeling alive.
///
/// Named `PillWaveformView` to avoid colliding with the main-window
/// `WaveformView` in TranscriptView.swift (different design).
struct PillWaveformView: View {
    let audioLevel: Float
    private let barCount = 19
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 2.5

    init(audioLevel: Float = 0.2) {
        self.audioLevel = audioLevel
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let midY = size.height / 2
                let maxH = size.height * 0.42
                let gain = 0.3 + Double(audioLevel) * 0.7

                for i in 0..<barCount {
                    let x = Double(i) * (barWidth + gap) + gap / 2
                    let p = Double(i) * 0.618034
                    let f = 1.3 + Double(i) * 0.07

                    let a = sin(time * f * 1.1 + p * 6.28) * 0.5
                    let b = sin(time * f * 0.7 + p * 9.42 + 1.5) * 0.3
                    let c = sin(time * f * 0.53 + p * 3.14 + 0.8) * 0.2

                    let raw = max((a + b + c + 0.5), 0.05)
                    let amp = max(raw * gain, 0.2)
                    let h = amp * maxH

                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: midY - h, width: barWidth, height: h * 2), cornerRadius: 1.25),
                        with: .color(.white.opacity(0.55))
                    )
                }
            }
            .frame(height: 20)
        }
    }
}
