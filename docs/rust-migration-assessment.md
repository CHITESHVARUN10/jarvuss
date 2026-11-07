# Rust migration assessment — 2026-11-07

Selective migration is worthwhile for shared pure logic and measured hot paths.
A language-percentage target is not a product-performance target. Keep SwiftUI,
AppKit, accessibility, audio/hardware adapters, permissions and Keychain brokerage
in Swift unless a specific replacement demonstrates an advantage.

## First completed slice: app-name resolution

Rust now owns the alias table, exact lookup and fuzzy resolution in both routing
modes. Swift retains three small adapters and native app launching. Removed the
second Swift alias table and fuzzy resolver, fixed missing Edge/Arc aliases in
Rust, and aligned normalization and unknown-input behavior with Swift. Exact
known-app lookup still never guesses. Bindings regenerate through the existing
build script. No global Rust-pipeline toggle was enabled.

Tests cover all 62 preexisting aliases, punctuation/case, exact versus fuzzy
lookup, unknown/empty preservation and bridge integration. Full Swift suite:
382 tests, 10 skipped, zero failures. Rust: 61 unit tests passed, one ignored,
plus one integration test passed. No commit or installed-app replacement here.

## Measured implementation performance

| Operation | Previous Swift | Rust including UniFFI | Ratio |
|---|---:|---:|---:|
| Exact app aliases | 2.87 µs | 0.93 µs | 3.1× |
| Fuzzy / unknown names | 68.16 µs | 31.40 µs | 2.2× |

These are warm in-process calls: optimized Swift (-O) versus release Rust,
seven alternating rounds, each repeating a small corpus 300 times, median of
round means. Raw timings, environment and baseline snapshot hash are in
[rust-migration-benchmark.json](rust-migration-benchmark.json). The temporary
standalone harness and baseline snapshot remain under `.build/rust-audit/`.
The final small parity corpus has 19 cases and zero differences. The earlier
Rust implementation had five Edge/Arc differences; those were corrected before
cutover. The 62-alias tests provide broader exact-alias coverage, not proof of
exhaustive equivalence for arbitrary fuzzy inputs. Rust gives deterministic
alias-table tie order; previous Swift dictionary iteration did not promise it.

This is an implementation comparison, not a language shootout: Rust caches its
regexes and the previous Swift path uses Foundation replacement calls. Swift
could also be optimized. Savings are microseconds, not a demonstrated change in
speech/model/app-launch latency. Memory, cold startup, battery use and binary
size deltas were not benchmarked; no improvement is claimed for them.

## Why the repository still has substantial Swift

Source audit before this slice, excluding generated bridge code: about 30,685
Swift lines (145 files), including 11,313 UI lines. Rust command core has 4,230
lines and STT Rust core 3,399 lines. These are filesystem source counts, not
GitHub Linguist percentages. Existing safety, quick-info and command-priority
policies already use Rust independently of the wider migration switch. Other
routing and persistence paths remain conditional. The old Rust action contract
still lacks some newer Swift-native families; enabling the whole flag is not an
acceptable shortcut to migration.

Disk allocation inspection of the installed debug/development bundle showed
roughly 1.03 GiB for the Python venv and 196 MiB for model assets, versus about
43 MiB under MacOS for executable/scripts. These are approximate du measurements,
not download sizes or a before/after experiment. Moving small Swift parsers
cannot remove those model/dependency assets. A separately scoped native inference
or dependency-packaging project has much greater size potential; voice-auth and
other Python users would need independent replacement or retention.

## Recommended remaining order

1. Port pure workspace/project, volume, shuffle and search parsing behind typed
   Rust requests. Preserve current fixtures, safety decisions and native adapters.
2. Extend Rust action/intent contracts for current capabilities before broader
   router cutover; test both modes and remove duplicate Swift logic only after
   parity. Send a complete command/plan across FFI rather than many tiny calls.
3. Centralize shared routine validation, matching, normalization and persistence
   where this removes real duplication. Avoid wrapping an Apple API in Rust just
   to change the language count.
4. Profile end-to-end speech, model invocation, filesystem search and UI work.
   Benchmark release builds on the same hardware/workload before promising gains.
5. Investigate Python-dependency/inference packaging separately if smaller app
   size is a priority; preserve model decoding, voice verification and credentials.

Rust ownership catches important lifetime/aliasing errors at compile time, but
permissions, network/player state, filesystem changes and incorrect model plans
remain runtime failures in either language. Swift is already compiled and offers
memory/type safety. There is no established guarantee that an LLM will produce
better application code simply because it is Rust.

References: [Swift overview](https://www.swift.org/about/),
[Rust ownership](https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html),
[GitHub repository languages](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-repository-languages).
