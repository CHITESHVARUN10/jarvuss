# Installed versus candidate — 9 November 2026

The candidate improves literal preservation and runtime structure. These measurements do **not** show a meaningful raw intent inference speedup. Loaded/peak memory and bundle size are slightly higher.

## Exact builds

- Installed: `/Applications/Jarvis.app`, UUID `F553D6DD-AA43-3DFD-AA61-AE922B7C6F62`.
- Candidate: `.build/Jarvis.app`, UUID `F3F0764A-B339-3A76-B0DD-8100BEBE4BAC`.
- All 13 intent-model files are unchanged. No installation, commit or training.

Both report version **1.0 (build 1)**. Installed source stamp: `9c74339494e7+modified` (8 November); candidate: `bfb18db58a56+modified` (9 November). UUIDs identify the actual tested executables.

## Measurements

| Metric | Installed | Candidate | New − old |
|---|---:|---:|---:|
| Fresh model-session request | 369.00 ms | 371.00 ms | +2.00 ms |
| Warm intent median | 84.00 ms | 83.50 ms | -0.50 ms |
| Warm intent p95 | 164.00 ms | 164.00 ms | +0.00 ms |
| Planning median | 0.00 ms | 0.00 ms | +0.00 ms |
| Planning p95 | 165.00 ms | 166.00 ms | +1.00 ms |
| Idle footprint before intent | 42.66 MiB | 42.22 MiB | -0.44 MiB |
| Idle RSS before intent | 110.27 MiB | 109.14 MiB | -1.12 MiB |
| Intent-loaded footprint | 701.30 MiB | 718.24 MiB | +16.94 MiB |
| Intent-loaded RSS | 782.95 MiB | 799.88 MiB | +16.92 MiB |
| Median peak footprint | 705.39 MiB | 722.25 MiB | +16.86 MiB |
| Worst peak footprint | 721.39 MiB | 735.85 MiB | +14.45 MiB |
| Sampled peak RSS | 787.25 MiB | 803.31 MiB | +16.06 MiB |
| Footprint after idle unload¹ | 459.56 MiB | 486.78 MiB | +27.22 MiB |
| RSS after idle unload¹ | 602.30 MiB | 625.61 MiB | +23.31 MiB |
| Request after idle unload¹ | 1547.00 ms | 1579.00 ms | +32.00 ms |
| Idle CPU before load | 19.14 % of one core | 17.26 % of one core | -1.88 % of one core |
| Idle CPU while model resident | 17.72 % of one core | 17.10 % of one core | -0.63 % of one core |
| Active inference CPU | 414.82 % of one core | 408.39 % of one core | -6.43 % of one core |
| CPU time per intent | 552.18 CPU ms | 552.08 CPU ms | -0.10 CPU ms |
| CPU time per planning request | 192.86 CPU ms | 150.74 CPU ms | -42.12 CPU ms |
| Bundle regular-file size | 280.39 MB | 280.76 MB | +0.37 MB |

¹ One final process/build observed through at least 155 seconds of inactivity, followed by a reload request. Automatic unload reduces memory but does not restore the fresh-start baseline. A repeatable remaining opportunity is to investigate retained allocator/runtime memory or isolate inference in a restartable worker.

Three fresh LaunchServices launches/build, order old–new / new–old / old–new; isolated data directories; same 12 commands × five intent rounds and three planning rounds per launch. Thus 180 timed intent and 108 planning requests/build, not 288 unique commands. No Execute mode, microphone capture, file writes requested through the app, Spotify commands or database operations. Startup settles for ten seconds; idle windows last five seconds. Candidate test mode omits background database/model-update setup, so these are controlled pipeline tests, not a complete normal-use energy benchmark.

Footprint is the kernel-reported app memory charge. RSS includes resident/shared pages. Kernel lifetime footprint peaks and 20ms-sampled RSS peaks are distinct. CPU uses Mach tick counters converted with this Mac’s 125/3 ns timebase, cross-checked against process CPU time; 100% means one core, not the whole 10-core Mac. [Apple kernel counter implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c).

The same selected intent weights and CPU inference backend are used in both builds. These timings do not measure better learned accuracy. Small timing differences overlap launch variation and do not establish a general speed benefit. Planning differences on the 108 paired requests: 0.

## Functional differences observed

These five additional targeted probes are examples, not an unbiased accuracy benchmark. Three expose corrected literal casing; two retain their earlier plan.

- `create file CaseSensitive.TXT`
  - Installed: `Create file 'caseSensitive.TXT'`
  - Candidate: `Create file 'CaseSensitive.TXT'`

- `search Google for CaseSensitive_API`
  - Installed: `Search Google for 'caseSensitive_API'`
  - Candidate: `Search Google for 'CaseSensitive_API'`

- `open https://example.com/MyCase?q=AB in Brave`
  - Installed: `Open URL in Brave Browser: https://example.com/mycase?q=ab`
  - Candidate: `Open URL in Brave Browser: https://example.com/MyCase?q=AB`

- `play Zéphyr_42 by AB`
  - Installed: `Media: play song 'Zéphyr_42 by AB'`
  - Candidate: `Media: play song 'Zéphyr_42 by AB'`

- `open Chrome and set volume to 25`
  - Installed: `Open 'Google Chrome'; Volume: set to 25%`
  - Candidate: `Open 'Google Chrome'; Volume: set to 25%`

## Separate speech-component experiment

Same 3.221-second synthetic English recording; three fresh probe processes per engine in alternating order. All six probes passed. Median final decoding: Whisper 1300.0 ms; Apple file analysis 76.8 ms.

Separate synthetic file component experiment, not exact bundle A/B or live latency. Whisper uses the unchanged native engine; Apple models/services are OS-managed. RAM/CPU not compared because Apple work occurs outside the probe process.

Whisper final timing excludes its separately reported model load. Apple final timing starts after asset availability checks but includes analyzer work; its service/model caches can persist across processes. These timing boundaries and runtime placement differ. This is a component experiment, not a claim that live Jarvis is faster by this ratio. No accuracy or equal-RAM conclusion follows from one synthetic sentence.

Raw evidence: ignored `logs/release-comparison-20261109/`. Reproduction harness: `scripts/benchmark_release_comparison.py`. CPU conversion is recorded in the JSON. The initial direct/headless baseline launch did not start its test endpoint; fresh LaunchServices `-F` launches succeeded, and all comparison rounds used that method. Installed bundle and existing user process remain unchanged.
