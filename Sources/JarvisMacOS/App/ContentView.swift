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
            backgroundLayer

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
                            .font(.system(size: 34, weight: .semibold, design: .default))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .multilineTextAlignment(.center)
                            .animation(.easeOut(duration: 0.3), value: appState.assistantState)

                        // Mic orb
                        MicOrbView(
                            assistantState: appState.assistantState,
                            audioLevel: appState.audioLevelNormalized,
                            micActive: appState.micActive
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
        .frame(minWidth: 960, minHeight: 680)
    }

    // MARK: - Background
    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.075)

            // Ambient blobs
            Circle()
                .fill(Color(red: 0.35, green: 0.35, blue: 0.90).opacity(0.08))
                .frame(width: 600, height: 600)
                .blur(radius: 100)
                .offset(x: -200, y: -180)

            Circle()
                .fill(Color(red: 0.60, green: 0.25, blue: 0.90).opacity(0.05))
                .frame(width: 500, height: 500)
                .blur(radius: 90)
                .offset(x: 300, y: 200)
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack(spacing: 14) {
            // App identity
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.55, green: 0.55, blue: 1.0),
                                Color(red: 0.75, green: 0.40, blue: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(red: 0.55, green: 0.55, blue: 1.0).opacity(0.8), radius: 6)

                Text("JARVIS")
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(4)
                    .foregroundStyle(Color.white.opacity(0.75))
            }

            Rectangle()
                .frame(width: 1, height: 16)
                .foregroundStyle(Color.white.opacity(0.10))

            StatusBadge(state: appState.assistantState, micActive: appState.micActive)

            Spacer()

            // Mic indicator
            HStack(spacing: 5) {
                Image(systemName: appState.micActive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(appState.micActive
                        ? Color(red: 0.35, green: 0.90, blue: 0.65)
                        : Color.white.opacity(0.25))
                Text(appState.micActive ? "ACTIVE" : "OFFLINE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(appState.micActive
                        ? Color(red: 0.35, green: 0.90, blue: 0.65).opacity(0.8)
                        : Color.white.opacity(0.25))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8))
        }
        .padding(.horizontal, 24)
        .background(Color.black.opacity(0.20))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.06)),
            alignment: .bottom
        )
    }
}