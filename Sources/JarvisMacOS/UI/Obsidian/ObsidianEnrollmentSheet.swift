import SwiftUI

/// Only the current phrase is visible. UI progress reflects saved voice samples.
struct ObsidianEnrollmentSheet: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice enrollment").obsidianFont(size: 15, weight: .medium)
                Spacer()
                NoirIconButton(icon: "xmark", help: appState.enrollmentActive ? "Pause enrollment" : "Close") { close() }
                    .disabled(appState.enrollmentSavingSample)
            }.padding(.bottom, 22)
            if appState.enrollmentPreparing {
                ProgressView("Preparing microphone and voice storage…").obsidianFont(size: 12)
                    .frame(maxWidth: .infinity).padding(.vertical, 55)
            } else if appState.enrollmentActive {
                activePhrase
            } else if appState.enrollmentCompleted && appState.voiceProfileReady {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle").obsidianFont(size: 35).foregroundStyle(NoirPalette.green)
                    Text("You’re all set.").obsidianFont(size: 23, weight: .medium)
                    Text("Your voice profile is ready.").obsidianFont(size: 12).foregroundStyle(NoirPalette.muted)
                    Text("\(appState.enrollmentPhrases.count) phrases · \(appState.backendEnrollmentSampleCount) saved samples")
                        .obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
                Button("Done") { dismiss() }.buttonStyle(NoirButtonStyle(intent: .primary))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 20)
            } else {
                Text(appState.enrollmentMessage.isEmpty ? appState.voiceVerificationStatus : appState.enrollmentMessage)
                    .obsidianFont(size: 12).foregroundStyle(NoirPalette.secondary).padding(.vertical, 25)
                HStack {
                    Button("Close") { dismiss() }.buttonStyle(NoirButtonStyle())
                    Spacer()
                    Button(appState.enrollmentPaused ? "Resume enrollment" : "Try again") {
                        if appState.enrollmentPaused { appState.resumeEnrollment() } else { appState.startEnrollment() }
                    }.buttonStyle(NoirButtonStyle(intent: .primary))
                }
            }
        }
        .padding(26).frame(width: 500)
        .foregroundStyle(NoirPalette.text).background(GlassPanelBackground()).preferredColorScheme(.dark)
    }

    private var activePhrase: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speak naturally, at your usual distance from the microphone.")
                .obsidianFont(size: 12).foregroundStyle(NoirPalette.muted).lineSpacing(4)
            HStack {
                Text("Phrase \(appState.enrollmentIndex + 1) of \(appState.enrollmentPhrases.count)")
                Spacer()
                Text("\(appState.enrollmentMatchedCount) / \(appState.voiceEnrollmentSampleTarget) samples")
            }.obsidianFont(size: 11).foregroundStyle(NoirPalette.muted).padding(.top, 25)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(NoirPalette.line)
                    Capsule().fill(NoirPalette.accent).frame(width: geometry.size.width * min(1,
                        CGFloat(appState.enrollmentMatchedCount) / CGFloat(max(1, appState.voiceEnrollmentSampleTarget))))
                }
            }.frame(height: 3).padding(.top, 9).accessibilityElement(children: .ignore)
                .accessibilityLabel("Enrollment progress")
                .accessibilityValue("\(appState.enrollmentMatchedCount) of \(appState.voiceEnrollmentSampleTarget) samples saved")
            VStack(spacing: 18) {
                Text("READ THIS PHRASE ALOUD").obsidianFont(size: 10, weight: .medium).tracking(1.3).foregroundStyle(NoirPalette.muted)
                Text(appState.currentEnrollmentPhrase).obsidianFont(size: 24, weight: .medium)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ForEach(0..<appState.enrollmentRequiredMatchesPerPhrase, id: \.self) { index in
                        Circle().fill(index < appState.enrollmentCurrentPhraseMatchCount ? NoirPalette.accent : NoirPalette.raised)
                            .overlay(Circle().strokeBorder(NoirPalette.lineStrong, lineWidth: 1)).frame(width: 8, height: 8)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(appState.enrollmentCurrentPhraseMatchCount) of \(appState.enrollmentRequiredMatchesPerPhrase) samples saved")
                Text(appState.enrollmentMessage).obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }.frame(maxWidth: .infinity).padding(.vertical, 33)
            if appState.enrollmentAwaitingNextPhrase {
                Button("Next phrase") { appState.advanceEnrollmentPhrase() }
                    .buttonStyle(NoirButtonStyle(intent: .primary)).frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    if appState.enrollmentSavingSample { ProgressView().controlSize(.small) }
                    else { Image(systemName: "mic.fill").foregroundStyle(NoirPalette.accent) }
                    Text(appState.enrollmentSavingSample ? "Saving your sample…" : "Listening · repeat this phrase three times")
                        .obsidianFont(size: 12).foregroundStyle(NoirPalette.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            NoirDivider().padding(.top, 24)
            HStack {
                Button("Pause enrollment") { close() }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    .disabled(appState.enrollmentSavingSample)
                Spacer()
                Label("On this Mac", systemImage: "lock").obsidianFont(size: 10).foregroundStyle(NoirPalette.muted)
            }.padding(.top, 16)
        }
    }

    private func close() {
        if appState.enrollmentActive { appState.stopEnrollment() }
        dismiss()
    }
}
