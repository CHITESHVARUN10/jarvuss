import SwiftUI

/// Voice pane — profile ring, capture log, enrollment actions.
struct VoicePane: View {
    @ObservedObject var appState: AppState

    private var target: Int { appState.voiceEnrollmentSampleTarget }
    private var collected: Int { appState.backendEnrollmentSampleCount }
    private var frac: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(collected) / Double(target))
    }

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mock `.enroll` + `.ring`: 104pt ring, 25pt numeral, 9.5pt label.
            JCard {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 8)
                            .frame(width: 104, height: 104)
                        Circle()
                            .trim(from: 0, to: frac)
                            .stroke(appState.voiceProfileReady ? JColor.ok : JColor.accent,
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 104, height: 104)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.8), value: frac)
                        VStack(spacing: 5) {
                            Text("\(collected)")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(JColor.ink)
                            Text("of \(target)")
                                .font(.system(size: 9.5, weight: .medium))
                                .tracking(0.9)
                                .foregroundStyle(JColor.ink4)
                        }
                    }
                    .padding(.top, 5)
                    .padding(.bottom, 14)

                    HStack(spacing: 8) {
                        statusChip
                        Text(appState.lastVoiceSimilarity > 0
                             ? "Last match \(Int(appState.lastVoiceSimilarity * 100))%"
                             : "\(appState.enrollmentPhrases.count) phrases")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(JColor.ink4)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            JLabel(text: "Capture log")
                .padding(.top, 22)

            JCard(flush: true) {
                VStack(spacing: 1) {
                    ForEach(Array(appState.enrollmentPhrases.enumerated()), id: \.offset) { idx, phrase in
                        let done = idx < appState.enrollmentIndex
                        HStack(spacing: 9) {
                            ZStack {
                                Circle()
                                    .fill(done ? JColor.okSoft : JColor.inset)
                                    .frame(width: 15, height: 15)
                                if done {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(JColor.ok)
                                }
                            }
                            Text(phrase)
                                .font(.system(size: 11.5))
                                .foregroundStyle(done ? JColor.ink2 : JColor.ink3)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 7)
                    }
                }
                .padding(.vertical, 5)
            }
            .padding(.top, 9)

            JLabel(text: "Actions")
                .padding(.top, 22)

            HStack(spacing: 8) {
                Button {
                    appState.startEnrollment()
                } label: {
                    Label("Enroll", systemImage: "play.fill")
                }
                .disabled(appState.enrollmentActive)
                .jButton(intent: .primary)
                .help("Starts the mic and begins enrollment — no listening session needed")

                Button {
                    appState.retrainVoiceProfile()
                } label: {
                    Label("Retrain", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(appState.enrollmentActive)
                .jButton()
                .help("Deletes ALL stored voice samples, then starts a fresh enrollment so only the new samples are used")
            }
            .padding(.top, 9)

            HStack(spacing: 8) {
                Button {
                    appState.startEnrollment(resetStore: false)
                } label: {
                    Label("Add samples", systemImage: "plus")
                }
                .disabled(appState.enrollmentActive || !appState.enrollmentCompleted)
                .jButton()

                Button {
                    appState.resetVoiceProfile()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appState.enrollmentActive)
                .jButton(intent: .danger)
                .help("Clear stored voice embeddings (POST /reset) without starting a new enrollment")
            }
            .padding(.top, 8)

            if appState.enrollmentActive {
                HStack(spacing: 8) {
                    Text("Say: “\(appState.currentEnrollmentPhrase)”")
                        .font(.system(size: 11))
                        .foregroundStyle(JColor.ink2)
                    Spacer(minLength: 8)
                    Button {
                        appState.stopEnrollment()
                    } label: {
                        Text("Stop")
                    }
                    .jButton(intent: .danger, size: .small)
                }
                .padding(.top, 9)
            } else {
                Text("Retrain wipes old samples first — verify against the new enrollment only.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(JColor.ink4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
    }

    private var statusChip: some View {
        if appState.voiceProfileReady {
            return AnyView(JChip(text: "Profile ready", kind: .ok))
        }
        if appState.enrollmentActive {
            return AnyView(JChip(text: "Training", kind: .warn))
        }
        return AnyView(JChip(text: "Not enrolled", kind: .neutral))
    }
}
