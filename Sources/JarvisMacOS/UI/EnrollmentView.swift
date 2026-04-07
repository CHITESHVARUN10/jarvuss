import SwiftUI

struct EnrollmentView: View {
    @ObservedObject var appState: AppState

    private var totalSteps: Int { appState.enrollmentPhrases.count }
    private var completedSteps: Int { min(appState.enrollmentIndex, totalSteps) }

    private var totalSamplesCollected: Int {
        appState.backendEnrollmentSampleCount
    }
    private var totalSamplesRequired: Int {
        appState.voiceEnrollmentSampleTarget
    }

    private var progress: Double {
        guard totalSteps > 0 else { return 0 }
        let phraseProgress = Double(appState.enrollmentIndex) / Double(totalSteps)
        let subProgress = Double(appState.enrollmentCurrentPhraseMatchCount) / Double(appState.enrollmentRequiredMatchesPerPhrase)
        return min(1.0, phraseProgress + subProgress / Double(totalSteps))
    }

    /// Which layer the current phrase belongs to.
    private var currentLayer: Int {
        appState.enrollmentIndex < AppState.layer1PhraseCount ? 1 : 2
    }

    /// Is layer 1 complete?
    private var layer1Complete: Bool {
        appState.enrollmentIndex >= AppState.layer1PhraseCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.75, green: 0.55, blue: 1.0))
                Text("VOICE ENROLLMENT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color(red: 0.75, green: 0.55, blue: 1.0).opacity(0.8))
                Spacer()
                enrollmentBadge
            }

            if appState.enrollmentCompleted && appState.voiceProfileReady {
                // Complete state
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.25, green: 0.90, blue: 0.65))
                    Text("Voice profile ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                // Total samples
                HStack {
                    Text("Total samples")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Text("\(totalSamplesCollected)/\(totalSamplesRequired)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.25, green: 0.90, blue: 0.65))
                }
            } else {
                // Progress section
                VStack(alignment: .leading, spacing: 6) {

                    // Layer status badges
                    HStack(spacing: 6) {
                        layerBadge(layer: 1, complete: layer1Complete)
                        layerBadge(layer: 2, complete: appState.enrollmentCompleted)
                    }

                    // Total progress bar
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Phrase \(min(appState.enrollmentIndex + 1, totalSteps))/\(totalSteps)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.45))
                            Spacer()
                            Text("Rep \(appState.enrollmentCurrentPhraseMatchCount)/\(appState.enrollmentRequiredMatchesPerPhrase)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.75, green: 0.55, blue: 1.0))
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.07))
                                    .frame(height: 5)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.55, green: 0.55, blue: 1.0),
                                                Color(red: 0.75, green: 0.35, blue: 1.0)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: geo.size.width * progress, height: 5)
                                    .animation(.easeOut(duration: 0.4), value: progress)
                            }
                        }
                        .frame(height: 5)
                    }

                    // Total samples collected
                    HStack {
                        Text("Samples")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.35))
                        Spacer()
                        Text("\(totalSamplesCollected)/\(totalSamplesRequired)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 1.0))
                    }

                    // Current phrase
                    if appState.enrollmentActive {
                        Text(appState.currentEnrollmentPhrase)
                            .font(.system(size: 12, weight: .medium, design: .default))
                            .foregroundStyle(Color.white.opacity(0.80))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.25), lineWidth: 1)
                            )

                        // Score badge
                        if appState.latestEnrollmentScore > 0 {
                            HStack(spacing: 6) {
                                Text("Last score:")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.35))
                                Text(String(format: "%.2f", appState.latestEnrollmentScore))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(scoreColor(appState.latestEnrollmentScore))
                                Spacer()
                                Text("Attempts: \(appState.enrollmentAttemptCount)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.30))
                            }
                        }
                    }
                }

                // Control buttons
                HStack(spacing: 8) {
                    Button {
                        appState.startEnrollment()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .disabled(!appState.micActive || appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: Color(red: 0.55, green: 0.45, blue: 1.0), compact: true))

                    Button {
                        appState.stopEnrollment()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .disabled(!appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: Color(red: 0.75, green: 0.25, blue: 0.45), compact: true))
                }
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.06))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.18), lineWidth: 1)
            }
        )
    }

    // MARK: - Layer badge

    @ViewBuilder
    private func layerBadge(layer: Int, complete: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(complete
                    ? Color(red: 0.25, green: 0.90, blue: 0.65)
                    : Color.white.opacity(0.30))
            Text("Layer \(layer)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(complete
                    ? Color(red: 0.25, green: 0.90, blue: 0.65).opacity(0.8)
                    : Color.white.opacity(0.35))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(complete
                    ? Color(red: 0.25, green: 0.90, blue: 0.65).opacity(0.10)
                    : Color.white.opacity(0.04))
        )
    }

    // MARK: - Enrollment badge

    @ViewBuilder
    private var enrollmentBadge: some View {
        if appState.enrollmentActive {
            Text("TRAINING")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.2))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(red: 1.0, green: 0.78, blue: 0.2).opacity(0.15))
                .clipShape(Capsule())
        } else if appState.enrollmentCompleted {
            Text("DONE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color(red: 0.25, green: 0.90, blue: 0.65))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(red: 0.25, green: 0.90, blue: 0.65).opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.7 { return Color(red: 0.25, green: 0.90, blue: 0.65) }
        if score >= 0.48 { return Color(red: 1.0, green: 0.78, blue: 0.2) }
        return Color(red: 1.0, green: 0.40, blue: 0.55)
    }
}

// MARK: - Shared button style
struct JarvisButtonStyle: ButtonStyle {
    let color: Color
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? color.opacity(0.6) : color)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 9)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.20 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .strokeBorder(color.opacity(0.30), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
