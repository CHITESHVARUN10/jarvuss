import SwiftUI
import AppKit
import AVFoundation

// MARK: - Items

enum NoirSetupKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case whisper
    case ollama
    case postgres
    case backend
    case spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:    return "Microphone"
        case .accessibility: return "Accessibility"
        case .whisper:       return "Whisper speech model"
        case .ollama:        return "Ollama + AI model"
        case .postgres:      return "PostgreSQL"
        case .backend:       return "Python helper"
        case .spotify:       return "Spotify"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone:    return "For dictation and voice commands."
        case .accessibility: return "For inserting text at your cursor."
        case .whisper:       return "On-device transcription · approximately 1.5 GB."
        case .ollama:        return "For AI answers and command planning."
        case .postgres:      return "For activity history and usage insights."
        case .backend:       return "For voice authentication and integrations."
        case .spotify:       return "For voice-controlled music playback."
        }
    }

    var icon: String {
        switch self {
        case .microphone:    return "mic"
        case .accessibility: return "accessibility"
        case .whisper:       return "waveform"
        case .ollama:        return "sparkle"
        case .postgres:      return "cylinder"
        case .backend:       return "slider.horizontal.3"
        case .spotify:       return "music.note"
        }
    }
}

private struct SetupStatus {
    let text: String
    let kind: NoirTag.Kind
    let ready: Bool
}

// MARK: - Setup page

struct NoirSetupPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var dictation = DictationController.shared
    @EnvironmentObject private var toasts: ToastCenter

    @State private var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var ollamaInstalled = false
    @State private var postgresReachable = false
    @State private var activeItem: NoirSetupKind?

    var body: some View {
        NoirPage(
            eyebrow: "Make yourself at home",
            title: "A good place to begin.",
            sub: "Start with the essentials. Everything else can wait."
        ) {
            essentialsCard

            NoirSectionHeading(
                title: "Your setup checklist",
                trailing: AnyView(
                    NoirIconButton(icon: "arrow.clockwise", help: "Refresh checklist") {
                        Task { await refreshProbes() }
                    }
                )
            )

            NoirCard {
                VStack(spacing: 0) {
                    ForEach(Array(NoirSetupKind.allCases.enumerated()), id: \.element.id) { index, kind in
                        setupRow(kind, first: index == 0)
                    }
                }
            }

            HStack(spacing: 16) {
                Text("Optional steps are always available here.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 8)
                Button {
                    appState.setupCompleted = true
                    appState.activeSection = .assistant
                    toasts.show("Setup marked complete.")
                } label: {
                    HStack(spacing: 6) {
                        Text("Finish setup")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(NoirButtonStyle(intent: .primary))
            }
            .padding(.top, 23)
        }
        .task { await refreshProbes() }
        .sheet(item: $activeItem) { kind in
            SetupDetailSheet(appState: appState, kind: kind)
                .environmentObject(toasts)
        }
    }

    // MARK: Essentials

    private var essentialsCard: some View {
        NoirCard(padded: true) {
            HStack(spacing: 12) {
                Text(essentialsReady == 3 ? "Your essentials are ready" : "Finish the essentials")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NoirPalette.text)
                Spacer(minLength: 8)
                NoirTag(
                    text: essentialsReady == 3 ? "Ready to dictate" : "\(essentialsReady) of 3 ready",
                    kind: essentialsReady == 3 ? .green : .accent,
                    icon: essentialsReady == 3 ? "checkmark" : nil
                )
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.043))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(NoirPalette.accent)
                        .frame(width: proxy.size.width * CGFloat(essentialsReady) / 3)
                }
            }
            .frame(height: 3)
            .padding(.top, 18)

            Text("Microphone, accessibility, and the speech model are the only required steps.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 10)
        }
    }

    private var essentialsReady: Int {
        var count = 0
        if micAuthorized { count += 1 }
        if has_accessibility_permission() { count += 1 }
        if case .Ready = dictation.modelPhase { count += 1 }
        else if case .Inference = dictation.modelPhase { count += 1 }
        return count
    }

    // MARK: Rows

    private func setupRow(_ kind: NoirSetupKind, first: Bool) -> some View {
        let status = status(for: kind)
        return Button {
            activeItem = kind
        } label: {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(status.ready ? NoirPalette.green.opacity(0.035) : .clear)
                    Circle()
                        .strokeBorder(
                            status.ready ? NoirPalette.green.opacity(0.15) : NoirPalette.lineStrong,
                            lineWidth: 1
                        )
                    Image(systemName: status.ready ? "checkmark" : kind.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.ready ? NoirPalette.green : NoirPalette.muted)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.system(size: 12))
                        .foregroundStyle(NoirPalette.text)
                    Text(kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                }

                Spacer(minLength: 8)
                NoirTag(text: status.text, kind: status.kind)
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if !first {
                    Rectangle().fill(NoirPalette.line).frame(height: 1)
                }
            }
        }
        .buttonStyle(SetupRowButtonStyle())
    }

    private func status(for kind: NoirSetupKind) -> SetupStatus {
        switch kind {
        case .microphone:
            return SetupStatus(text: micAuthorized ? "Ready" : "Grant",
                               kind: micAuthorized ? .green : .amber,
                               ready: micAuthorized)
        case .accessibility:
            let granted = has_accessibility_permission()
            return SetupStatus(text: granted ? "Ready" : "Grant",
                               kind: granted ? .green : .amber,
                               ready: granted)
        case .whisper:
            let phase = dictation.modelPhase
            if case .Ready = phase { return SetupStatus(text: "Installed", kind: .green, ready: true) }
            if case .Inference = phase { return SetupStatus(text: "Installed", kind: .green, ready: true) }
            if case .NotInstalled = phase { return SetupStatus(text: "Missing", kind: .amber, ready: false) }
            if case .Error = phase { return SetupStatus(text: "Failed", kind: .red, ready: false) }
            return SetupStatus(text: "Working", kind: .accent, ready: false)
        case .ollama:
            if appState.ollamaReachable {
                return appState.ollamaModelInstalled
                    ? SetupStatus(text: "Ready", kind: .green, ready: true)
                    : SetupStatus(text: "Pull model", kind: .amber, ready: false)
            }
            return ollamaInstalled
                ? SetupStatus(text: "Start it", kind: .amber, ready: false)
                : SetupStatus(text: "Missing", kind: .amber, ready: false)
        case .postgres:
            if appState.postgresConfigured { return SetupStatus(text: "Configured", kind: .green, ready: true) }
            return postgresReachable
                ? SetupStatus(text: "Create DB", kind: .amber, ready: false)
                : SetupStatus(text: "Optional", kind: .neutral, ready: false)
        case .backend:
            let status = appState.backendStatus.lowercased()
            if status.contains("running") { return SetupStatus(text: "Running", kind: .green, ready: true) }
            if status.contains("fail") { return SetupStatus(text: "Failed", kind: .red, ready: false) }
            if status.contains("off") { return SetupStatus(text: "Off", kind: .neutral, ready: false) }
            return SetupStatus(text: appState.backendStatus, kind: .neutral, ready: false)
        case .spotify:
            return appState.spotifyLinked
                ? SetupStatus(text: "Connected", kind: .green, ready: true)
                : SetupStatus(text: "Optional", kind: .neutral, ready: false)
        }
    }

    private func refreshProbes() async {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let probes = await Task.detached(priority: .utility) {
            (OllamaSetup.isInstalled(), PostgresProvisioner.serverReachable())
        }.value
        ollamaInstalled = probes.0
        postgresReachable = probes.1
        await appState.refreshOllamaStatus()
        await appState.refreshPostgresStatus()
    }
}

private struct SetupRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.015) : .clear)
    }
}

// MARK: - Detail sheet

struct SetupDetailSheet: View {
    @ObservedObject var appState: AppState
    let kind: NoirSetupKind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter
    @ObservedObject private var dictation = DictationController.shared

    @State private var busy = false
    @State private var notice: String?
    @State private var progressLine = ""

    @State private var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var ollamaInstalled = false
    @State private var postgresReachable = false

    @State private var pgDatabase = "jarvis_db"
    @State private var pgUser = "jarvis_user"
    @State private var pgPassword = ""
    @State private var pgPrefilled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.016))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(NoirPalette.line, lineWidth: 1)
                    Image(systemName: kind.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(NoirPalette.secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoirPalette.text)
                    Text(kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                }

                Spacer()
                NoirIconButton(icon: "xmark", help: "Close") { dismiss() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    detailBody
                    if busy || !progressLine.isEmpty {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(progressLine.isEmpty ? "Working…" : progressLine)
                                .font(.system(size: 11))
                                .foregroundStyle(NoirPalette.muted)
                        }
                    }
                    if let notice {
                        noticeCard(notice)
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 480)

            HStack(spacing: 8) {
                Spacer()
                if kind == .postgres {
                    Button("Done") { dismiss() }
                        .buttonStyle(NoirButtonStyle(intent: .quiet))
                    Button(busy ? "Creating…" : "Create & configure") { createDatabase() }
                        .buttonStyle(NoirButtonStyle(intent: .primary))
                        .disabled(busy
                                  || pgDatabase.trimmingCharacters(in: .whitespaces).isEmpty
                                  || pgUser.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(NoirButtonStyle(intent: .primary))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }
        }
        .frame(width: 540)
        .background(NoirPalette.base)
        .preferredColorScheme(.dark)
        .task { await prepare() }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch kind {
        case .microphone:
            Text("Allow Jarvis to use your microphone for dictation and voice commands. Audio is transcribed locally and never uploaded.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            statusRow("Microphone access", micAuthorized ? "Ready" : "Not granted",
                      kind: micAuthorized ? .green : .amber)

            HStack(spacing: 8) {
                Button("Request access") { requestMicrophone() }
                    .buttonStyle(NoirButtonStyle(intent: .primary))
                Button("Open Microphone settings") { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                    .buttonStyle(NoirButtonStyle(intent: .quiet))
            }

        case .accessibility:
            Text("Jarvis needs accessibility access to paste dictated text at the cursor in other applications.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            statusRow("Accessibility access", has_accessibility_permission() ? "Ready" : "Not granted",
                      kind: has_accessibility_permission() ? .green : .amber)

            Button("Open Accessibility settings") {
                open_accessibility_pane()
                _ = request_event_posting_permission()
                notice = "Open Privacy & Security → Accessibility and enable Jarvis."
            }
            .buttonStyle(NoirButtonStyle(intent: .primary))

        case .whisper:
            Text("The current application uses Whisper large-v3-turbo for on-device speech recognition. The model is approximately 1.5 GB and downloads automatically.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            statusRow("Model", whisperStatusText,
                      kind: whisperReady ? .green : .amber)

            Text(whisperPhaseNote)
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)

            Button("Choose model folder") { chooseModelFolder() }
                .buttonStyle(NoirButtonStyle(intent: .primary))

        case .ollama:
            NoirCard {
                VStack(spacing: 0) {
                    statusRow("Ollama server", appState.ollamaReachable ? "Ready" : (ollamaInstalled ? "Not running" : "Missing"),
                              kind: appState.ollamaReachable ? .green : .amber)
                    NoirDivider()
                    statusRow("AI model", appState.ollamaModelInstalled ? "Installed" : "Not installed",
                              kind: appState.ollamaModelInstalled ? .green : .amber)
                    NoirDivider()
                    NoirSettingRow(title: "Model") {
                        Text("qwen2.5:1.5b-instruct")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NoirPalette.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(ollamaInstalled ? "Start Ollama" : "Install Ollama") {
                    if ollamaInstalled {
                        startOllama()
                    } else {
                        installOllama()
                    }
                }
                .buttonStyle(NoirButtonStyle(intent: .primary))
                Button("Pull model") { pullModel() }
                    .buttonStyle(NoirButtonStyle())
            }

        case .postgres:
            NoirCard {
                VStack(spacing: 0) {
                    statusRow("Server", postgresReachable ? "Running" : "Not running",
                              kind: postgresReachable ? .green : .amber)
                    NoirDivider()
                    NoirSettingRow(
                        title: "Event logging",
                        sub: postgresConfiguredSub
                    ) {
                        NoirSwitch(isOn: $appState.eventLoggingEnabled,
                                   disabled: !appState.postgresConfigured)
                    }
                }
            }

            if !postgresReachable {
                Button("Install & start server") { installPostgres() }
                    .buttonStyle(NoirButtonStyle())
            }

            VStack(alignment: .leading, spacing: 14) {
                TextField("Database", text: $pgDatabase)
                    .noirField()
                    .noirFieldLabel("Database")
                TextField("User", text: $pgUser)
                    .noirField()
                    .noirFieldLabel("User")
                SecureField("Leave blank to keep the current password", text: $pgPassword)
                    .noirField()
                    .noirFieldLabel("Password")
            }

        case .backend:
            Text("The helper supports voice authentication, Spotify, and the learned intent router. It can run on demand, always, or remain off.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            NoirCard {
                NoirSettingRow(title: "Helper mode") {
                    NoirSelect(
                        options: [
                            (.automatic, "On demand"),
                            (.always, "Always on"),
                            (.off, "Off")
                        ],
                        selection: $appState.backendMode,
                        width: 132
                    )
                }
            }

            statusRow("Helper", appState.backendStatus,
                      kind: appState.backendStatus.lowercased().contains("running") ? .green : .neutral)

            Button("Prepare Python helper") { prepareBackend() }
                .buttonStyle(NoirButtonStyle(intent: .primary))

        case .spotify:
            Text("Create a Spotify app with the redirect http://127.0.0.1:8000/spotify/callback, then paste your keys in Connections and authorize.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            statusRow("Spotify", appState.spotifyLinked ? "Connected" : "Not connected",
                      kind: appState.spotifyLinked ? .green : .neutral)

            HStack(spacing: 8) {
                Button("Open Spotify dashboard") {
                    openURL("https://developer.spotify.com/dashboard")
                }
                .buttonStyle(NoirButtonStyle())
                Button("Open Connections") {
                    appState.activeSection = .connections
                    dismiss()
                }
                .buttonStyle(NoirButtonStyle(intent: .primary))
            }
        }
    }

    // MARK: Status helpers

    private var whisperReady: Bool {
        if case .Ready = dictation.modelPhase { return true }
        if case .Inference = dictation.modelPhase { return true }
        return false
    }

    private var whisperStatusText: String {
        let phase = dictation.modelPhase
        if case .Ready = phase { return "Installed" }
        if case .Inference = phase { return "Installed" }
        if case .NotInstalled = phase { return "Missing" }
        if case .Error = phase { return "Failed" }
        return "Working"
    }

    private var whisperPhaseNote: String {
        let phase = dictation.modelPhase
        if case .NotInstalled = phase {
            return "The model downloads automatically when Jarvis launches. Restart Jarvis to retry a failed download."
        }
        if case .Ready = phase { return "Installed and ready." }
        if case .Downloading = phase {
            let pct = Int(dictation.downloadProgress * 100)
            return "Downloading: \(pct)% · \(dictation.downloadSpeed) · \(dictation.downloadRemaining) remaining"
        }
        if case .Error = phase {
            return "Download failed. Check your connection and restart Jarvis to retry."
        }
        return "Phase: \(phase)"
    }

    private var postgresConfiguredSub: String {
        appState.postgresConfigured
            ? "Write commands and stats to Postgres."
            : "Configure below to enable."
    }

    private func statusRow(_ label: String, _ value: String, kind: NoirTag.Kind) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.text)
            Spacer(minLength: 8)
            NoirTag(text: value, kind: kind)
        }
        .padding(.horizontal, 19)
        .frame(minHeight: 54)
    }

    private func noticeCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineSpacing(4)
            .foregroundStyle(NoirPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NoirPalette.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(NoirPalette.accent.opacity(0.15), lineWidth: 1)
            )
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Preparation

    private func prepare() async {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let probes = await Task.detached(priority: .utility) {
            (OllamaSetup.isInstalled(), PostgresProvisioner.serverReachable())
        }.value
        ollamaInstalled = probes.0
        postgresReachable = probes.1

        if !pgPrefilled {
            let saved = RuntimeConfiguration.mergedValues()
            if let database = saved["PGDATABASE"], !database.isEmpty,
               let user = saved["PGUSER"], !user.isEmpty {
                pgDatabase = database
                pgUser = user
                pgPassword = ""
            }
            pgPrefilled = true
        }
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            notice = "Allow Jarvis under Microphone, then return here."
            return
        }
        Task {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    continuation.resume(returning: ok)
                }
            }
            micAuthorized = granted
            notice = granted
                ? "Microphone access granted."
                : "Denied — allow Jarvis in System Settings → Privacy & Security → Microphone."
        }
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Folder for ggml-large-v3-turbo.bin (applies on next launch)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "jarvis.stt.modelDir")
        notice = "Model folder set: \(url.path) — applies on next launch."
    }

    private func installOllama() {
        busy = true
        progressLine = ""
        Task {
            let result = await OllamaSetup.install { line in
                Task { @MainActor in progressLine = line }
            }
            busy = false
            notice = result.isEmpty ? "Ollama installed." : result
            await refreshOllama()
        }
    }

    private func startOllama() {
        busy = true
        Task {
            let result = await OllamaSetup.start()
            busy = false
            notice = result
            await refreshOllama()
        }
    }

    private func pullModel() {
        busy = true
        progressLine = ""
        Task {
            let failure = await OllamaSetup.pullModel { line in
                Task { @MainActor in progressLine = line }
            }
            busy = false
            notice = failure ?? "Model ready."
            await refreshOllama()
        }
    }

    private func refreshOllama() async {
        ollamaInstalled = OllamaSetup.isInstalled()
        await appState.refreshOllamaStatus()
    }

    private func installPostgres() {
        busy = true
        progressLine = ""
        Task {
            let failure = await HomebrewActions.installAndStartPostgres { line in
                Task { @MainActor in progressLine = line }
            }
            busy = false
            notice = failure ?? "Server started."
            postgresReachable = await Task.detached { PostgresProvisioner.serverReachable() }.value
        }
    }

    private func createDatabase() {
        let plan = PostgresProvisioner.Plan(
            database: pgDatabase.trimmingCharacters(in: .whitespaces),
            user: pgUser.trimmingCharacters(in: .whitespaces),
            password: pgPassword,
            port: "5432",
            host: "127.0.0.1"
        )
        guard !plan.database.isEmpty, !plan.user.isEmpty else {
            notice = "Database and user are both required."
            return
        }
        busy = true
        Task {
            do {
                let message = try await Task.detached(priority: .utility) {
                    let message = try PostgresProvisioner.provision(plan)
                    try ConnectionSettingsStore.save([
                        "PGHOST": plan.host,
                        "PGPORT": plan.port,
                        "PGDATABASE": plan.database,
                        "PGUSER": plan.user,
                        "PGPASSWORD": plan.password,
                    ])
                    return message
                }.value
                appState.dbManager.reloadConfiguration()
                appState.eventLoggingEnabled = true
                appState.postgresForm = PostgresForm(
                    host: plan.host,
                    port: plan.port,
                    database: plan.database,
                    user: plan.user,
                    password: ""
                )
                appState.postgresConfigured = true
                appState.postgresStatusText = "Configured"
                notice = message
                toasts.show("Database configured.")
            } catch {
                notice = "Provisioning failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func prepareBackend() {
        busy = true
        progressLine = ""
        Task {
            let result = await HomebrewActions.prepareBackend { line in
                Task { @MainActor in progressLine = line }
            }
            busy = false
            notice = result
        }
    }
}
