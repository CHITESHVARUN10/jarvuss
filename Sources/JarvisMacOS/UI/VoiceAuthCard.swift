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
        if isStrong   { return JarvisColor.ok }
        if isLowConf  { return JarvisColor.attention }
        if isVerified { return JarvisColor.ok }
        if isWarning  { return JarvisColor.attention }
        return JarvisColor.accent
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

                Text("Voice auth")
                    .font(JarvisType.title)
                    .foregroundStyle(JarvisColor.textPrimary)

                Spacer()

                Text(cleanStatus)
                    .font(JarvisType.dataSmall)
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Samples")
                        .font(JarvisType.caption)
                        .foregroundStyle(JarvisColor.textSecondary)
                    Spacer()
                    Text("\(samplesCount)/\(samplesTarget)")
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(accentColor)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(JarvisColor.surfaceRaised)
                            .frame(height: 4)
                        Capsule()
                            .fill(accentColor.opacity(0.8))
                            .frame(width: geo.size.width * sampleProgress, height: 4)
                            .animation(.easeOut(duration: 0.5), value: samplesCount)
                    }
                }
                .frame(height: 4)
            }

            HStack {
                Text("Similarity")
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textSecondary)
                Spacer()

                Text(confidenceLabel)
                    .font(JarvisType.dataSmall)
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())

                Text(String(format: "%.0f%%", similarity * 100))
                    .font(JarvisType.dataSmall)
                    .foregroundStyle(accentColor)
            }
        }

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
