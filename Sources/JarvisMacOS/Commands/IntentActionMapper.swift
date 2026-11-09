import Foundation

/// Rust owns intent validation, native family admission and literal arguments.
/// Swift only serializes the model payload and adapts the generated action types.
enum IntentActionMapper {
    static func map(_ intents: [[String: Any]], sourceText: String? = nil) -> [PlannedAction]? {
        guard JSONSerialization.isValidJSONObject(intents),
              let data = try? JSONSerialization.data(withJSONObject: intents),
              let json = String(data: data, encoding: .utf8),
              let actions = coreMapIntentsWithSource(json: json, source: sourceText), !actions.isEmpty else { return nil }
        let mapped = RustPipeline.map(actions)
        return mapped.count == actions.count ? mapped : nil
    }
}
