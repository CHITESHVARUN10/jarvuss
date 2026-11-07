# Pure command-policy migration — 2026-11-07

Completed the five agreed areas in order. Each cutover passed differential
checks against frozen pre-migration Swift outputs before the next cutover.
These are source changes; the installed app was not replaced, no Git commit was
made, and no model training or Hugging Face publication occurred.

## Ownership

| Order | Rust implementation | Swift responsibility |
|---|---|---|
| 1 | `system_volume.rs`: whole-command routing, spoken numbers, absolute/delta amounts, bounds | Typed action adapter and native CoreAudio control |
| 2 | `workspace.rs`: app/operation recognition, project names/roots, command splitting | Native app identifiers and execution; composition with existing non-workspace fallback routes |
| 3 | `shuffle.rs`: current/liked/playlist targeting, exact names, shuffle mode, compound boundaries | Native Spotify controller |
| 4 | `local_search.rs`: literal queries, content/name mode, types, scopes, dates, byte limits, result selection | Spotlight predicates, calendar intervals, file-result UI, permissions and opening files |
| 5 | `routine_policy.rs` and `transcript.rs`: validation codes, required values, website input validation, normalization, repetition removal, batch conflict/capping policy | UI messages, Foundation URL serialization, logging delivery, existing final command admission |

`text_policy.rs` provides cached application regexes, character-count and
Foundation-compatibility primitives. Rust requests and outcomes cross UniFFI as
typed records/enums; the bridge generation script prefixes all new APIs/types.
The older global routing switch remains unchanged. Existing legacy fallback and
command-admission policies were not globally replaced or enabled.

## Compatibility details

- Distinguish volume changes **to** a level from changes **by** an amount; reject
  unsupported/out-of-range values and Spotify-specific volume commands.
- Preserve project roots, app destinations, playlist names, file-search literals,
  Unicode spelling and case. A second unrelated command stays with the compound
  planner instead of becoming part of a playlist name or search query.
- Keep exact native file-size rounding and overflow rejection, date/filter
  precedence, scope limits and one-based result selection.
- Normalize misheard names only in explicit app/destination slots. Project names,
  file names, search text and dictation prose are not fuzzy-rewritten.
- Preserve Foundation whitespace distinctions, including U+200B trimming and
  horizontal versus newline whitespace. NSRegularExpression capture end bounds
  differ from Swift String range/replacement APIs; the Rust helpers model those
  separately. This was verified against the original Swift implementation.
- Use canonical Unicode comparison where Swift String equality did, while
  retaining the original text in commands, literals and diagnostics.
- Keep repeated side-effect commands in order. Last-wins conflict handling applies
  only to matching app targets, and existing batch limits/log messages remain.
- Invalid nonpositive repetition thresholds and negative batch limits return
  safely rather than risking division/range failures. Existing valid custom
  repetition settings retain their prior normalization behavior.

Rust owns routine validation decisions; localized/presentation messages remain
in Swift. Foundation serializes approved website URLs to preserve native URL
formatting. macOS operations, credentials, accessibility, audio and UI lifecycles
remain native adapters. No operating-system actions are performed by these new
Rust policy modules.

## Verification

- Full Swift suite with frozen migration checks enabled: **390 tests, 10 skipped,
  zero failures**.
- Rust: **70 unit tests passed, one ignored; one integration test passed**.
- Frozen pre-migration comparisons: **5,300 commands**, **491 routine/voice/batch
  rows**, and **15 Unicode/repetition cases**, with no final differences.
- Additional standalone comparison against the original Swift transcript policy:
  **1,584 text/whitespace/line-ending variants**, with no final differences.
- Native bridge rebuilt in release mode; `git diff --check` passed.

Permanent Rust contract tests, existing authored-corpus Swift tests and
`RustPurePolicyTests` run without local snapshots. `PureMigrationParityTests`
provides three extra opt-in differential checks when `JARVIS_PURE_PARITY=1` and
local snapshots are available. It cannot regenerate or overwrite the baseline.
Raw local snapshots, test logs, the standalone original-Swift reference/harness
and their hashes are archived in ignored `logs/rust-pure-migration-20261107/`.
They are local evidence, not public dataset additions. To repeat the opt-in tests
after cleaning `.build`, restore the archived JSON snapshots into
`.build/pure-migration/` first. Run:

```sh
./scripts/build_rust_core.sh --release
cargo test --locked --manifest-path rust-core/Cargo.toml
JARVIS_PURE_PARITY=1 swift test
```

A machine-readable summary and source/evidence hashes are in
[rust-pure-policy-migration.json](rust-pure-policy-migration.json).
These checks measure compatibility, not end-to-end app speed, battery use or
memory improvements. Live playback, browser windows and filesystem opening were
not exercised during this migration; existing live tests remain opt-in.
