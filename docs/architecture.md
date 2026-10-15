# Runtime ownership

`AppState` owns published UI state and service wiring. Its command, enrollment,
verification, and connection extensions keep those flows separate. Planner
models, fast paths, media parsing, device controls, and general rules are in
separate files. Services can be injected without starting the microphone or
backend by constructing `AppState` with `activateServices: false`.

## Commands and inference

- `CommandQueueManager` owns command admission and its watchdog. Preemption
  and expiry cancel the active task and invalidate its UI generation.
- `ActionExecutor` checks cancellation between actions and returns step results.
  Main-actor callbacks are awaited. Opening an app waits for launch readiness;
  other actions do not incur an arbitrary delay.
- `CommandOutcome` distinguishes success, partial failure, failure and
  cancellation. One terminal event supplies command metrics and training input.
- `InferenceGate` serializes Ollama work in FIFO order. The wall-clock deadline
  includes gate admission and HTTP generation. Both support cancellation.
- The Swift HTTP client owns inference in both routing modes. Rust owns safety,
  priority and instant information patterns; Swift adapts application types.
  Remaining routing migration differences use the same JSON fixtures in Swift
  and Rust (`Tests/JarvisMacOSTests/Fixtures/command_policy.json`).

Cancellation prevents subsequent actions. An operation already accepted by
another application or a remote API may have completed before cancellation.

## Dictation

Each Rust recording has a monotonically increasing session ID. Cancelling a
recording invalidates queued inference and callbacks. Swift checks that ID
again after dispatching callbacks onto the main queue. Polishing has its own
generation check and cancellable task, so dismissing one card and starting
another cannot insert the earlier result.

## Statistics

`StatsRecorder` serializes its state and persistence on one queue. Events are
batched in memory for up to one second (or 64 events); shutdown flushes them
immediately. Day rollover rotates snapshots without taking recursive locks.

Persisted batches have stable UUIDs. PostgreSQL accepts a UUID and adds its
delta in one statement. Replaying the UUID does nothing. The outbox removes
only acknowledged IDs, preserving events recorded during an upload. Failures
and disabled logging leave data available for retry. A periodic retry also
runs when no new usage events arrive. A corrupt outbox is retained and logged,
rather than silently overwritten.

## Configuration and Python workers

`backend/runtime_config.py` and Swift's `RuntimeConfiguration` share the
`local.jarvis.credentials` Keychain service. Secrets never enter JSON settings,
shell source files, or process arguments. Persisted settings override `.env`
and inherited defaults. Legacy files are read as data and left untouched;
packaging migrates existing local credentials and voice profiles before
removing their generated copies from the bundle.

The voice encoder runs on one dedicated worker with bounded admission.
Enrollment, verification and reset share that worker; slow CPU inference does
not block the ASGI event loop. Voice-profile writes use atomic replacement in
Application Support. Model inference tests use fakes; quality still needs
evaluation with real audio.

## Build compatibility

The minimum OS is macOS 26.0 in SwiftPM, Info.plist, Cargo and native build
scripts. `scripts/macos_toolchain.zsh` selects a matching Xcode compiler and SDK
for native compilation. Rebuild both XCFrameworks after Rust or bridge changes.
