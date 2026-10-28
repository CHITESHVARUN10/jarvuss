import AppKit
import CoreGraphics

struct DisplayRecoveryReport: Sendable {
    let targets: Int
    let failures: Int
    var complete: Bool { targets > 0 && failures == 0 }

    func status(betterDisplay: Bool?) -> String {
        if (complete || betterDisplay == true) && betterDisplay != false {
            return "Display restored to 60% brightness and 50% external contrast."
        }
        let message = "Recovery attempted. Some display controls could not be confirmed."
        // An absent optional app is not an error or a setup requirement.
        return betterDisplay == false
            ? message + " BetterDisplay did not confirm recovery; check its notification integration."
            : message
    }
}

struct DisplayRecoveryOperations {
    var resetGamma: () -> Void
    var builtIn: () -> Bool? // nil when no built-in panel is connected
    var externalIDs: () -> [CGDirectDisplayID]
    var brightness: (CGDirectDisplayID, Int) -> Bool
    var contrast: (CGDirectDisplayID, Int) -> Bool

    func perform() -> DisplayRecoveryReport {
        resetGamma()
        var targets = 0, failures = 0
        if let result = builtIn() { targets += 1; if !result { failures += 1 } }
        for id in Set(externalIDs()).sorted() {
            targets += 1
            // Try both even if one fails; never stop at the first monitor.
            let bright = brightness(id, DisplaySafety.recoveryBrightness)
            let contrast = contrast(id, DisplaySafety.recoveryContrast)
            if !bright || !contrast { failures += 1 }
        }
        return DisplayRecoveryReport(targets: targets, failures: failures)
    }

    static func restoreNative() -> DisplayRecoveryReport {
        // These stateful controllers are created and used on this worker only.
        let builtIn = BuiltInBrightnessController(), ddc = DDCController()
        return DisplayRecoveryOperations(resetGamma: { CGDisplayRestoreColorSyncSettings() },
            builtIn: {
                guard builtIn.builtInDisplayID() != nil else { return nil }
                return builtIn.setBrightness(Float(DisplaySafety.recoveryBrightness) / 100)
            }, externalIDs: { DDCController.externalDisplayIDs() },
            brightness: { ddc.setBrightness(displayID: $0, percent: $1) },
            contrast: { ddc.setContrast(displayID: $0, percent: $1) }).perform()
    }
}

/// Fixed absolute requests only; no arbitrary commands, shell, or app settings edits.
@MainActor
final class BetterDisplayRecovery {
    static let steps: [[String: String]] = [
        ["softwareBrightness": "1.0"],
        ["suspendImageAdjustments": "on"],
        ["hardwareContrast": String(Float(DisplaySafety.recoveryContrast) / 100)],
        ["brightness": String(Float(DisplaySafety.recoveryBrightness) / 100)],
    ]
    private var observerTokens: [NSObjectProtocol] = []
    private var pending: CheckedContinuation<Bool?, Never>?
    private var pendingID: String?
    private let isRunning: () -> Bool
    private let request: (([String: String]) async -> Bool?)?

    init(isRunning: (() -> Bool)? = nil, request: (([String: String]) async -> Bool?)? = nil) {
        self.isRunning = isRunning ?? {
            for id in ["pro.betterdisplay.BetterDisplay", "com.betterdisplay.BetterDisplay", "me.waydabber.BetterDummy"] {
                if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return true }
            }
            return false
        }
        self.request = request
    }

    func restore(needsContrast: Bool) async -> Bool? {
        // No launch, executable lookup, observer, notification, or timeout when absent.
        guard isRunning() else { return nil }
        var applied = true
        for step in Self.steps {
            if step["hardwareContrast"] != nil && !needsContrast { continue }
            let response: Bool?
            if let request { response = await request(step) }
            else { response = await send(step) }
            guard let result = response else { return false }
            if !result { applied = false }
        }
        return applied
    }

    private func send(_ parameters: [String: String]) async -> Bool? {
        let id = UUID().uuidString
        let data: [String: Any] = ["uuid": id, "commands": ["set"],
                                   "parameters": parameters.merging(["type": "Display"], uniquingKeysWith: { old, _ in old })]
        guard let encoded = try? JSONSerialization.data(withJSONObject: data),
              let json = String(data: encoded, encoding: .utf8) else { return false }
        return await withCheckedContinuation { continuation in
            pending = continuation
            pendingID = id
            let center = DistributedNotificationCenter.default()
            // BetterDisplay 4.1 uses com.*, current versions retain compatibility.
            for prefix in ["com", "pro"] {
                let token = center.addObserver(forName: .init("\(prefix).betterdisplay.BetterDisplay.response"), object: nil, queue: .main) { [weak self] notification in
                    guard let text = notification.object as? String,
                          let bytes = text.data(using: .utf8),
                          let reply = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          reply["uuid"] as? String == id,
                          let success = reply["result"] as? Bool else { return }
                    Task { @MainActor in self?.finish(id, result: success) }
                }
                observerTokens.append(token)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(id, result: nil) }
            center.postNotificationName(.init("com.betterdisplay.BetterDisplay.request"), object: json, userInfo: nil, deliverImmediately: true)
        }
    }

    private func finish(_ id: String, result: Bool?) {
        guard pendingID == id else { return }
        let continuation = pending
        pending = nil; pendingID = nil
        for token in observerTokens { DistributedNotificationCenter.default().removeObserver(token) }
        observerTokens.removeAll()
        continuation?.resume(returning: result)
    }
}

@MainActor
final class DisplayRecovery: ObservableObject {
    static let shared = DisplayRecovery()
    @Published private(set) var isRestoring = false
    @Published private(set) var status = ""
    @Published var shortcutRegistered = false

    func restore() {
        guard !isRestoring else { return }
        AppState.shared?.commandQueue.cancelAll()
        isRestoring = true
        status = "Restoring display visibility…"
        CrashDiagnostics.shared.record("display_recovery_requested")
        NSSound(named: "Glass")?.play()
        Task {
            let native = Task.detached(priority: .userInitiated) { DisplayRecoveryOperations.restoreNative() }
            let better = await BetterDisplayRecovery().restore(needsContrast: !DDCController.externalDisplayIDs().isEmpty)
            let report = await native.value
            status = report.status(betterDisplay: better)
            isRestoring = false
            AppState.shared?.refreshBrightness()
            AppState.shared?.refreshContrast()
            AppState.shared?.appendLog("[Display recovery] \(status)")
            CrashDiagnostics.shared.record("display_recovery_finished", fields: ["native_targets": String(report.targets),
                "native_failures": String(report.failures), "betterdisplay": better.map(String.init) ?? "not_running"])
        }
    }
}
