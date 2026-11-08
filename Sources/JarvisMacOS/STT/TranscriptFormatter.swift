import Foundation

/// Wispr-Flow-style deterministic cleanup of a dictated transcript.
///
/// The rules pass lives in the Rust core. Swift owns the `Output` contract and
/// the app-side decision to send the text to the optional polish model.
enum TranscriptFormatter {

    struct Output {
        let text: String
        let fillerRemovals: Int
        let correctionResolves: Int
        let unboundedCorrections: Int
        let hasEnumeration: Bool
        let inputWords: Int

        var outputWords: Int { text.split(separator: " ").count }
    }

    static func format(_ raw: String) -> Output {
        let value = coreFormatTranscript(raw: raw)
        return Output(
            text: value.text,
            fillerRemovals: Int(value.fillerRemovals),
            correctionResolves: Int(value.correctionResolves),
            unboundedCorrections: Int(value.unboundedCorrections),
            hasEnumeration: value.hasEnumeration,
            inputWords: Int(value.inputWords)
        )
    }

    /// The app-side instruction line for the polish model (see
    /// `DictationPolisher.systemPrompt`). The speaker never says this line —
    /// it is how the app tells the model "this is a list, typeset it".
    enum ListDirective: String, Equatable {
        case numbered = "List: numbered"
        case bullets  = "List: bullets"
    }

    /// LLM-pass trigger (`DictationPolisher`): rules handle the common case at
    /// ~0 ms; the LLM only earns its latency on messy, structured, or
    /// app-directed-list input.
    static func shouldUseLLM(_ output: Output, directive: ListDirective? = nil) -> Bool {
        coreTranscriptShouldUseLlm(
            hasEnumeration: output.hasEnumeration,
            unboundedCorrections: Int32(output.unboundedCorrections),
            outputWords: Int32(output.outputWords),
            fillerRemovals: Int32(output.fillerRemovals),
            correctionResolves: Int32(output.correctionResolves),
            hasDirective: directive != nil
        )
    }

    /// Decides whether the app should DIRECT the model to typeset a list.
    /// The model is never allowed to infer list structure on its own.
    static func listDirective(for raw: String) -> ListDirective? {
        switch coreTranscriptListDirective(raw: raw) {
        case "numbered": return .numbered
        case "bullets": return .bullets
        default: return nil
        }
    }

    /// The deterministic casing/punctuation authority, exposed separately for
    /// the LLM pass: a model that solves self-corrections can STILL unfix
    /// capitalization, so whatever the LLM returns passes back through this.
    static func recapitalize(_ text: String) -> String {
        coreRecapitalize(text: text)
    }
}
