import SwiftUI
import AppKit

// MARK: - About

struct NoirAboutPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var tests = CommandTestHarness.shared

    var body: some View {
        NoirPage(
            eyebrow: "Thoughtfully at your service",
            title: "Made for your Mac.",
            sub: "An assistant that fits into your workspace, and gets out of your way."
        ) {
            aboutMark

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(title: "Application")
                    NoirCard {
                        VStack(spacing: 0) {
                            fact("Version", versionText)
                            NoirDivider()
                            fact("Source build", DiagnosticBuild.current.revision)
                            NoirDivider()
                            fact("Binary ID", String(DiagnosticBuild.current.executableUUID.prefix(8)))
                            NoirDivider()
                            fact("Architecture", "arm64")
                            NoirDivider()
                            fact("Speech engine", "Whisper large-v3-turbo")
                            NoirDivider()
                            fact("Intent router", "t5-small")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(title: "Keyboard shortcuts")
                    NoirCard {
                        VStack(spacing: 0) {
                            shortcut("Dictate anywhere", keys: "⌘ ⇧ D")
                            NoirDivider()
                            shortcut("Run a voice command", keys: "⌘ ⇧ A")
                            NoirDivider()
                            shortcut("Restore display visibility", keys: "⌘ ⇧ R")
                            NoirDivider()
                            shortcut("Toggle verification", keys: "⌘ O")
                            NoirDivider()
                            shortcut("Submit typed command", keys: "Return")
                        }
                    }
                }
            }

            NoirSectionHeading(title: "Engine")
            NoirCard {
                NoirSettingRow(
                    title: "Rust pipeline",
                    sub: "Use the Rust core for command understanding."
                ) {
                    NoirSwitch(isOn: $appState.useRustPipeline)
                }
            }

            NoirSectionHeading(title: "Diagnostics")
            NoirCard(padded: true) {
                Text("Session logs and macOS crash reports stay on this Mac. Runtime logs can include dictated text and commands.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.secondary)
                HStack(spacing: 12) {
                    Button("Open diagnostic logs") {
                        NSWorkspace.shared.open(CrashDiagnostics.shared.directory)
                    }
                    Button("Copy crash summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CrashDiagnostics.shared.summary, forType: .string)
                    }
                }
                .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                .padding(.top, 12)
            }

            NoirSectionHeading(title: "Command testing")
            NoirCard(padded: true) {
                Text("Send text through the command pipeline without recording. The local runner shows plans, execution results, and your pass/fail notes. Live execution performs real actions on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(NoirPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(tests.isRunning ? "Open test runner" : "Start test runner") {
                        Task { await tests.start(app: appState) }
                    }
                    .buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                    if tests.isRunning {
                        Button("Stop test mode") { tests.stop() }
                            .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    }
                }.padding(.top, 12)
                Text(tests.message).font(.system(size: 10)).foregroundStyle(NoirPalette.muted).padding(.top, 8)
            }

            NoirSectionHeading(title: "Privacy")
            NoirCard(padded: true) {
                Text("Speech is transcribed on your Mac. Your voice samples stay in a local speaker profile, and command history lives in the event storage you configure.")
                    .font(.system(size: 11))
                    .lineSpacing(5)
                    .foregroundStyle(NoirPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Spotify and PostgreSQL talk only to the services you connect. Nothing is sent to a Jarvis account, because there isn’t one.")
                    .font(.system(size: 11))
                    .lineSpacing(5)
                    .foregroundStyle(NoirPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    private var aboutMark: some View {
        VStack(spacing: 17) {
            NoirBrandMark(size: 66)
            Text("JARVIS")
                .font(.system(size: 21, weight: .medium))
                .tracking(4)
                .foregroundStyle(NoirPalette.text)
            Text("A little more possible.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        NoirSettingRow(title: title) {
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NoirPalette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        NoirSettingRow(title: title) {
            Text(keys)
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(NoirPalette.lineStrong, lineWidth: 1)
                )
        }
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
