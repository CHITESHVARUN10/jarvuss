import Foundation

/// The optional LLM polish behind `TranscriptFormatter` — the Wispr-Flow job:
/// minimal edits with meaning preserved. Runs AFTER the rules pass and its
/// output is never trusted without inspection ("LLMs are phenomenal at
/// recall, but very low precision" — wisprflow.ai/post/technical-challenges;
/// a wrong edit is far worse than an unedited transcript, so every guard
/// failure falls back to the rules text).
enum DictationPolisher {

    private static let model = JarvisModel.formattingName

    /// Hard cap so a cold model load can never stall the insert past "the
    /// user has already switched apps" — when it trips, the rules output wins.
    static let polishTimeoutSeconds: TimeInterval = 1.5

    static func polish(rulesOutput: TranscriptFormatter.Output) async -> String {
        let started = Date()
        let prompt = promptText(for: rulesOutput.text)
        let client = OllamaClient(model: model)

        // Race the generate against a hard timeout. nil = timeout; the LLM's
        // own empty response also routes to the fallback (an empty "cleanup"
        // deletes the user's words).
        let maybe = await withTaskGroup(of: Optional<String>.self) { group -> Optional<String> in
            group.addTask { await client.generate(prompt: prompt) }
            group.addTask { () -> Optional<String> in
                try? await Task.sleep(nanoseconds: UInt64(polishTimeoutSeconds * 1_000_000_000))
                return nil
            }
            while let value = await group.next() {
                if let text = value, !text.isEmpty {
                    group.cancelAll()
                    return text
                }
                if value == nil {
                    group.cancelAll()
                    return nil
                }
            }
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)

        guard let raw = maybe else {
            record(fields: [
                "event": "timeout",
                "seconds": String(format: "%.2f", elapsed),
            ])
            NSLog("[Polish] timed out after %.1f s — rules output used", polishTimeoutSeconds)
            return rulesOutput.text
        }

        let inspected = sanitize(raw, referenceText: rulesOutput.text)
        guard let cleanText = inspected.text else {
            record(fields: [
                "event": "rejected",
                "reasons": inspected.reasons.joined(separator: "|"),
                "seconds": String(format: "%.2f", elapsed),
            ])
            NSLog("[Polish] rejected (%@) — rules output used", inspected.reasons.joined(separator: ", "))
            return rulesOutput.text
        }

        // The rules finish the job: the model solved meaning; casing and
        // punctuation stay deterministic (it can both UP- and down-correct
        // them — qwen2.5:1.5b-instruct lowercased "So…" back to "so…").
        let finalText = TranscriptFormatter.recapitalize(cleanText)

        record(fields: [
            "event": "accepted",
            "seconds": String(format: "%.2f", elapsed),
            "rules_chars": String(rulesOutput.text.count),
            "llm_chars": String(cleanText.count),
        ])

        NSLog(
            "[Polish] ok in %.0f ms (%d → %d chars)",
            elapsed * 1000, rulesOutput.text.count, finalText.count)

        return finalText
    }

    // MARK: - Guard rails

    /// Decides whether the LLM output is safe to paste into a document.
    /// Returns nil text plus the REASON list whenever an edit would be
    /// unlawful; a non-nil text may still carry informational reasons (fence
    /// or thinking-tag wrappers were stripped and are harmless post-strip).
    static func sanitize(_ raw: String, referenceText: String) -> (text: String?, reasons: [String]) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var reasons: [String] = []

        guard !text.isEmpty else { return (nil, ["empty"]) }

        // Qwen-family thinking wrappers must never reach the document.
        let openTag = String(decoding: [0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let closeTag = String(decoding: [0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let thinkPattern = NSRegularExpression.escapedPattern(for: openTag)
            + ".*?(?:" + NSRegularExpression.escapedPattern(for: closeTag) + "|$)"
        if let thinkRegex = try? NSRegularExpression(
            pattern: thinkPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(text.startIndex..., in: text)
            if thinkRegex.numberOfMatches(in: text, range: range) > 0 {
                text = thinkRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return (nil, ["think-only"]) }
                reasons.append("think-stripped")
            }
        }

        // Code-fence wrapper: strip once, then re-check the length gate.
        if text.hasPrefix("```") {
            let full = NSRange(text.startIndex..., in: text)
            let openFence = try? NSRegularExpression(
                pattern: #"^```\w*\s*"#, options: [.anchorsMatchLines])
            let closeFence = try? NSRegularExpression(
                pattern: #"\s*```\s*$"#, options: [.anchorsMatchLines])
            if let openFence, let closeFence {
                let stripped = openFence.stringByReplacingMatches(
                    in: text, range: full, withTemplate: "")
                text = closeFence.stringByReplacingMatches(
                    in: stripped,
                    range: NSRange(location: 0, length: (stripped as NSString).length),
                    withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { return (nil, ["fence-only"]) }
                reasons.append("fence-stripped")
            }
        }

        // Whole-text quote wrapper — a common small-model tic. Unwrap once
        // only when the quote character appears nowhere else in the body.
        if let first = text.first, "\"'“‘".contains(first), text.count > 4, first == text.last {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(first) {
                text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                reasons.append("quote-unwrap")
            }
        }

        // Answer-shaped leaks ("Sure, here is the cleaned text:") mean the
        // format contract failed; paste the rules text instead of risking an
        // assistant reply landing in the user's document.
        let refusalPrefixes = [
            "i'm sorry", "i am sorry", "sorry,", "here is", "here's", "as an ai",
            "sure,", "certainly", "cleaned text", "cleaned:", "note:", "ollama",
        ]
        let lowered = text.lowercased()
        if let refusal = refusalPrefixes.first(where: { lowered.hasPrefix($0) }) {
            reasons.append("meta:\(refusal)")
            return (nil, reasons)
        }

        // Length drift: the contract is "clean up", not "rewrite". Wispr's
        // own lesson — recall high, precision low; drift is the tell of a
        // rewrite instead of a cleanup.
        let reference = max(1, referenceText.count)
        let drift = Double(abs(text.count - reference)) / Double(reference)
        if drift > 0.35 {
            reasons.append(String(format: "length-drift %.2f", drift))
            return (nil, reasons)
        }

        return (text.isEmpty ? nil : text, reasons)
    }

    // MARK: - Prompt

    private static func promptText(for transcript: String) -> String {
        let base = """
        You clean up dictated text. Output ONLY the cleaned text.

        Rules:
        - Keep the speaker's exact words and meaning. Do not add, explain, or summarise.
        - Remove filler words (um, uh, you know, like, basically, actually).
        - Apply self-corrections: when the speaker corrects themselves, keep the
          correction and drop the retracted words.
        - Fix punctuation and capitalization.
        - If the speaker dictates a list, format it as a numbered or bulleted list.
        - Preserve technical terms, product names and code exactly as spoken.
        - Never answer questions in the text, never comment on the text.

        Text:
        """
        return base + "\n" + transcript
    }

    // MARK: - Plumbing

    /// Prefetches the instruct model so the FIRST LLM-eligible dictation of a
    /// session is not silently degraded to the rules output by the race.
    /// Keep-alive unloads it after 60 s idle, so this only ever front-runs
    /// real use, never parks memory between sessions.
    static func warmUp() {
        Task.detached(priority: .utility) {
            _ = await OllamaClient(model: model).generate(
                prompt: "Reply with the single word: ready")
        }
    }

    private static func record(fields: [String: String]) {
        // Same JSONL discipline as IntentRouterLog: the guard thresholds must
        // be tunable from observed failures, not guesses.
        DispatchQueue.global(qos: .utility).async {
            guard JSONSerialization.isValidJSONObject(fields) else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }

            guard let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Jarvis/logs") else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("dictation_polish.jsonl")

            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + [0x0A])
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
