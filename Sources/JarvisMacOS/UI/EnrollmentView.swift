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
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(JarvisColor.accent)
                Text("Voice enrollment")
                    .font(JarvisType.title)
                    .foregroundStyle(JarvisColor.textPrimary)
                Spacer()
                enrollmentBadge
            }

            if appState.enrollmentCompleted && appState.voiceProfileReady {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(JarvisColor.ok)
                    Text("Voice profile ready")
                        .font(JarvisType.body)
                        .foregroundStyle(JarvisColor.textSecondary)
                }

                HStack {
                    Text("Total samples")
                        .font(JarvisType.caption)
                        .foregroundStyle(JarvisColor.textSecondary)
                    Spacer()
                    Text("\(totalSamplesCollected)/\(totalSamplesRequired)")
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.ok)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {

                    HStack(spacing: 6) {
                        layerBadge(layer: 1, complete: layer1Complete)
                        layerBadge(layer: 2, complete: appState.enrollmentCompleted)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Phrase \(min(appState.enrollmentIndex + 1, totalSteps))/\(totalSteps)")
                                .font(JarvisType.dataSmall)
                                .foregroundStyle(JarvisColor.textSecondary)
                            Spacer()
                            Text("Rep \(appState.enrollmentCurrentPhraseMatchCount)/\(appState.enrollmentRequiredMatchesPerPhrase)")
                                .font(JarvisType.dataSmall)
                                .foregroundStyle(JarvisColor.accent)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(JarvisColor.surfaceRaised)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(JarvisColor.accent)
                                    .frame(width: geo.size.width * progress, height: 4)
                                    .animation(.easeOut(duration: 0.4), value: progress)
                            }
                        }
                        .frame(height: 4)
                    }

                    HStack {
                        Text("Samples")
                            .font(JarvisType.caption)
                            .foregroundStyle(JarvisColor.textTertiary)
                        Spacer()
                        Text("\(totalSamplesCollected)/\(totalSamplesRequired)")
                            .font(JarvisType.dataSmall)
                            .foregroundStyle(JarvisColor.accent)
                    }

                    if appState.enrollmentActive {
                        Text(appState.currentEnrollmentPhrase)
                            .font(JarvisType.body)
                            .foregroundStyle(JarvisColor.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                                    .fill(JarvisColor.accent.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                                    .strokeBorder(JarvisColor.accent.opacity(0.22), lineWidth: 1)
                            )

                        if appState.latestEnrollmentScore > 0 {
                            HStack(spacing: 6) {
                                Text("Last score")
                                    .font(JarvisType.caption)
                                    .foregroundStyle(JarvisColor.textTertiary)
                                Text(String(format: "%.2f", appState.latestEnrollmentScore))
                                    .font(JarvisType.dataSmall)
                                    .foregroundStyle(scoreColor(appState.latestEnrollmentScore))
                                Spacer()
                                Text("Attempts \(appState.enrollmentAttemptCount)")
                                    .font(JarvisType.dataSmall)
                                    .foregroundStyle(JarvisColor.textTertiary)
                            }
                        }
                    }
                }
            }

            // Always visible — including once the profile is ready, so the
            // voice can be re-enrolled/retrained at any time.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        appState.startEnrollment()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(!appState.micActive || appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.accent, compact: true))

                    Button {
                        appState.stopEnrollment()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(!appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.danger, compact: true))

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        appState.retrainVoiceProfile()
                    } label: {
                        Label("Retrain voice", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!appState.micActive || appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.attention, compact: true))
                    .help("Deletes ALL stored voice samples, then starts a fresh enrollment so only the new samples are used")

                    Button {
                        appState.resetVoiceProfile()
                    } label: {
                        Label("Clear", systemImage: "trash.fill")
                    }
                    .disabled(appState.enrollmentActive)
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))
                    .help("Clear stored voice embeddings (POST /reset) without starting a new enrollment")

                    Spacer()
                }

                Text("Retrain wipes old samples first — verify against the new enrollment only.")
                    .font(JarvisType.micro)
                    .foregroundStyle(JarvisColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

    }

    // MARK: - Layer badge

    @ViewBuilder
    private func layerBadge(layer: Int, complete: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(complete ? JarvisColor.ok : JarvisColor.textTertiary)
            Text("Layer \(layer)")
                .font(JarvisType.dataSmall)
                .foregroundStyle(complete ? JarvisColor.ok : JarvisColor.textTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(complete ? JarvisColor.ok.opacity(0.10) : JarvisColor.surface)
        )
    }

    // MARK: - Enrollment badge

    @ViewBuilder
    private var enrollmentBadge: some View {
        if appState.enrollmentActive {
            Text("Training")
                .font(JarvisType.dataSmall)
                .foregroundStyle(JarvisColor.attention)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(JarvisColor.attention.opacity(0.12))
                .clipShape(Capsule())
        } else if appState.enrollmentCompleted {
            Text("Done")
                .font(JarvisType.dataSmall)
                .foregroundStyle(JarvisColor.ok)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(JarvisColor.ok.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.7 { return JarvisColor.ok }
        if score >= 0.48 { return JarvisColor.attention }
        return JarvisColor.danger
    }
}
