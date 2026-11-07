# Installed Jarvis versus Rust candidate — 2026-11-07

The migrated policies are faster in the measured workloads. The app produces the same tested plans, its bundle is slightly larger, and these samples do not establish a memory or startup improvement. The signed candidate is built at `.build/Jarvis.app`; the installed `/Applications/Jarvis.app` was preserved and restored to normal operation.

## Actual app comparison

The installed app is the routines build (`74485e7b3d9f+modified`, UUID `A3964B47-37EC-35A8-97CD-88F4E414D15E`). Its Rust-pipeline setting was already enabled: it was a hybrid, with the newly migrated policy functions still in Swift. The candidate is `8540cc1e563b+modified`, UUID `A4296311-BE97-3A68-B193-63922F7C0DB4`. Both use the existing debug Swift packaging and release Rust native libraries.

Both actual executables were launched in their existing `--test-mode`. Only `plan` requests were sent: no songs were played, websites opened, files opened, or model/STT calls intentionally exercised. Eighteen scenarios were warmed once and repeated in seven shuffled rounds across two separate launches per build (252 measured requests per build). The same scenarios/order were used for each.

| Measurement | Installed app | Rust candidate |
|---|---:|---:|
| Test-runner round-trip median | 6.33 ms | 2.47 ms |
| Test-runner round-trip p95 | 7.90 ms | 6.29 ms |
| Server-reported mean elapsedMs | 0.917 ms | 0.179 ms |
| Exact reference plans, unique examples | 17/18 | 17/18 |
| Matching plans between builds | — | 18/18 |
| Warm RSS, per-launch medians | 127.1–133.8 MiB | 132.5–133.0 MiB |
| Test-runner-ready time, per-launch range | 471–686 ms | 456–799 ms |

Client timing includes HTTP, diagnostic logging, polling and UI scheduling. It is **test-runner interaction latency**, not voice-command latency. The harness records server durations as truncated integer milliseconds; zero means below its recorded resolution. Do not infer a precise server speed ratio from those means. Startup describes readiness of the test endpoint, not cold-boot or full UI readiness. RSS samples overlap, so no RAM/startup/battery improvement is claimed.

The one reference mismatch is unchanged song-title capitalization: the reference expects `Blinding Lights`; both builds plan `blinding lights`. The raw exact score retains that mismatch. Playback was not executed, so this is not a demonstrated playback failure. All 18 actual plans match between versions. This is a small synthetic planning test, not population accuracy.

## Isolated policy timing

Baseline policy source was reconstructed from commit `125a9eb` (the routines changes committed after the installed build). Because the installed build is marked modified, byte-identical source reconstruction cannot be proven. These source probes complement the separate actual-executable comparison above. Both policies run in the same process using identical inputs; result consumption is included. Nine alternating rounds use 128 corpus repetitions each, reporting the median block average per input. The Rust timing includes UniFFI and the Swift adapter. All results are warm, local, load-sensitive implementation measurements.

| Policy | Previous Swift, optimized | Rust + optimized adapter | Ratio |
|---|---:|---:|---:|
| System volume | 71.83 µs | 6.26 µs | 11.5× |
| Workspace parsing | 21.81 µs | 4.03 µs | 5.4× |
| Spotify shuffle | 22.44 µs | 3.09 µs | 7.3× |
| File search | 157.79 µs | 24.21 µs | 6.5× |
| Routine validation | 6.05 µs | 2.02 µs | 3.0× |
| Transcript policies | 58.55 µs | 5.25 µs | 11.2× |

An additional debug-configuration probe matches the configuration of the two packaged apps; its results are in the JSON report and interactive chart. The optimized probe shows gains persist with Swift optimization enabled. App-alias microtimings are excluded from this headline comparison because alias routing was already Rust-enabled in the installed app. Cached Rust regexes differ from the old Foundation implementation, so these results are not a universal language-speed comparison. The transcript group combines target normalization, phrase-loop removal and spoken-input cleanup per input.

## Bundle size and build verification

The regular-file inventory grew from **1300.37 MB to 1305.86 MB**: **+5.49 MB (+0.42%)**. Symlink targets are excluded; these are file lengths, not disk allocation or compressed-download sizes. The measured increase is in the native executable/scripts area; Python environment and model-asset byte counts are identical. This migration did not make the app smaller.

Both app signatures pass verification. The candidate executable UUID and all on-disk Mach-O sections match the compiled debug executable. Raw executable hashes differ from the unsigned/ad-hoc build because packaging signs the app; executable UUID/section checks account for this. All 12 runtime model artifacts match the installed Run 6 v1.0.2 manifest. The installed executable hash is unchanged.

## Correctness and reproducibility

The preceding migration verification also retained pre-migration outputs on 5,300 command cases, 491 routine/voice/batch rows, 15 Unicode cases and 1,584 expanded text/line-ending variants. The final migration suite passed 390 Swift tests (10 skipped) and 71 Rust tests (one ignored). These are compatibility checks, not a claim of improved learned-model accuracy. No model weights, speech model or training data changed for this benchmark.

Raw app runs, source snapshots, component samples, build logs, verification metadata, helper scripts and checksums are archived locally under ignored `logs/rust-app-benchmark-20261107/`. Public aggregate results are in [the JSON report](rust-app-benchmark-20261107.json); [the interactive comparison](rust-app-benchmark-20261107.html) switches between optimized and packaged-debug policy timings.

To repeat the pure-policy probes with Git history and native bridges available:

```sh
python3 scripts/benchmark_migrated_policies.py --configuration debug
python3 scripts/benchmark_migrated_policies.py --configuration release
```

The script generates a temporary XCTest source, preserves any existing file at that path, and removes its own fixture on completion or test failure. It executes no OS actions and changes no stored app settings. The default baseline is the pre-migration routines commit. Full actual-app tests also restart the app and use private local test-session authentication; their local driver is preserved with the raw evidence.

No Git commit, model training, Hugging Face publication or installed-app replacement was performed.
