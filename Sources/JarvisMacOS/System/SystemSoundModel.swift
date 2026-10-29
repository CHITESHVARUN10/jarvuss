import Foundation
import Combine

/// Lives with the visible System pane. Polls only when requested by the view;
/// the controller and fallback-mute bookmarks are shared with voice commands.
@MainActor
final class SystemSoundModel: ObservableObject {
    @Published private(set) var snapshot: SystemVolumeSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isApplying = false
    @Published private(set) var lastResult: ControllerResult?
    private let controller: VolumeController

    init(controller: VolumeController = .shared) { self.controller = controller }

    func refresh() async {
        guard !isRefreshing, !isApplying, !Task.isCancelled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let observed = await controller.snapshot()
        // An earlier poll must not replace the state of an in-flight action.
        guard !Task.isCancelled, !isApplying else { return }
        snapshot = observed
    }

    func apply(_ action: VolumeAction, to output: SystemAudioOutput?) async {
        guard let output, !isApplying, !Task.isCancelled else { return }
        isApplying = true
        defer { isApplying = false }
        lastResult = await controller.perform(action, expectedOutput: output)
        snapshot = await controller.snapshot()
    }
}
