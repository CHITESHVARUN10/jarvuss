import SwiftUI

struct NoirVoicePage: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var toasts: ToastCenter
    @State private var showEnrollment = false
    @State private var confirmRetrain = false
    @State private var confirmClear = false
    @AppStorage("jarvis.liveSpeech.engine") private var liveSpeechEngine = "apple"
    @AppStorage("jarvis.liveSpeech.locale") private var liveSpeechLocale = "en-IN"

    var body: some View {
        NoirPage(eyebrow: "Preferences", title: "Voice & speech",
                 sub: "Your voice profile, recognition, and dictation in one place.") {
            profileCard
            HStack(spacing: 24) {
                ForEach(VoiceSettingsTab.allCases, id: \.self) { tab in
                    Button { appState.voiceSettingsTab = tab } label: {
                        Text(tab.rawValue).obsidianFont(size: 12, weight: .medium)
                            .foregroundStyle(appState.voiceSettingsTab == tab ? NoirPalette.text : NoirPalette.muted)
                            .frame(height: 44)
                            .overlay(alignment: .bottom) {
                                if appState.voiceSettingsTab == tab { Rectangle().fill(NoirPalette.accent).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(appState.voiceSettingsTab == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
                .padding(.top, 22)

            if appState.voiceSettingsTab == .dictation {
                ObsidianDictationPreferences()
            } else {
                recognitionSettings
            }
        }
        .sheet(isPresented: $showEnrollment, onDismiss: {
            if appState.enrollmentActive { appState.stopEnrollment() }
        }) {
            ObsidianEnrollmentSheet(appState: appState)
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
        }
        .onAppear { if appState.enrollmentActive { showEnrollment = true } }
        .onChange(of: appState.enrollmentActive) { _, active in if active { showEnrollment = true } }
        .alert("Retrain your voice?", isPresented: $confirmRetrain) {
            Button("Cancel", role: .cancel) {}
            Button("Start fresh", role: .destructive) { appState.retrainVoiceProfile(); showEnrollment = true }
        } message: {
            Text("Your existing samples will be replaced with a new guided session. You’ll read one phrase at a time, three times each.")
        }
        .alert("Clear your voice profile?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear profile", role: .destructive) { appState.resetVoiceProfile() }
        } message: {
            Text("Your voice profile and unfinished enrollment will be removed. Hands-free mode will turn off.")
        }
    }

    private var profileCard: some View {
        NoirCard(padded: true) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: appState.voiceProfileReady ? "checkmark" : "waveform")
                    .obsidianFont(size: 20).foregroundStyle(appState.voiceProfileReady ? NoirPalette.green : NoirPalette.accent)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12).fill(NoirPalette.accentSoft))
                VStack(alignment: .leading, spacing: 0) {
                    Text(appState.voiceProfileReady ? "Your voice, recognized." : "Make Jarvis familiar with your voice.")
                        .obsidianFont(size: 16, weight: .medium).foregroundStyle(NoirPalette.text)
                    NoirTag(text: profileStatus, kind: appState.voiceProfileReady ? .green : .accent)
                        .padding(.top, 9)
                    Text(appState.voiceProfileReady
                         ? "Your profile is ready for verified commands. Retrain whenever your voice or microphone changes."
                         : "A guided session, one phrase at a time. Read each phrase three times; Jarvis takes you through the rest.")
                        .obsidianFont(size: 12).foregroundStyle(NoirPalette.muted).lineSpacing(4).padding(.top, 12)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { profileActions }
                        VStack(alignment: .leading, spacing: 12) { profileActions }
                    }.padding(.top, 20).disabled(appState.voiceProfileResetting)
                    if appState.voiceProfileResetting {
                        Text("Clearing voice profile…").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted).padding(.top, 12)
                    }
                    if let error = appState.voiceProfileError {
                        Text(error).obsidianFont(size: 11).foregroundStyle(NoirPalette.orange).padding(.top, 12)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var profileStatus: String {
        if appState.enrollmentActive { return "Enrollment in progress" }
        if appState.enrollmentPaused { return "Enrollment paused" }
        if appState.voiceProfileReady { return "Voice profile ready" }
        return "No voice profile yet"
    }

    @ViewBuilder private var profileActions: some View {
        Button(appState.enrollmentActive ? "Continue enrollment" : appState.enrollmentPaused ? "Resume enrollment" : "Start enrollment") {
            if appState.enrollmentPaused { appState.resumeEnrollment() }
            else if !appState.enrollmentActive { appState.startEnrollment() }
            showEnrollment = true
        }.buttonStyle(NoirButtonStyle(intent: .primary))
            .disabled(appState.voiceProfileReady && !appState.enrollmentActive)
            .help(appState.voiceProfileReady ? "Your profile is ready. Use Retrain profile to replace its samples." : "Start the guided voice session")
        Button("Retrain profile") { confirmRetrain = true }
            .buttonStyle(NoirButtonStyle()).disabled(appState.enrollmentActive || appState.backendEnrollmentSampleCount == 0)
        Button("Clear profile") { confirmClear = true }
            .buttonStyle(NoirButtonStyle(intent: .quiet))
            .disabled(appState.enrollmentActive || (appState.backendEnrollmentSampleCount == 0 && !appState.enrollmentPaused))
    }

    private var recognitionSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Recognition")
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Live speech", sub: "Applies when you restart listening.") {
                        Picker("Live speech recognizer", selection: $liveSpeechEngine) {
                            Text("Apple · on device").tag("apple")
                            Text("Whisper · local fallback").tag("whisper")
                        }.labelsHidden().frame(width: 215)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Language", sub: "For example en-IN, en-US, or en-GB.") {
                        TextField("Speech language", text: $liveSpeechLocale).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Shortcut dictation", sub: "Speech recognition runs on this Mac.") {
                        Text("Whisper Turbo").obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary)
                    }
                }
            }
            NoirSectionHeading(title: "Voice verification")
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Action commands", sub: "Verify your voice before carrying out a command with ⌘⇧A.") {
                        NoirSwitch(isOn: $appState.actionPillRequiresVerify)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Live mode", sub: "Verify your voice after the wake word.") {
                        NoirSwitch(isOn: $appState.voiceModeRequiresVerify)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Similarity threshold", sub: "The minimum voice match required to execute.") {
                        Text(String(format: "%.2f", appState.voiceVerifyThreshold)).obsidianFont(size: 12, design: .monospaced)
                            .foregroundStyle(NoirPalette.secondary)
                    }
                }
            }
            Label("Your voice profile stays on this Mac.", systemImage: "lock")
                .obsidianFont(size: 11).foregroundStyle(NoirPalette.muted).padding(.top, 15)
        }
    }
}
