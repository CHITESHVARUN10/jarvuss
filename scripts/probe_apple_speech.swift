// Offline Apple recognizer smoke test. No microphone, commands or user profiles.
// swift scripts/probe_apple_speech.swift AUDIO_FILE [LOCALE] [--install-assets]
import AVFoundation
import Foundation
import Speech

@main struct AppleSpeechProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw NSError(domain: "usage: AUDIO_FILE [LOCALE] [--install-assets]", code: 2) }
        guard SpeechTranscriber.isAvailable else { throw NSError(domain: "Apple speech unavailable", code: 1) }
        let requested = Locale(identifier: args.count > 2 && !args[2].hasPrefix("--") ? args[2] : "en-IN")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw NSError(domain: "Unsupported locale: \(requested.identifier)", code: 1)
        }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            guard args.contains("--install-assets") else { throw NSError(domain: "Apple language assets need installation; pass --install-assets", code: 1) }
            try await install.downloadAndInstall()
        }
        let started = ContinuousClock.now
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () throws -> [[String: Any]] in
            var output: [[String: Any]] = []
            for try await result in module.results {
                output.append(["text": String(result.text.characters), "start": result.range.start.seconds,
                               "end": CMTimeRangeGetEnd(result.range).seconds, "final": result.isFinal,
                               "elapsed_ms": Double(started.duration(to: .now).components.attoseconds) / 1e15 + Double(started.duration(to: .now).components.seconds)*1000])
            }
            return output
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
        if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
        else { await analyzer.cancelAndFinishNow() }
        let records = try await results.value
        let data = try JSONSerialization.data(withJSONObject: ["engine":"apple", "locale":locale.identifier, "results":records], options: [.prettyPrinted,.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
