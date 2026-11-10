# Runtime ownership

Swift owns SwiftUI/AppKit, Accessibility, Apple Events, permissions, Keychain,
audio-device capture, security-scoped bookmarks, Spotlight and hardware adapters.
Rust owns the portable command/action contract, parsing, model mapping,
validation, literal arguments, routine compilation, indexing and native model
inference. Offline training/export/evaluation tools remain Python; Python is not
shipped. `AppState(activateServices: false)` keeps unit tests free of audio,
Apple speech asset installation and service startup.

## Commands and inference

`ActionPlanner` coordinates asynchronous model calls. Its policy helpers and
`FastPathRouter` are adapters to Rust, including post-model fallback selection
and Ollama response parsing. Both former routing modes use this policy. Swift
presentation enums adapt the generated Rust actions; an unadaptable action
rejects the entire plan instead of dropping individual steps.

Native parsing precedes model admission for explicit commands. The learned
mapper re-parses supported families and obtains names from original clauses.
Unfamiliar song/file names cannot be replaced with invented generated arguments.
Exact URLs retain their path/query case. Quoted literals survive compound
splitting, while explicit negated actions do not become positive actions.
This is targeted deterministic interpretation, not universal natural-language
understanding or a newly trained classifier.

`CommandQueueManager` owns bounded admission, delivery-ID deduplication,
preemption and a watchdog. Native decoding has per-request cancellation checks
between inference steps; an individual running native kernel cannot be
interrupted by that flag. `InferenceBudget` limits concurrent intent, voice and
LLM jobs, prioritizes interactive waiting jobs, and refuses optional formatting
during speech or memory pressure. Ollama retains its cancellable single-flight
gate and request deadline. These bounds do not measure or cap an OS speech
service's or Ollama process's total memory.

`MemoryGuard` observes both app footprint and system memory-pressure signals.
Before its existing hard backstop, it suppresses optional work and requests
unloading idle intent and Whisper contexts. Active capture/inference is not
unloaded. Voice inference already runs in a bounded, separate Rust helper.
Additional process isolation of intent/STT remains a conditional future change;
there is no evidence here that another IPC hop improves normal performance.

## Live speech and dictation

Live listening defaults to Apple `SpeechAnalyzer`/`SpeechTranscriber`, using a
supported configured locale (default en-IN). macOS manages on-device language
assets. Preparation and recognition have separate cancellation generations.
`MicManager` supplies the existing tap: copied buffers go through a bounded
serial format-conversion queue to a bounded analyzer stream. Unsupported audio
layouts fail before entering Apple's trapping initializer. Pre-roll is queued
before tap delivery. Partial results replace overlapping hypotheses. A pause
(650 ms) ends an utterance; finalization drains accepted audio/results before
one command handoff. Continuous speech is bounded at 45 seconds; failed or
stuck sessions produce an error rather than partial command execution.

Voice & speech → Recognition selects Apple/Whisper and the locale; restart listening
to apply it. The Whisper fallback keeps its existing VAD path. Shortcut
recordings continue through Rust/Whisper, with `STTRouter` owning their separate
dictation/action roles. A modal shortcut cancels any live Apple session first.
No Moonshine runtime or weights were installed.

Rules formatting is the dictation default. Optional AI formatting is explicitly
enabled in System and passes the existing lexical preservation guard. Model
formatting cannot silently alter content. Dismissing a session invalidates its
pending formatting/insertion; no late result can paste into a later session.

## Effects and routines

`ActionResult`/`ControllerResult` distinguish `verified`, `submitted`,
`unavailable` and `failed`. Success still means the controller accepted/completed
its supported operation; verification describes the available evidence.
Browser creation, Finder/Terminal project checks and hardware volume use their
existing readback. VS Code project submission and playlist identity are not
represented as fully verified. Spotify remains entirely native, without OAuth.

Routine steps compile to the same Rust action contract as ordinary commands.
`requiresPreviousSuccess` skips a step after a failed/skipped predecessor;
independent steps still run. Old routines default to independent steps. There
are no automatic retries or rollback of already completed external effects.
New unverified execution events are excluded from automatic positive training
pairs; historical logs retain their earlier interpretation. Reviewed corrections
are separate and never automatically trained.

## Projects

Swift resolves bookmarks and retains scoped access during lookup. Rust owns a
bounded four-entry directory index with a 30-second fallback TTL. Filesystem
(FSEvents), saved-location and volume events invalidate it. Root/selected-path
availability is checked; direct-child and alias precedence are retained. First
index construction is still a bounded traversal, and blocked filesystem calls
cannot be interrupted by a user-space deadline.

## Diagnostics, evaluation and updates

`PipelineTrace` carries a request ID from Apple live speech or shortcut capture
through verification, queued command work, planning and execution. New pipeline
events contain metadata/timing by default and rotate to one predecessor.
Existing command logs and opt-in dictation text diagnostics remain separate.
Settings → General → Advanced & safeguards → Correct a command writes a private reviewed record with the associated
request ID when available. Nothing uploads or starts training from this UI.

`evaluate_pipeline.py` separates WER, exact plans, verified effects and p50/p95
latency. `calibrate_intent.py` reads development predictions, reports confidence
risk/coverage with sample-size bounds and never changes thresholds. Existing
model integrity, audit evidence and rollback checks remain required. Run 6
weights and the serving threshold are unchanged.

Statistics retain their serialized persistence and UUID-deduplicated PostgreSQL
outbox. The native helper retains local-token authentication, signed Keychain
brokerage and atomic voice-profile storage. Stable signing and clean bundle
verification remain packaging requirements.

## Experimental acceleration

`voice-probe MODEL_DIRECTORY ORT_LIBRARY [cpu|coreml]` can explicitly test Core
ML. Compiled caches are keyed by encoder weight hash and ORT version; unavailable
provider registration is an error. Production always selects the verified CPU
path. The prototype was slower on the tested synthetic clips, so it is not
promoted. See `system-improvements-20261109.md` for evidence and limitations.

## Desktop interface

The Obsidian UI uses a native SwiftUI/AppKit shell with a compact navigation rail,
a command session, and an adaptive inspector. Appearance has its own destination;
Settings groups General, Setup, and About. Core service configuration lives in
General. Pages use the window width and native scroll indicators.

The assistant orb alone uses the approved offline Three.js renderer in a
transparent WKWebView. Its local assets and MIT license are packaged explicitly.
The renderer receives validated appearance settings, never command text or
credentials, and its content security policy blocks networking. It pauses when
hidden and is destroyed when leaving the page. All other UI remains native.
See [Obsidian UI](obsidian-ui-20261109.md) for validation and implementation details.
