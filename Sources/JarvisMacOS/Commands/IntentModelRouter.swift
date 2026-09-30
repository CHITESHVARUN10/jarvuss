import Foundation

/// First routing attempt in `ActionPlanner.plan(from:)`.
///
/// Sends the cleaned utterance to the backend's learned intent model
/// (fine-tuned t5-small). On success it returns the mapped plan and logs a
/// `model_hit`. On ANY failure — disabled, backend down, timeout, invalid
/// JSON, unknown intent, or low confidence — it logs a `model_miss` with the
/// reason and returns nil so the caller falls through to the existing
/// FastPathRouter → rules → Ollama pipeline (the Qwen fallback).
final class IntentModelRouter {

    /// Minimum mean token-probability for a model answer to be trusted.
    static let confidenceThreshold = 0.75

    private let client = IntentModelClient()
    private let isEnabled: Bool

    init() {
        let env = ProcessInfo.processInfo.environment["JARVIS_INTENT_MODEL"]?.lowercased()
        isEnabled = env != "off" && env != "0" && env != "false"
    }

    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? {
        guard isEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let start = Date()
        do {
            let response = try await client.parse(text: text)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

            guard response.parseOK, !response.actions.isEmpty else {
                logMiss(text: text, requestID: requestID, reason: "parse_fail",
                        raw: response.raw, confidence: response.confidence, elapsedMs: elapsedMs)
                return nil
            }
            guard response.confidence >= Self.confidenceThreshold else {
                logMiss(text: text, requestID: requestID, reason: "low_confidence",
                        raw: response.raw, confidence: response.confidence, elapsedMs: elapsedMs)
                return nil
            }
            guard let actions = IntentActionMapper.map(response.actions) else {
                logMiss(text: text, requestID: requestID, reason: "unmappable",
                        raw: response.raw, confidence: response.confidence, elapsedMs: elapsedMs)
                return nil
            }

            IntentRouterLog.shared.append([
                "event": "model_hit",
                "request_id": requestID.uuidString,
                "text": text,
                "raw": response.raw,
                "actions": response.actions,
                "confidence": response.confidence,
                "latency_ms": response.latencyMs,
                "total_ms": elapsedMs,
            ])
            NSLog("[IntentModel] hit (%.2f, %dms): %@",
                  response.confidence, elapsedMs, actions.map(\.description).joined(separator: ", "))
            return actions
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            logMiss(text: text, requestID: requestID, reason: "unavailable",
                    raw: String(describing: error), confidence: 0, elapsedMs: elapsedMs)
            return nil
        }
    }

    private func logMiss(text: String, requestID: UUID, reason: String,
                         raw: String, confidence: Double, elapsedMs: Int) {
        IntentRouterLog.shared.append([
            "event": "model_miss",
            "request_id": requestID.uuidString,
            "text": text,
            "reason": reason,
            "raw": raw,
            "confidence": confidence,
            "total_ms": elapsedMs,
        ])
        NSLog("[IntentModel] miss (%@): '%@'", reason, text)
    }
}
