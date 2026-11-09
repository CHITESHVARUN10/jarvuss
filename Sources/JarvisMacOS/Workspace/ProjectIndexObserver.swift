import AppKit
import CoreServices

/// macOS owns event delivery; Rust owns the bounded index and matching.
/// Missed/dropped events are safe: every event invalidates the entire index,
/// which also has a short TTL and validates roots and selected directories.
@MainActor
final class ProjectIndexObserver {
    private var stream: FSEventStreamRef?
    private var observers: [NSObjectProtocol] = []
    init() {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.willUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                coreInvalidateProjectIndex()
            })
        }
    }
    func watch(_ paths: [String]) {
        stop(); coreInvalidateProjectIndex()
        guard !paths.isEmpty else { return }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, _, _, _, _, _ in coreInvalidateProjectIndex() }, nil,
                                             paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(stream) { stop() }
    }
    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
