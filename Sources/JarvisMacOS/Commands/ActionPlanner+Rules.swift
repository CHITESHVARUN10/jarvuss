import Foundation

/// Native adapters only. Parsing, precedence, literals and schema validation
/// have one owner in Rust; these methods retain the existing test seam.
extension ActionPlanner {
    func ruleBasedPlan(cleaned: String, lower: String) -> [PlannedAction]? {
        coreRuleCommand(raw: cleaned).map(RustPipeline.map)
    }
    func parseMediaCommand(_ text: String) -> PlannedAction? {
        coreParseMediaCommand(raw: text).flatMap(RustPipeline.map)
    }
    func parseFileQuery(_ text: String) -> PlannedAction? {
        coreParseFileQuery(raw: text).flatMap(RustPipeline.map)
    }
    func splitByConjunction(_ text: String) -> [String] { coreCommandParts(raw: text) }
    func actionVerbCount(_ text: String) -> Int { Int(coreCommandVerbCount(raw: text)) }
    func mediaContentTokens(_ text: String) -> [String] { coreMediaContentWords(raw: text) }
    func answerLocalStateQuery(cleaned: String, lower: String) -> [PlannedAction]? {
        coreResolveLocalState(cleaned: cleaned).map(RustPipeline.map)
    }
    func stripWakeWord(_ text: String) -> String { coreCleanCommand(raw: text) }
    func stripTrailingNoise(_ text: String) -> String { text }
}
