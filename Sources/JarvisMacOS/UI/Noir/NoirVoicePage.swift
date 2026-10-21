import SwiftUI

// MARK: - Voice profile

struct NoirVoicePage: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var toasts: ToastCenter

    @State private var showPreferences = false
    @State private var confirmRetrain = false
    @State private var confirmClear = false

    private var collected: Int { appState.backendEnrollmentSampleCount }
    private var target: Int { appState.voiceEnrollmentSampleTarget }
    private var ready: Bool { appState.voiceProfileReady }
    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(collected) / Double(target))
    }

    var body: some View {
        NoirPage(
            eyebrow: "Recognition, made personal",
            title: "A voice that’s yours.",
            sub: "Teach Jarvis to recognize you before it carries out a command."
        ) {
            profileCard

            NoirSectionHeading(
                title: "Voice samples",
                trailing: AnyView(
                    Text("\(appState.enrollmentPhrases.count) phrases · \(appState.enrollmentRequiredMatchesPerPhrase) samples each")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NoirPalette.muted)
                )
            )

            NoirCard(padded: true) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 20, alignment: .leading),
                        GridItem(.flexible(), spacing: 20, alignment: .leading)
                    ],
                    spacing: 0
                ) {
                    ForEach(Array(appState.enrollmentPhrases.enumerated()), id: \.offset) { index, phrase in
                        phraseRow(phrase: phrase, index: index)
                    }
                }
            }

            HStack(spacing: 8) {
                enrollmentButtons
            }
            .padding(.top, 20)

            if appState.enrollmentActive {
                HStack(spacing: 8) {
                    Text("Say: “\(appState.currentEnrollmentPhrase)”")
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.secondary)
                    Spacer(minLength: 8)
                    Button("Stop") { appState.stopEnrollment() }
                        .buttonStyle(NoirButtonStyle(intent: .danger, small: true))
                }
                .padding(.top, 12)
            } else {
                Text("Retraining replaces existing samples. Adding samples keeps your current profile.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.muted)
                    .padding(.top, 15)
            }

            NoirSectionHeading(
                title: "Verification",
                trailing: AnyView(
                    NoirIconButton(icon: "slider.horizontal.3", help: "Open preferences") {
                        showPreferences = true
                    }
                )
            )

            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(
                        title: "Verify action commands",
                        sub: "Require a voice match when using ⌘⇧A."
                    ) {
                        NoirSwitch(isOn: $appState.actionPillRequiresVerify)
                    }
                    NoirDivider()
                    NoirSettingRow(
                        title: "Verify live mode",
                        sub: "Require a voice match after the wake word."
                    ) {
                        NoirSwitch(isOn: $appState.voiceModeRequiresVerify)
                    }
                    NoirDivider()
                    NoirSettingRow(
                        title: "Similarity threshold",
                        sub: "The minimum match required to execute."
                    ) {
                        Text(String(format: "%.2f", appState.voiceVerifyThreshold))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(NoirPalette.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showPreferences) {
            AssistantPreferencesSheet(appState: appState)
                .environmentObject(toasts)
        }
        .alert("Retrain your voice?", isPresented: $confirmRetrain) {
            Button("Cancel", role: .cancel) {}
            Button("Retrain", role: .destructive) {
                appState.retrainVoiceProfile()
                toasts.show("Fresh enrollment started — old samples will be replaced.")
            }
        } message: {
            Text("Your existing samples will be replaced with a fresh enrollment.")
        }
        .alert("Clear your voice profile?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear profile", role: .destructive) {
                appState.resetVoiceProfile()
                toasts.show("Voice profile cleared.")
            }
        } message: {
            Text("Your stored voice samples will be removed and hands-free mode will turn off.")
        }
    }

    // MARK: Profile card

    private var profileCard: some View {
        NoirCard(padded: true) {
            HStack(spacing: 26) {
                ring

                VStack(alignment: .leading, spacing: 0) {
                    Text(profileTitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(NoirPalette.text)

                    NoirTag(
                        text: profileTag,
                        kind: ready ? .green : (appState.enrollmentActive ? .amber : .accent),
                        icon: ready ? "checkmark" : "mic"
                    )
                    .padding(.top, 9)

                    Text(profileText)
                        .font(.system(size: 11))
                        .lineSpacing(4)
                        .foregroundStyle(NoirPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    if appState.lastVoiceSimilarity > 0 {
                        Text("Last match \(Int(appState.lastVoiceSimilarity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NoirPalette.muted)
                            .padding(.top, 10)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.043), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ready ? NoirPalette.green : NoirPalette.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: progress)
            VStack(spacing: 4) {
                Text("\(collected)")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(NoirPalette.text)
                Text("of \(target) samples")
                    .font(.system(size: 9))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(NoirPalette.muted)
            }
        }
        .frame(width: 112, height: 112)
    }

    private var profileTitle: String {
        if appState.enrollmentActive { return "Getting to know your voice" }
        return ready ? "Uniquely you." : "Let’s get to know you."
    }

    private var profileTag: String {
        if appState.enrollmentActive { return "Enrollment active" }
        return ready ? "Voice profile ready" : "Not enrolled"
    }

    private var profileText: String {
        if appState.enrollmentActive {
            return "Keep reading the phrases. Jarvis stores a speaker embedding on this Mac — never the recording."
        }
        if ready {
            return "Your voice profile is ready for verified commands and hands-free follow-ups."
        }
        return "Read \(appState.enrollmentPhrases.count) phrases, with \(appState.enrollmentRequiredMatchesPerPhrase) samples per phrase, to build your voice profile."
    }

    // MARK: Phrase rows

    private func phraseRow(phrase: String, index: Int) -> some View {
        let done = collected >= (index + 1) * appState.enrollmentRequiredMatchesPerPhrase
        let current = appState.enrollmentActive && index == appState.enrollmentIndex
        return HStack(spacing: 8) {
            Image(systemName: done ? "checkmark" : "mic")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(done ? NoirPalette.green : (current ? NoirPalette.accent : NoirPalette.muted))
                .frame(width: 12)
            Text(phrase)
                .font(.system(size: 11))
                .foregroundStyle(current ? NoirPalette.text : NoirPalette.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var enrollmentButtons: some View {
        if appState.enrollmentActive {
            Button {
                appState.stopEnrollment()
            } label: {
                Label("Stop enrollment", systemImage: "stop.fill")
            }
            .buttonStyle(NoirButtonStyle(intent: .danger))
        } else if ready {
            Button {
                appState.startEnrollment(resetStore: false)
                toasts.show("Listening for new samples.")
            } label: {
                Label("Add samples", systemImage: "mic")
            }
            .buttonStyle(NoirButtonStyle(intent: .primary))
        } else {
            Button {
                appState.startEnrollment()
                toasts.show("Enrollment started.")
            } label: {
                Label("Start enrollment", systemImage: "mic")
            }
            .buttonStyle(NoirButtonStyle(intent: .primary))
        }

        Button {
            confirmRetrain = true
        } label: {
            Label("Retrain profile", systemImage: "arrow.clockwise")
        }
        .buttonStyle(NoirButtonStyle())

        Button {
            confirmClear = true
        } label: {
            Label("Clear profile", systemImage: "trash")
        }
        .buttonStyle(NoirButtonStyle(intent: .quiet))

        Spacer(minLength: 0)
    }
}
