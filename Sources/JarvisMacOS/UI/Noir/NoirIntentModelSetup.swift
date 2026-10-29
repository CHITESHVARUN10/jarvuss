import SwiftUI

@MainActor
struct NoirIntentModelRow: View {
    @ObservedObject var model: IntentModelSetup
    let onOpen: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 15) {
                    Image(systemName: model.isInstalled ? "checkmark.circle" : "arrow.down.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(model.isInstalled ? NoirPalette.green : NoirPalette.muted)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Intent command model").font(.system(size: 12)).foregroundStyle(NoirPalette.text)
                        Text(model.isDownloading ? "Downloading… \(Int(model.progress * 100))%" : "On-device command understanding · approximately 206 MB.")
                            .font(.system(size: 11)).foregroundStyle(NoirPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    NoirTag(text: model.isDownloading ? "Downloading" : model.isBusy ? "Checking" : model.updateAvailable ? "Update available" : model.isInstalled ? "Installed" : "Optional",
                            kind: model.isInstalled ? .green : .neutral)
                }
                .padding(.leading, 19)
                .padding(.trailing, 12)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NoirIconButton(icon: "arrow.clockwise", help: "Check for intent model updates") { model.checkForUpdates() }
                .disabled(model.isBusy)
                .padding(.trailing, 19)
        }
        .overlay(alignment: .top) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
    }
}

@MainActor
struct NoirIntentModelDetail: View {
    @ObservedObject var model: IntentModelSetup
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This small model helps Jarvis understand commands locally. It is separate from Whisper transcription and the Ollama model. A Hugging Face account is not required.")
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(NoirPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Installed version") {
                        Text(model.installedVersion ?? "Not installed").font(.system(size: 12, design: .monospaced)).foregroundStyle(NoirPalette.secondary)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Latest release") {
                        Text(model.latestVersion ?? "Not checked").font(.system(size: 12, design: .monospaced)).foregroundStyle(NoirPalette.secondary)
                    }
                }
            }
            if model.isDownloading {
                ProgressView(value: model.progress).tint(NoirPalette.accent)
                    .accessibilityLabel("Intent model download")
                    .accessibilityValue("\(Int(model.progress * 100)) percent")
            }
            Text(model.message).font(.system(size: 11)).foregroundStyle(NoirPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = model.runtimeWarning {
                Text(warning).font(.system(size: 11)).foregroundStyle(NoirPalette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !model.isInstalled || model.updateAvailable {
                    Button(model.isInstalled ? "Update intent model" : "Download intent model") { model.installLatest() }
                        .buttonStyle(NoirButtonStyle(intent: .primary)).disabled(model.isBusy)
                }
                Button("Check for updates") { model.checkForUpdates() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet)).disabled(model.isBusy)
                if model.runtimeWarning != nil && !model.isBusy {
                    Button("Download again") { model.installLatest(force: true) }.buttonStyle(NoirButtonStyle(intent: .quiet))
                }
                if model.isBusy {
                    Button("Cancel") { model.cancel() }.buttonStyle(NoirButtonStyle(intent: .quiet))
                }
            }
            Text("Downloads are verified before activation. A failed update keeps your working model. Native commands and dictation remain available without this model.")
                .font(.system(size: 11)).foregroundStyle(NoirPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if model.lastChecked == nil { model.checkForUpdates() } }
        .task {
            while !Task.isCancelled {
                await model.refreshRuntimeStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}
