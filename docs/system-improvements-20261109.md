# System improvements — 9 November 2026

Implemented on `bfb18db58a56` with uncommitted changes.
No commit, training, Hugging Face publication, Moonshine installation or
replacement of `/Applications/Jarvis.app` was performed.

## Implemented

1. **Apple live speech.** The live recognizer defaults to on-device
   SpeechAnalyzer/SpeechTranscriber. System → Live speech selects the locale
   (default en-IN) or the Whisper fallback. macOS manages Apple assets.
   Shortcut dictation/action capture continues to use the existing Whisper
   engine. Copied audio, format conversion and analyzer input are bounded;
   hypotheses replace overlapping ranges; cancellation invalidates preparation
   and recognition independently. Pre-roll precedes live tap data. Recognition
   finalizes/drains at utterance end rather than executing partial hypotheses.
2. **Shared Rust command policy.** Completed the action contract for workspace,
   browser destination, file query/search/result, settings and shuffle actions.
   Native routes, learned mapping, compound splitting, rule fallback, routine
   compilation and Ollama output validation share Rust. Swift owns native
   execution and presentation adapters. Removed the remaining Swift media and
   device-planner policy files. Unsupported adapters reject a whole plan.
3. **Literal arguments.** Explicit song/playlist names, filenames, projects,
   URLs and web-search queries come from original input/native extraction.
   Learned replacements cannot overwrite supported literal arguments. URL path
   and query case survive. Compound mapping aligns only multiple actual clauses;
   a single request retains its complete source, including scopes and negation.
   This avoids a new classifier training run and keeps accepted Run 6 for
   ambiguous input; a separately trained smaller replacement was not produced.
4. **Trace/review/evaluation.** Correlation IDs span Apple and Whisper live
   capture, hotkey capture, verification, queues, routes and effects. New trace
   logs omit text by default and rotate. System → Correct a command saves
   private reviewed corrections associated with the request when available.
   WER, exact plans, verified effects and latency are separate evaluation
   metrics. Development-only confidence risk/coverage tooling never changes
   serving policy or starts training. New unverified step events are excluded
   from automatic positive training labels.
5. **Inference resources.** A bounded shared admission budget prioritizes
   interactive waiting work and refuses optional formatting during speech or
   memory pressure. Native intent decoding checks request cancellation between
   steps. System memory pressure and app footprint request idle intent/Whisper
   unload before the existing hard backstop. Voice remains in the existing
   bounded Rust helper. Another process boundary for intent/STT was not added:
   it remains conditional on evidence of native crashes or unrecoverable growth.
6. **Effects and routines.** Results/exported test steps distinguish verified,
   submitted, unavailable and failed effects. App launch only reports verified
   when an identified application has finished launching. Existing volume,
   browser, Finder/Terminal and Spotify readback remains. Playlist context and
   VS Code project identity are not falsely marked verified. Routine steps can
   require previous-step success; existing routines default to independent
   steps. No automatic retries duplicate tabs or relative volume actions.
7. **Project indexing.** Rust caches bounded directory indexes with a four-entry
   limit and 30-second fallback TTL. Native filesystem, location and volume
   changes invalidate them; roots and selected folders are checked. Alias and
   direct-child precedence remain. First construction still scans directories.
8. **Deterministic dictation default.** Rules formatting is immediate by
   default. AI formatting is explicitly enabled in System → Dictation and
   retains the content-preservation guard. Test mode follows the same setting.
9. **Core ML prototype.** Added an explicit CPU/CoreML voice-probe comparison,
   with compiled caches keyed by model weight hash and ORT version. The
   CoreML-enabled session was slower here, so production remains CPU.
10. **Startup reliability.** A packaged smoke check exposed window-dependent
    bootstrap: a second/windowless process could start without its services.
    AppDelegate now starts one idempotent bootstrap and owns shutdown. Test
    mode starts its endpoint without database setup or automatic model updates.
    Failed benchmark startup retains its diagnostic directory.

## Verification and measured limits

- Swift: **414 tests, 14 skipped, zero failures**.
- Rust: **119 library + two helper + one integration passed**, one ignored.
- STT: **37 passed**, one ignored.
- Python reference/tooling: **42 tests**, one skipped, zero failures.
- Packaging: **six isolated authenticated-helper API checks passed**.
- Apple speech: a paced synthetic audio stream passed the real Apple-service
  integration test, including finalization. A separate file-path smoke fixture
  had **0 word errors across 23 reference words**. This is one TTS sentence,
  not an estimate of your accent/noise accuracy, false wakes or general WER.
- Signed candidate: **36 intent requests parsed and 36 planning requests
  planned**, over **12 unique commands**, three rounds. No Execute-mode
  side effects. Observed intent median **89 ms**; plan median **0 ms** means
  below integer timer resolution. This is one launch and a smoke corpus,
  not a new comparative speed or whole-voice latency result. Windowless test
  startup differs from earlier GUI benchmarks; do not compare idle memory.
- **All 13 intent model files are byte-identical** to the installed app.
  The accepted Run 6 weights and 0.75 serving threshold remain unchanged.
  The saved 272-case development report did not yield an eligible threshold
  under the calibration tool's configured confidence-bound/error criteria.
- Strict deep bundle signature verification passed; `git diff --check` clean.

Core ML experiment: three synthetic clips repeated three times per provider,
one CPU session followed by one CoreML-enabled session. Median embedding
request (decode + frontend + encoder) was **17.59 ms CPU**
and **44.78 ms Core ML**. Maximum absolute
embedding difference was **4.47e-08**.
Provider registration does not prove full Neural Engine placement. This does
not measure human-speaker false acceptance/rejection or comparative RAM.
[Interactive measurements](coreml-prototype-20261109.html).

## Candidate and follow-up

Signed candidate: `.build/Jarvis.app`, UUID
`F3F0764A-B339-3A76-B0DD-8100BEBE4BAC`, 280,763,168 regular-file bytes.
The installed `/Applications/Jarvis.app` remains UUID
`F553D6DD-AA43-3DFD-AA61-AE922B7C6F62`. Existing running processes were not replaced;
only test processes launched for this work were stopped.

Remaining experiments need user-recorded, reviewed examples: live endpoint
latency, accent/background-noise accuracy, false wake rate, speaker decision
boundaries, and total app/OS-service memory. Review corrections before creating
new training shards. A new learned classifier, additional inference process
isolation or an accelerated production backend should be promoted only after
those measurements justify it. No Moonshine weights/runtime were installed.

See [architecture](architecture.md), [routine behavior](routines.md), and the
adjacent machine-readable report. Private raw evidence is under ignored
`logs/`: runtime-apple-shared-policy-20261109.json,
coreml-voice-prototype-20261109.json, run6-confidence-risk-20261109.json,
apple-speech-pipeline-evaluation-20261109.json and
system-improvements-model-parity-20261109.json. Development Python tests used
the training venv; its missing python-multipart test dependency was installed.

Primary API references:
[Apple SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/),
[Apple input-format contract](https://developer.apple.com/documentation/speech/analyzerinput),
[ONNX Runtime Core ML](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html).
