# Remaining pure-policy Rust migration — 2026-11-08

Completed the safe, parity-testable Swift→Rust cutovers identified in the
follow-up audit. Apple/UI adapters remain native. The app-level benchmark is
linked below; inference and planning were not on the migrated paths, so the
expected result is no meaningful change.

## Moved to Rust

| Module | Swift adapter | Responsibility |
|---|---|---|
| `rust-core/src/dictation.rs` | `STT/TranscriptFormatter.swift`, `STT/DictationPolisher.swift` | Dictation rules pass, list-directive decision, polish wrapper/meta/length guards, capitalization, drift allowance |
| `rust-core/src/text_distance.rs` | `Utils/StringDistance.swift` | Grapheme-aware Levenshtein/similarity |
| `rust-core/src/open_target.rs` | `Commands/OpenTargetResolver.swift`, `Commands/FastPathRouter.swift`, `Commands/ActionPlanner+Rules.swift` | Site/browser tables, open-in-browser and local-dev URL/port parsing |
| `rust-core/src/env_policy.rs` | `Utils/DotEnvLoader.swift` | `.env` text parsing/quoting; file discovery stays Swift |
| `rust-core/src/postgres_sql.rs` | `Database/PostgresProvisioner.swift` | SQL builders, quoting, password generation, plan validation, failure redaction; psql execution stays Swift |
| `rust-core/src/project_policy.rs` | `Workspace/ProjectLocations.swift` | Bounded project traversal, alias/root matching, exclusions, canonical containment; security-scoped bookmarks stay Swift |

About 990 Swift lines were removed and the migrated behaviour now has Rust unit
coverage in addition to the existing Swift suites. No UI, Accessibility,
AppleScript, CoreAudio, display, Keychain, security-scoped bookmark, Spotlight,
process execution or model-call ownership moved.

## Verification

- Rust: **111 passed, 0 failed, 1 ignored** (`cargo test --locked --manifest-path rust-core/Cargo.toml --lib`).
- Swift: **394 tests, 13 skipped, 0 failures** (`swift test --build-system native`).
- `git diff --check` clean.
- The existing `TranscriptFormatterTests`, `ListDirectiveTests`,
  `DictationPolisherTests`, `StringDistanceTests`, `ProjectWorkspaceTests` and
  the wider suite exercised the Rust adapters without test changes.

## App-level benchmark

Method: same signed candidate bundle family, local authenticated test runner,
Intent and Plan modes only (no Execute actions), warm medians after one warm-up
round. Baseline is the pre-migration `HEAD` rebuilt in a separate worktree and
launched through LaunchServices; post-migration is the rebuilt working tree.
Memory is RSS/physical footprint; separate processes are attributed separately.

| Metric | Before (median of 3 launches) | After (median of 5 launches) |
|---|---:|---:|
| Bundle | 301.82 MiB | 301.77 MiB |
| App idle footprint | 43.0 MiB | 62.0 MiB (first launch 43.0) |
| App idle RSS | 113.5 MiB | 133.1 MiB (first launch 114.7) |
| Intent-loaded footprint | 716.0 MiB | 698.0 MiB |
| Intent-loaded RSS | 801.8 MiB | 784.6 MiB |
| Intent warm median | 111 ms | 111 ms |
| Intent model median | 104.0 ms | 106.5 ms |
| Plan warm median | 1 ms | 1 ms |
| Voice native warm median | 19.9 ms | 24.7 ms |
| Voice native helper RSS | 104.2 MiB | 102.3 MiB |
| Whisper load / transcribe | 464 / 1344 ms | 440 / 1384 ms |
| Whisper peak footprint | 1780.2 MB | 1780.7 MB |
| Qwen 1.5B warm median / RSS | 121.9 ms / 1136.9 MiB | 130.5 ms / 1136.9 MiB |

Interpretation: Intent and Plan are unchanged at the median; they are not on
the migrated text/policy paths. Loaded memory differences are smaller than the
observed launch-to-launch spread (baseline loaded RSS 782–806 MiB, post
692–786 MiB). Idle memory moved in the opposite direction; the first post
launch matched the baseline. The voice benchmark slowed for **both** Python and
native runtimes in the post run (Python 40.8→46.3 ms, native 19.9→24.7 ms),
consistent with machine load rather than the unchanged voice code. No claim of
a speed, memory or battery improvement is made for these cutovers.

Reports and chart:
- `docs/runtime-baseline-20261108.html`
- `docs/runtime-comparison-20261108.html`
- `logs/runtime-baseline-median.json`, `logs/runtime-post-median.json`
- `logs/voice-baseline-20261108.json`, `logs/voice-post-20261108.json`

## Build notes discovered during this work

- Swift 6.4.2's default SwiftPM `swiftbuild` planner produces a duplicate
  `module.modulemap` for the two static xcframeworks. Packaging/tests use
  `--build-system native`.
- The same toolchain can emit a corrupt proc-macro dylib (`pest_derive`) with
  the release profile's default `strip=debuginfo`. `rust-core/Cargo.toml` now
  sets `[profile.release.build-override] strip = "none"`; library/binary
  stripping is unchanged.
- `stt-core/examples/transcribe_file.rs` now prints load/transcribe timings for
  the benchmark, with no runtime-app behaviour change.

## Still native or not yet migrated

- Full Rust `PlannedAction` contract and pre-model planner orchestration. The
  Swift planner interleaves async model calls/cancellation with policy, and the
  Rust action enum still lacks workspace/search-result/settings/file-query
  families. This is the largest remaining policy project; porting it needs a
  complete action contract and differential tests before deleting Swift rules.
- `FileExplorer` Q&A, stats aggregation/upload outbox, intent-model update
  policy, enrollment scoring policy beyond StringDistance, and audio DSP.
- In-process backend calls (removing loopback HTTP for Spotify/Postgres/voice)
  and Keychain-owning process boundaries. Keep Keychain/security-scoped access
  with the signed Swift app.
- SwiftUI/AppKit, Accessibility, AppleScript, CoreAudio, DisplayServices,
  Spotlight/MDQuery, TCC and process execution remain native adapters.

## 2026-11-08 performance/memory follow-up

The installed build is now a release Swift build with the optimized Rust core.

- **Release packaging**: package script builds `-c release`; app binary
  55.4→20 MB, installed bundle 303→269 MB, idle 133→110 MiB RSS (62→43 MiB
  footprint).
- **ORT intent arena**: disabled by default (`JARVIS_INTENT_ARENA=1` opts back
  in). It was observed growing to 2.3 GB with two threads; per-run allocation
  keeps the resident peak stable at ~700 MiB. No intent-memory leak: 695→697 MiB
  across 36 repeated runs.
- **Intent result cache**: 64 entries, exact-text keyed, cleared on model
  change/unload. First occurrence is real inference (~90 ms); repeats are cache
  hits (~0 ms). `JARVIS_INTENT_CACHE=0` bypasses it for diagnostics.
- **Idle residency**: intent model 120 s (checked every 30 s), backend helper 120 s.
  STT model stays at 300 s: the 120 s experiment caused cold Whisper reloads before dictation. Intent unload is followed by
  `malloc_zone_pressure_relief`; the next command reloads in ~415 ms. ORT still
  retains allocator pages after unload, so the process footprint does not return
  all the way to idle.
- **Project traversal**: child paths are already canonical under a canonical
  root with symlinks skipped, so the per-entry `canonicalize` syscall was
  removed.
- **Threads**: intent 5, Whisper 4. Whisper 2/4/6/8/10-thread runs were flat
  (1.29–1.31 s for the synthetic clip).
- **Dictation regression fix**: the 120 s STT idle caused cold Whisper reloads;
  STT is back to 300 s. A repeated hotkey press during the polish pass used to
  dismiss the card and invalidate the pending insertion; presses during
  `formattingInProgress` are now ignored and the result still inserts. Added
  `PillLifecycleTests.testHotkeyDuringPolishDoesNotCancelThePendingInsertion`.
  Insert logs showed `ax_trusted=1`; the missing paste was cancellation, not TCC.
- **Insertion latency**: the final text is pasted before the popup publishes it;
  the native insert reuses one clipboard instance; the card hard-cap cannot
  dismiss a card while polish is active (it reschedules), so it cannot invalidate
  the pending paste. `dictation_insert.jsonl` now records `transcript_ms` and
  `insert_ms` to separate polish/UI time from the actual clipboard+⌘V call.

Measured after optimization: intent raw median **90–93 ms** (was 111 ms), cached
repeats **~0 ms**, plan **0–1 ms**, idle **110.5 MiB RSS / 43 MiB footprint**.
Swift 394 tests / 13 skipped / 0 failures; Rust 112 passed / 1 ignored; STT 37
passed / 1 ignored. Installed build revision `125c199+modified`, executable UUID
`E371984B-B2F0-3948-A40A-393FD4EEEBEF`.
