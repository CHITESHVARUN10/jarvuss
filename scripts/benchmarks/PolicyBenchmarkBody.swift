private func benchAction(_ action: PlannedAction?) -> Int { action?.description.utf8.count ?? 0 }
private func benchSearch(_ r: LocalSearchRequest?) -> Int {
    guard let r else { return 0 }
    return r.query.utf8.count &+ r.scopes.joined().utf8.count &+ Int(r.minimumBytes % 100000) &+ Int(r.maximumBytes % 100000)
}
private func benchRoutine(_ raw: String, installed: Bool) -> Int {
    let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    if installed {
        let value = InstalledAutomationAction(type: InstalledAutomationActionType(rawValue: parts[0])!, value: parts[1])
        return value.validationMessage?.utf8.count ?? 0
    }
    let value = AutomationAction(type: AutomationActionType(rawValue: parts[0])!, value: parts[1])
    return value.validationMessage?.utf8.count ?? 0
}
private func benchTranscript(_ t: String, installed: Bool) -> Int {
    if installed {
        return InstalledTranscriptSanitizer.normalizeMisheardTargets(in:t).utf8.count
            + InstalledTranscriptSanitizer.collapseRepeatedPhrases(t).utf8.count
            + InstalledTranscriptSanitizer.sanitizeSpokenCommand(t).utf8.count
    }
    return TranscriptSanitizer.normalizeMisheardTargets(in:t).utf8.count
        + TranscriptSanitizer.collapseRepeatedPhrases(t).utf8.count
        + TranscriptSanitizer.sanitizeSpokenCommand(t).utf8.count
}
final class InstalledPolicyBenchmark: XCTestCase {
    @inline(never) private func measureBlock(_ inputs: [String], _ repeats: Int, _ f: (String) -> Int) -> (Double, Int) {
        var sum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeats { for input in inputs { sum &+= f(input) } }
        let us = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(repeats * inputs.count) / 1000
        return (us, sum)
    }
    func testWarmPolicies() throws {
        guard let output = ProcessInfo.processInfo.environment["JARVIS_POLICY_BENCH_OUTPUT"] else { throw XCTSkip("Opt-in performance probe") }
        TestSupport.pinRustPipelineOff()
        defer { TestSupport.unpinRustPipeline() }
        typealias Group = (String, [String], (String) -> Int, (String) -> Int)
        let groups: [Group] = [
            ("App aliases", ["Chrome", "Brave", "VS Code", "spotfy", "Arc", "Microsoft Edge", "UnknownApplicationXYZ"],
             { InstalledAppAliasResolver.resolveSpoken($0).utf8.count }, { AppAliasResolver.resolveSpoken($0).utf8.count }),
            ("System volume", ["set output volume to nineteen", "increase volume by twenty three", "turn the volume down", "mute", "what is the volume", "play Volume Up", "set volume to 101"],
             { benchAction(InstalledSystemVolumeParser.route($0)) }, { benchAction(SystemVolumeParser.route($0)) }),
            ("Workspace parsing", ["open a new tab in Chrome", "open my portfolio project in VS Code", "open it in Terminal", "open Research project from Drive A in Finder", "play portfolio on Spotify"],
             { InstalledWorkspaceCommandParser.parse($0)?.description.utf8.count ?? 0 }, { WorkspaceCommandParser.parse($0)?.description.utf8.count ?? 0 }),
            ("Spotify shuffle", ["shuffle on", "turn shuffle off", "play playlist called Botanical Hours with shuffle on", "play my liked songs with shuffle off", "shuffle Gym playlist and open Safari"],
             { InstalledSpotifyShuffleParser.parse($0)?.description.utf8.count ?? 0 }, { SpotifyShuffleParser.parse($0)?.description.utf8.count ?? 0 }),
            ("File search", ["find PDFs mentioning orbital mechanics in Downloads", "search for files called \"yesterday in Downloads\"", "find images last week under 1.5 MB in Documents", "open Spotify", "find the compliance checklist PDF in documents"],
             { benchSearch(InstalledLocalSearchParser.search($0)) }, { benchSearch(LocalSearchParser.search($0)) }),
            ("Routine validation", ["open_website_chrome|example.com", "new_tab|Chrome", "workspace_command|open portfolio project in Finder", "play_song|Blinding Lights", "open_file|/tmp/Routine Notes.pdf", "open_website|file:///tmp/a", "play_song|"],
             { benchRoutine($0, installed:true) }, { benchRoutine($0, installed:false) }),
            ("Transcript policies", ["open chant gpt in breif", "open Brief project in Finder", "a little bit of a little bit of a little bit of", "hello ordinary command", "\u{200b}open Notes\n"],
             { benchTranscript($0, installed:true) }, { benchTranscript($0, installed:false) })
        ]
        var rows: [[String:Any]] = []; var checksum = 0
        for (name,inputs,old,new) in groups {
            // Warm both implementations and check result-consumption checksums before timing.
            for input in inputs { XCTAssertEqual(old(input),new(input),name + ": " + input) }
            var oldTimes:[Double] = [], newTimes:[Double] = []
            for round in 0..<9 {
                for side in (round % 2 == 0 ? [0,1] : [1,0]) {
                    let result = measureBlock(inputs,128,side == 0 ? old : new)
                    checksum &+= result.1
                    if side == 0 { oldTimes.append(result.0) } else { newTimes.append(result.0) }
                }
            }
            rows.append(["component":name,"case_count":inputs.count,"calls_per_round":128 * inputs.count,"baseline_us":oldTimes.sorted()[4],"rust_us":newTimes.sorted()[4],"baseline_round_us":oldTimes,"rust_round_us":newTimes])
            print("BENCH \(name): old \(oldTimes.sorted()[4]) us, new \(newTimes.sorted()[4]) us")
        }
        let report:[String:Any] = ["rows":rows,"checksum":checksum,"method":"Warm component calls in the same process; nine alternating rounds; median of block averages; result consumption included. No OS actions or model calls.","swift_configuration":ProcessInfo.processInfo.environment["JARVIS_POLICY_BENCH_CONFIGURATION"] ?? "unknown","rust_configuration":"release static library, UniFFI included"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
}
