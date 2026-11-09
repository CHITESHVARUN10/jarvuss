import Foundation

/// Shared native policy; model/network orchestration stays asynchronous in Swift.
enum FastPathRouter {
    enum Verdict: Equatable { case execute([PlannedAction]); case needsModel }
    static func route(_ raw: String) -> Verdict {
        guard let actions = coreFastCommand(raw: raw) else { return .needsModel }
        return .execute(RustPipeline.map(actions))
    }
}
