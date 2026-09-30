import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState

    private var greeting: String {
        switch appState.assistantState {
        case .idle:       return "I'm offline. Tap mic to start."
        case .listening:  return "How can I help, Sir?"
        case .recording:  return "I'm listening..."
        case .processing: return "Let me think..."
        case .executing:  return "On it..."
        }
    }

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────
            JarvisColor.canvas
                .ignoresSafeArea()

            // ── Layout ──────────────────────────────────────────────
            HStack(spacing: 0) {

                // Left control panel (sidebar)
                ControlPanelView(appState: appState)

                // Main canvas
                VStack(spacing: 0) {

                    // Top bar
                    topBar
                        .frame(height: 54)

                    Spacer()

                    // Central interaction area
                    VStack(spacing: 28) {
                        // Greeting
                        Text(greeting)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(JarvisColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .animation(.easeOut(duration: 0.3), value: appState.assistantState)

                        // Mic orb
                        MicOrbView(
                            assistantState: appState.assistantState,
                            audioLevel: appState.audioLevelNormalized,
                            micActive: appState.micActive,
                            sessionState: appState.voiceSessionState
                        ) {
                            if appState.micActive {
                                appState.stopMicrophone()
                            } else {
                                Task { await appState.startMicrophone() }
                            }
                        }

                        // Transcript
                        TranscriptView(
                            lastSpeech: appState.lastRecognizedSpeech,
                            currentCommand: appState.currentCommand,
                            audioLevel: appState.audioLevelNormalized,
                            state: appState.assistantState
                        )
                        .frame(maxWidth: 480)
                    }
                    .padding(.horizontal, 40)

                    Spacer()

                    // Bottom log drawer
                    EventLogDrawer(appState: appState)
                }
                .background(SubtleGridView())
            }

            // ── Popup overlay ────────────────────────────────────────
            if appState.popupManager.isVisible {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                PopupView(manager: appState.popupManager)
                    .frame(maxWidth: 360)
            }
        }
        .frame(minWidth: 1020, minHeight: 680)
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack(spacing: 14) {
            Text("Jarvis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JarvisColor.textPrimary)

            Rectangle()
                .frame(width: 1, height: 16)
                .foregroundStyle(JarvisColor.hairline)

            StatusBadge(state: appState.assistantState, micActive: appState.micActive, sessionState: appState.voiceSessionState)

            Spacer()

            micStatusBadge
            backendStatusBadge
        }
        .padding(.horizontal, 24)
        .background(JarvisColor.canvas)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(JarvisColor.hairline),
            alignment: .bottom
        )
    }

    private var micStatusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: appState.micActive ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 11))
                .foregroundStyle(appState.micActive ? JarvisColor.ok : JarvisColor.textTertiary)
            Text(appState.micActive ? "Active" : "Offline")
                .font(JarvisType.dataSmall)
                .foregroundStyle(appState.micActive ? JarvisColor.ok : JarvisColor.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(JarvisColor.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(JarvisColor.hairline, lineWidth: 1))
    }

    private var backendStatusBadge: some View {
        let isHealthy = appState.backendStartupError == nil

        return HStack(spacing: 5) {
            Image(systemName: isHealthy ? "network" : "network.slash")
                .font(.system(size: 11))
                .foregroundStyle(isHealthy ? JarvisColor.textSecondary : JarvisColor.danger)
            Text(appState.backendStatus)
                .font(JarvisType.dataSmall)
                .foregroundStyle(isHealthy ? JarvisColor.textSecondary : JarvisColor.danger)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(JarvisColor.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(JarvisColor.hairline, lineWidth: 1))
    }
}
