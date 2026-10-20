import SwiftUI
import AVFoundation
import AppKit

/// First-run checklist: one row per dependency, each with an inline fix.
/// Nothing here blocks the app — dictation needs only mic + Whisper; the
/// rest (Ollama, Postgres, Spotify) are optional upgrades.
struct SetupPane: View {
    @ObservedObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var dictation = DictationController.shared

    @State private var expanded: SetupItemKind?
    @State private var ollamaInstalled = false
    @State private var postgresReachable = false
    @State private var micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    @State private var pgDatabase = "jarvis_db"
    @State private var pgUser = "jarvis_user"
    @State private var pgPassword = PostgresProvisioner.generatedPassword()
    /// Update path: fill the form from the saved connection (outside the
    /// bundle, so it survives replacing the app) and blank the password.
    @State private var pgPrefilled = false

    @ObservedObject private var activity = SetupActivity.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                JLabel(text: "Checklist")
                Spacer()
                JRefreshButton(help: "Refresh setup status") {
                    Task { await refreshProbes() }
                }
            }

            JCard(flush: true) {
                ForEach(Array(SetupItemKind.allCases.enumerated()), id: \.element) { index, kind in
                    setupRow(
                        kind: kind,
                        isFirst: index == 0
                    )
                }
            }
            .padding(.top, 9)

            if let expanded {
                detail(for: expanded)
                    .padding(.top, 6)
            }

            if let message = activity.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(JColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }

            JCard {
                JRow(title: "Finish setup",
                     sub: "You can return here anytime to finish optional steps",
                     first: true) {
                    Button("Done") {
                        appState.setupCompleted = true
                        appState.activeSection = .assistant
                    }
                    .disabled(activity.busy)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(JColor.accent)
                }
            }
            .padding(.top, 9)
        }
        .task { await refreshProbes() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshProbes() } }
        }
    }

    // MARK: - Rows

    private func setupRow(kind: SetupItemKind, isFirst: Bool) -> some View {
        let chip = status(kind: kind)
        return JActionRow(
            title: kind.title,
            sub: kind.subtitle,
            icon: kind.icon,
            first: isFirst,
            accessory: JChip(text: chip.text, kind: chip.kind)
        ) {
            expanded = expanded == kind ? nil : kind
            activity.message = nil
        }
    }

    private func status(kind: SetupItemKind) -> (text: String, kind: JChip.Kind) {
        switch kind {
        case .microphone:
            return micAuthorized ? ("Ready", .ok) : ("Grant", .warn)
        case .accessibility:
            return has_accessibility_permission() ? ("Ready", .ok) : ("Grant", .warn)
        case .whisper:
            let phase = dictation.modelPhase
            if case .Ready = phase { return ("Installed", .ok) }
            if case .Inference = phase { return ("Installed", .ok) }
            if case .NotInstalled = phase { return ("Missing", .warn) }
            if case .Error = phase { return ("Failed", .danger) }
            return ("Working", .accent)
        case .ollama:
            if appState.ollamaReachable {
                return appState.ollamaModelInstalled ? ("Ready", .ok) : ("Pull model", .warn)
            }
            return ollamaInstalled ? ("Start it", .warn) : ("Missing", .warn)
        case .postgres:
            if appState.postgresConfigured { return ("Configured", .ok) }
            return postgresReachable ? ("Create DB", .warn) : ("Optional", .neutral)
        case .backend:
            return (appState.backendStatus, .neutral)
        case .spotify:
            return appState.spotifyLinked ? ("Connected", .ok) : ("Optional", .neutral)
        }
    }

    // MARK: - Detail cards

    @ViewBuilder
    private func detail(for kind: SetupItemKind) -> some View {
        JCard(flush: true) {
            VStack(alignment: .leading, spacing: 0) {
                JCardHead<EmptyView>(icon: kind.icon, title: kind.title, accessory: nil)
                kindDetails(kind)
            }
            .padding(15)
        }
        if activity.busy {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(JColor.ink3)
            }
            .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func kindDetails(_ kind: SetupItemKind) -> some View {
        switch kind {
        case .microphone:
            JRow(title: "Grant microphone access",
                 sub: "Everything is recorded and transcribed locally",
                 first: true) {
                actionButton("Grant") { await requestMic() }
            }
        case .accessibility:
            JRow(title: "Grant accessibility",
                 sub: "Privacy & Security → Accessibility → Jarvis",
                 first: true) {
                actionButton("Open panel") {
                    open_accessibility_pane()
                    _ = request_event_posting_permission()
                    return ""
                }
            }
        case .whisper:
            JRow(title: "Model folder",
                 sub: "Choose where the speech model is stored (about 1.5 GB)",
                 first: true) {
                actionButton("Browse") {
                    chooseModelFolder()
                    return ""
                }
            }
            modelPhaseRow
        case .ollama:
            JRow(title: ollamaInstalled ? "Start Ollama" : "Install Ollama",
                 sub: ollamaInstalled
                    ? "Launches the local server on port 11434"
                    : "Installs via Homebrew, else opens the download page",
                 first: true) {
                actionButton(ollamaInstalled ? "Start" : "Install") {
                    if ollamaInstalled { return await OllamaSetup.start() }
                    return await OllamaSetup.install { line in
                        Task { @MainActor in activity.ollamaProgress = line }
                    }
                }
            }
            JRow(title: appState.ollamaModelInstalled ? "AI model installed" : "Pull qwen2.5:1.5b-instruct",
                 sub: "The model Ollama serves (~1 GB download)") {
                actionButton("Pull") {
                    let failure = await OllamaSetup.pullModel { line in
                        Task { @MainActor in activity.ollamaProgress = line }
                    }
                    return failure ?? "Model ready."
                }
            }
        case .postgres:
            JRow(title: postgresReachable ? "Server running" : "Install & start server",
                 sub: postgresReachable
                    ? "Port 5432 is accepting connections"
                    : "Installs postgresql@18 via Homebrew and starts it",
                 first: true) {
                actionButton(postgresReachable ? "Refresh" : "Install") {
                    guard !postgresReachable else { return "" }
                    let failure = await HomebrewActions.installAndStartPostgres { line in
                        Task { @MainActor in activity.postgresProgress = line }
                    }
                    return failure ?? "Server started."
                }
            }
            JRow(title: "Database", sub: "Created if missing; an existing role gets the password you enter") {
                TextField("", text: $pgDatabase)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
            }
            JRow(title: "User", sub: "Login role for Jarvis") {
                TextField("", text: $pgUser)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
            }
            JRow(title: "Password", sub: "Leave blank to keep the current password") {
                SecureField("", text: $pgPassword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
            }
            JRow(title: "Create & configure",
                 sub: "Creates role + database, enables event logging. Safe to re-run after an update.") {
                actionButton("Create") { await createJarvisDatabase() }
            }
        case .backend:
            JRow(title: "Prepare Python helper",
                 sub: "For speaker verification, Spotify and the learned command router. Installs Python 3.11 if needed, then helper dependencies.",
                 first: true) {
                actionButton("Prepare") {
                    await HomebrewActions.prepareBackend { line in
                        Task { @MainActor in activity.backendProgress = line }
                    }
                }
            }
        case .spotify:
            JRow(title: "1. Create a Spotify app",
                 sub: "Add redirect http://127.0.0.1:8000/spotify/callback",
                 first: true) {
                Button("Open dashboard") {
                    if let url = URL(string: "https://developer.spotify.com/dashboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JColor.accent)
            }
            JRow(title: "2. Paste keys, then connect",
                 sub: "The Connections pane has the fields and OAuth link") {
                Button("Open Connections") {
                    appState.activeSection = .connections
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(JColor.accent)
            }
        }

        progressRow(kind)
    }

    @ViewBuilder
    private var modelPhaseRow: some View {
        Text(modelPhaseNote)
            .font(.system(size: 10.5))
            .foregroundStyle(JColor.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
    }

    private var modelPhaseNote: String {
        let phase = dictation.modelPhase
        if case .NotInstalled = phase {
            return "The model downloads automatically when Jarvis launches. Restart Jarvis to retry a failed download."
        }
        if case .Ready = phase {
            return "Installed and ready."
        }
        if case .Downloading = phase {
            return "Downloading: \(Int(dictation.downloadProgress * 100))% · \(dictation.downloadSpeed) · \(dictation.downloadRemaining) remaining"
        }
        if case .Error = phase { return "Download failed. Check your connection and restart Jarvis to retry." }
        return "Phase: \(phase)"
    }

    @ViewBuilder
    private func progressRow(_ kind: SetupItemKind) -> some View {
        let message: String? = switch kind {
        case .ollama: activity.ollamaProgress
        case .postgres: activity.postgresProgress
        case .backend: activity.backendProgress
        default: nil
        }
        if let message {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(JColor.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
        }
    }

    private func actionButton(_ label: String, action: @escaping () async -> String) -> some View {
        Button(label) {
            guard !activity.busy else { return }
            activity.busy = true
            activity.message = nil
            Task {
                let failure = await action()
                await MainActor.run {
                    activity.busy = false
                    if failure.isEmpty {
                        activity.message = nil
                    } else {
                        activity.message = failure
                    }
                }
                await refreshProbes()
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(JColor.accent)
        .disabled(activity.busy)
    }

    // MARK: - Probes & actions

    private func refreshProbes() async {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !pgPrefilled {
            // Saved settings live in Application Support, so an app update
            // arrives with the connection intact; keep the password blank to
            // mean "don't touch the existing role".
            let saved = RuntimeConfiguration.mergedValues()
            if let database = saved["PGDATABASE"], !database.isEmpty,
               let user = saved["PGUSER"], !user.isEmpty {
                pgDatabase = database
                pgUser = user
                pgPassword = ""
            }
            pgPrefilled = true
        }
        let probes = await Task.detached(priority: .utility) {
            (OllamaSetup.isInstalled(), PostgresProvisioner.serverReachable())
        }.value
        guard !Task.isCancelled else { return }
        ollamaInstalled = probes.0
        postgresReachable = probes.1
        await appState.refreshOllamaStatus()
    }

    private func requestMic() async -> String {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return "Allow Jarvis in Microphone settings, then return here."
        }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { ok in continuation.resume(returning: ok) }
        }
        return granted ? "" : "Denied — allow Jarvis in System Settings → Privacy & Security → Microphone."
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Folder for ggml-large-v3-turbo.bin (applies on next launch)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "jarvis.stt.modelDir")
        activity.message = "Model folder set: \(url.path) — applies on next launch."
    }

    private func createJarvisDatabase() async -> String {
        let plan = PostgresProvisioner.Plan(
            database: pgDatabase.trimmingCharacters(in: .whitespaces),
            user: pgUser.trimmingCharacters(in: .whitespaces),
            password: pgPassword,
            port: "5432",
            host: "127.0.0.1"
        )
        guard !plan.database.isEmpty, !plan.user.isEmpty else {
            return "Database and user are both required."
        }
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
            await MainActor.run {
                appState.dbManager.reloadConfiguration()
                appState.eventLoggingEnabled = true
                appState.postgresForm = PostgresForm(host: plan.host, port: plan.port,
                    database: plan.database, user: plan.user, password: "")
                appState.postgresConfigured = true
                appState.postgresStatusText = "Configured"
            }
            return message
        } catch {
            return "Provisioning failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Item model

private enum SetupItemKind: String, CaseIterable, Identifiable {
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
        case .accessibility: return "Accessibility (auto-paste)"
        case .whisper:       return "Whisper model"
        case .ollama:        return "Ollama + AI model"
        case .postgres:      return "PostgreSQL"
        case .spotify:       return "Spotify"
        case .backend:       return "Python helper"
        }
    }

    var subtitle: String {
        switch self {
        case .microphone:    return "Required for dictation and commands"
        case .accessibility: return "Required for pasting at the cursor"
        case .whisper:       return "Required — about 1.5 GB, downloads automatically"
        case .ollama:        return "Optional — AI answers and planning"
        case .postgres:      return "Optional — history and usage stats"
        case .spotify:       return "Optional — voice-controlled playback"
        case .backend:       return "Optional — voice authentication and integrations"
        }
    }

    var icon: String {
        switch self {
        case .microphone:    return "mic"
        case .accessibility: return "accessibility"
        case .whisper:       return "waveform"
        case .ollama:        return "brain"
        case .postgres:      return "cylinder.split.1x2"
        case .spotify:       return "music.note"
        case .backend:       return "server.rack"
        }
    }
}


/// Keep an installation's state when the user switches panes and returns.
/// Otherwise a second Setup view can start a competing Homebrew operation.
@MainActor
private final class SetupActivity: ObservableObject {
    static let shared = SetupActivity()
    @Published var busy = false
    @Published var message: String?
    @Published var ollamaProgress: String?
    @Published var postgresProgress: String?
    @Published var backendProgress: String?
}
