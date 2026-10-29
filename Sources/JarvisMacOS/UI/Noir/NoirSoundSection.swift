import SwiftUI

@MainActor
struct NoirSoundSection: View {
    @StateObject private var sound: SystemSoundModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var volume: Double = 0
    @State private var isEditing = false
    @State private var editingOutput: SystemAudioOutput?
    @State private var keyboardCommit: Task<Void, Never>?

    init(model: SystemSoundModel? = nil) {
        _sound = StateObject(wrappedValue: model ?? SystemSoundModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Sound", trailing: AnyView(
                NoirIconButton(icon: "arrow.clockwise", help: "Refresh the current audio output and volume") {
                    Task { await sound.refresh() }
                }
                .disabled(sound.isRefreshing || sound.isApplying)
            ))
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Output", sub: sound.snapshot?.output?.name ?? (sound.snapshot == nil ? "Reading current output…" : "No available output")) {
                        Button("Sound settings") { _ = SystemSettingsPane.sound.open() }
                            .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                            .help("Choose the output in macOS Sound settings")
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Volume", sub: "Adjust the selected macOS output.") {
                        if let level = sound.snapshot?.level {
                            HStack(spacing: 12) {
                                Slider(value: sliderValue, in: 0...100) { editing in
                                    keyboardCommit?.cancel()
                                    isEditing = editing
                                    if editing {
                                        editingOutput = sound.snapshot?.output
                                    } else {
                                        let target = Int(volume.rounded())
                                        let output = editingOutput ?? sound.snapshot?.output
                                        editingOutput = nil
                                        Task { await sound.apply(.setLevel(target), to: output) }
                                    }
                                }
                                .tint(NoirPalette.accent)
                                .frame(width: 190)
                                .accessibilityLabel("Output volume")
                                .accessibilityValue("\(Int(volume.rounded())) percent")
                                .disabled(sound.snapshot?.canSetVolume != true || sound.isApplying)

                                Text("\(Int((isEditing ? volume : Double(level) * 100).rounded()))%")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(NoirPalette.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        } else {
                            Text(sound.snapshot == nil ? "Reading…" : "Unavailable")
                                .font(.system(size: 12))
                                .foregroundStyle(NoirPalette.muted)
                        }
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Mute", sub: muteDescription) {
                        let muted = sound.snapshot?.isMuted == true
                        Button {
                            let output = sound.snapshot?.output
                            Task { await sound.apply(muted ? .unmute : .mute, to: output) }
                        } label: {
                            Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.wave.2" : "speaker.slash")
                        }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                        .disabled(sound.isApplying || !(muted ? sound.snapshot?.canUnmute == true : sound.snapshot?.canMute == true))
                    }
                }
            }
            if let result = sound.lastResult, !result.success {
                Text(result.message)
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityLabel("Sound control error: \(result.message)")
            }
            if let detail = sound.snapshot?.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Text("Try “increase volume by ten percent” or “set volume to forty percent”.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .onAppear { syncVolume() }
        .onDisappear { keyboardCommit?.cancel() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await sound.refresh()
                syncVolume()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
        .onChange(of: sound.snapshot?.level) { _, _ in syncVolume() }
        .onChange(of: sound.snapshot?.output) { _, _ in syncVolume() }
        .onChange(of: sound.isApplying) { _, applying in if !applying { syncVolume() } }
    }

    private var muteDescription: String {
        if sound.isApplying { return "Applying audio change…" }
        guard let muted = sound.snapshot?.isMuted else { return "Mute state unavailable." }
        return muted ? "This output is muted." : "This output is not muted."
    }

    /// Native slider keyboard/accessibility changes may not bracket a mouse
    /// drag. Commit those changes too, coalescing held arrow keys. Programmatic
    /// refreshes update `volume` directly and never enter this setter.
    private var sliderValue: Binding<Double> {
        Binding(get: { volume }, set: { value in
            volume = value
            guard !isEditing else { return }
            keyboardCommit?.cancel()
            let output = sound.snapshot?.output
            let target = Int(value.rounded())
            keyboardCommit = Task {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
                await sound.apply(.setLevel(target), to: output)
            }
        })
    }

    private func syncVolume() {
        guard !isEditing, let level = sound.snapshot?.level else { return }
        volume = Double(level) * 100
    }
}
