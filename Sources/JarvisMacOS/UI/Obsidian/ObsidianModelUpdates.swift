import SwiftUI

/// A compact home for the same verified updater used by Setup.
struct ObsidianModelUpdates: View {
    @ObservedObject var model: IntentModelSetup
    @State private var detailsOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Model updates", minHeight: 30)
            NoirCard(padded: true) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Intent command model").obsidianFont(size: 12, weight: .medium).foregroundStyle(NoirPalette.text)
                        Text("Installed: \(model.installedVersion ?? "Not installed")")
                            .obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                        if let latest = model.latestVersion {
                            Text("Latest: \(latest)").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Details") { detailsOpen = true }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                }
                if model.isDownloading {
                    ProgressView(value: model.progress).tint(NoirPalette.accent).padding(.top, 14)
                        .accessibilityLabel("Intent model download")
                        .accessibilityValue("\(Int(model.progress * 100)) percent")
                }
                Text(model.message).obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 13)
                if let warning = model.runtimeWarning {
                    Text(warning).obsidianFont(size: 11).foregroundStyle(NoirPalette.orange).padding(.top, 8)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }.padding(.top, 16)
                if let checked = model.lastChecked {
                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .obsidianFont(size: 10).foregroundStyle(NoirPalette.muted).padding(.top, 12)
                }
            }
        }
        .task { await model.refreshInstallation() }
        .sheet(isPresented: $detailsOpen) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Intent command model").obsidianFont(size: 15, weight: .medium)
                    Spacer()
                    NoirIconButton(icon: "xmark", help: "Close model details") { detailsOpen = false }
                }
                ScrollView { NoirIntentModelDetail(model: model) }
                HStack { Spacer(); Button("Done") { detailsOpen = false }.buttonStyle(NoirButtonStyle(intent: .primary)) }
            }.padding(24).frame(width: 600, height: 570).foregroundStyle(NoirPalette.text)
                .background(GlassPanelBackground()).preferredColorScheme(.dark).presentationBackground(.clear)
        }
    }
    @ViewBuilder private var actions: some View {
        Button { model.checkForUpdates() } label: {
            Label(model.isBusy && !model.isDownloading ? "Checking…" : "Check for updates", systemImage: "arrow.clockwise")
        }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true)).disabled(model.isBusy)
        if model.updateAvailable || !model.isInstalled {
            Button(model.isInstalled ? "Update available · Install" : "Download model") { model.installLatest() }
                .buttonStyle(NoirButtonStyle(intent: .primary, small: true)).disabled(model.isBusy)
        }
        if model.isBusy {
            Button("Cancel") { model.cancel() }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
        }
    }
}
