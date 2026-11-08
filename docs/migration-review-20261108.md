# Review of the latest Rust migrations

Reviewed source at `2fc101e`, the latest owner-local handoff entries, and the
changes since `0576986`. The working tree was clean before review. Scope:
dictation formatting/polish/lifecycle changes, intent cache/unload changes,
website routing, project traversal, text distance, configuration/SQL adapters,
packaging, and CI. This was a targeted source and regression review, not a
complete audit of every application feature.

## Fixed findings

- **Unicode edit distance:** Rust grapheme slices compared bytes; Swift
  Characters compare canonical Unicode equivalents. `café` and `cafe\u{301}`
  incorrectly had distance one. Normalize to NFC before distance computation;
  retain real accent differences. Accented Latin and decomposed Hangul tests
  failed before the fix and pass afterward.
- **Project-name matching:** filtering individual scalars dropped a decomposed
  accent before matching a composed query. Normalize before filtering so the
  same accented name matches across filesystem/text representations. A
  temporary-folder test failed before the fix.
- **Hidden-file budget:** Rust counted hidden entries before excluding them,
  unlike Foundation's `skipsHiddenFiles`. Hidden metadata could exhaust the
  lookup budget even with only one visible project. Exclude hidden names before
  counting; continue checking the deadline within each directory. A test with
  five hidden entries and one visible project failed before the fix.
- **Direct-lookup errors:** recursive fallback discarded a direct-pass error,
  potentially masking an offline root behind an unrelated entry-limit error.
  Propagate errors like the earlier throwing Swift implementation. A two-root
  test failed before the fix.
- **Swift adapter boundaries:** restore cancellation checks before and after
  lookup, clamp large limits instead of trapping in UInt32 conversion, and
  activate saved alias bookmark access as well as root access during lookup.
  Swift tests cover cancellation and Int.max limits. Actual security-scoped
  external-volume access was not exercised.
- **CI build command:** the default `swift test` reproduced the duplicate
  modulemap error documented in the handoff. Update the workflow to
  `swift test --build-system native`, matching the packaging workaround.

## Verification

- Rebuilt the release Rust bridge and generated bindings.
- `cargo test --locked --manifest-path rust-core/Cargo.toml`: 116 library,
  two helper, and one integration tests passed; one library test ignored.
- `zsh scripts/test_stt.zsh`: 37 passed, one ignored.
- `swift test --build-system native`: 397 executed, 13 skipped, zero failures.
- Python backend discovery with PYTHONPATH unset: 64 executed, one skipped,
  zero failures.
- `git diff --check`: clean.

No new performance or model-accuracy claim follows from these fixes. Live
microphone capture, insertion into another application, real Spotify playback,
database provisioning and external-drive bookmark permissions remain manual or
opt-in integration checks. Native lookup observes cancellation at the Swift
boundary; it does not poll Swift task cancellation during traversal. Its
deadline is checked between filesystem operations, which cannot interrupt a
blocked filesystem call.

No app packaging/installation, Git commit, training or publication was performed.
