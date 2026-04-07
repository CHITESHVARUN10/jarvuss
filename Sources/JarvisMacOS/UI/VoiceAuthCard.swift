import SwiftUI

struct VoiceAuthCard: View {
    let status: String
    let similarity: Double
    let samplesCount: Int
    let samplesTarget: Int

    private var isStrong: Bool { status.contains("Strong") }
    private var isLowConf: Bool { status.contains("Low Confidence") }
    private var isVerified: Bool { status.contains("✅") }
    private var isWarning: Bool { status.contains("⚠️") }

    private var accentColor: Color {
        if isStrong   { return Color(red: 0.25, green: 0.90, blue: 0.65) }
        if isLowConf  { return Color(red: 1.0,  green: 0.78, blue: 0.20) }
        if isVerified { return Color(red: 0.25, green: 0.90, blue: 0.65) }
        if isWarning  { return Color(red: 1.0,  green: 0.78, blue: 0.20) }
        return Color(red: 0.75, green: 0.35, blue: 1.0)
    }

    private var iconName: String {
        if isStrong   { return "checkmark.shield.fill" }
        if isLowConf  { return "exclamationmark.shield.fill" }
        if isVerified { return "checkmark.shield.fill" }
        if isWarning  { return "exclamationmark.shield.fill" }
        return "shield.slash.fill"
    }

    private var confidenceLabel: String {
        if isStrong   { return "Strong" }
        if isLowConf  { return "Low" }
        if isVerified { return "OK" }
        if isWarning  { return "Warn" }
        return "None"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(accentColor)

                Text("VOICE AUTH")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(accentColor.opacity(0.8))

                Spacer()

                Text(cleanStatus)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            // Sample progress bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Samples")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Text("\(samplesCount)/\(samplesTarget)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 5)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accentColor.opacity(0.8))
                            .frame(width: geo.size.width * sampleProgress, height: 5)
                            .animation(.easeOut(duration: 0.5), value: samplesCount)
                    }
                }
                .frame(height: 5)
            }

            // Similarity + Confidence row
            HStack {
                Text("Similarity")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()

                // Confidence badge
                Text(confidenceLabel.uppercased())
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())

                Text(String(format: "%.0f%%", similarity * 100))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentColor.opacity(0.06))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            }
        )
    }

    private var cleanStatus: String {
        status
            .replacingOccurrences(of: "✅", with: "")
            .replacingOccurrences(of: "⚠️", with: "")
            .replacingOccurrences(of: "❌", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var sampleProgress: CGFloat {
        guard samplesTarget > 0 else { return 0 }
        return CGFloat(min(samplesCount, samplesTarget)) / CGFloat(samplesTarget)
    }
}
