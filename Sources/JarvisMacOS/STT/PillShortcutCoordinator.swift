import Foundation

/// A second press cancels a pending permission/start request. Its completion
/// cannot open a recording later, even if the permission dialog ignores cancellation.
@MainActor
final class PillShortcutCoordinator {
    static let shared = PillShortcutCoordinator(
        prepare: {
            guard let app = AppState.shared else { return false }
            if app.micActive { return true }
            app.markTransientMicStart()
            await app.startMicrophone()
            return app.micActive
        },
        cancelPreparation: { AppState.shared?.restoreMicAfterTransientStartIfNeeded() },
        hasSession: { DictationController.shared.hasModalSession },
        toggle: { mode in
            if mode == .action { DictationController.shared.toggleAction() }
            else { DictationController.shared.toggleDictation() }
        },
        preparationFailed: { mode in
            DictationController.shared.presentCaptureFailure(
                AppState.shared?.microphoneError ?? "Microphone input is unavailable. Check your input device and Retry.", mode: mode)
        }
    )

    private let work = LatestResultTask<Bool>()
    private(set) var pendingMode: PillMode?
    private let prepare: () async -> Bool
    private let cancelPreparation: () -> Void
    private let hasSession: () -> Bool
    private let toggle: (PillMode) -> Void
    private let preparationFailed: (PillMode) -> Void

    init(prepare: @escaping () async -> Bool, cancelPreparation: @escaping () -> Void,
         hasSession: @escaping () -> Bool, toggle: @escaping (PillMode) -> Void,
         preparationFailed: @escaping (PillMode) -> Void = { _ in }) {
        self.prepare = prepare
        self.cancelPreparation = cancelPreparation
        self.hasSession = hasSession
        self.toggle = toggle
        self.preparationFailed = preparationFailed
    }

    func press(_ mode: PillMode) {
        if let pendingMode {
            cancel()
            if pendingMode == mode { return }
        }
        // Stop/close must never start another microphone first.
        if hasSession() { toggle(mode); return }
        pendingMode = mode
        work.start(operation: prepare) { [weak self] ready in
            guard let self else { return }
            self.pendingMode = nil
            if ready { self.toggle(mode) }
            else {
                self.cancelPreparation()
                self.preparationFailed(mode)
            }
        }
    }

    func cancel() {
        let wasPending = pendingMode != nil
        pendingMode = nil
        work.invalidate()
        if wasPending { cancelPreparation() }
    }
}
