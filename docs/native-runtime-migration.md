# Native runtime migration — 2026-11-07

The candidate app uses Rust for intent inference and local backend services,
including voice enrollment and verification. It ships no Python interpreter,
venv, FastAPI, PyTorch, NumPy or librosa. Python remains in the repository for
training, export, evaluation and the development reference backend.

The signed candidate is `.build/Jarvis.app`. `/Applications/Jarvis.app` remains
the previous installed build and was restored running normally after checks.
No Git commit, model training, Hugging Face publication or installation occurred.

## Measured results

Same machine, same intent weights and existing speaker encoder; measurements
are scoped to the workload stated in each row. Decimal MB unless noted.

| Measurement | Python / installed reference | Native candidate |
|---|---:|---:|
| App regular-file size | 1,300.4 MB | 315.4 MB |
| Warm voice verification HTTP median | 39.85 ms | 18.58 ms |
| Voice-helper median sampled RSS | 425.3 MB | 102.0 MB |
| First voice request, final process launch | 1,248 ms | 77 ms |
| Helper endpoint ready, final process launch | 182 ms | 91 ms |
| Direct intent engine median, 704-case comparison | 85.78 ms | 85.46 ms |

The bundle is about **985 MB / 75.7% smaller**. Warm voice verification was
about **2.1× faster** in this test. First-request timing varied across launches:
an earlier native launch took about 1,263 ms, so no dependable cold-start ratio
is claimed. OS cache state was not reset between builds/runs.
Intent inference speed is essentially unchanged: both implementations use the
same CPU ONNX Runtime kernels. No model accuracy improvement is claimed.
The voice comparison includes the switch from PyTorch to ONNX Runtime and the
native audio implementation; it is not a general Rust-versus-Python speed ratio.

The HTTP voice benchmark used 36 synthetic speech fixtures and three synthetic
enrollments, one warm-up pass, seven shuffled rounds and alternating runtime
order: **252 measured requests per runtime, 252 identical response objects**,
including confidence and common app threshold decisions. It never used the
microphone or the user's enrollment. Raw `.build/native-migration/runtime-benchmark.json`
is archived under ignored `logs/native-runtime-migration-20261107/`.

RSS includes shared resident pages and is not physical unique memory, peak
memory or a battery measurement. Voice-helper figures exclude the main app.
Intent sessions now reside inside Jarvis. A separate packaged-app observation
after five matching intent-only requests measured native app RSS at 660.9 MB,
versus installed app 128.3 MB plus its Python intent helper 758.1 MB (886.4 MB
combined). This was one launch of each app; do not interpret it as a guaranteed
whole-app memory reduction across workloads. The earlier planning-only sample
and warm intent-loaded samples have different model residency.

Size is the sum of regular file lengths, excluding symlink targets; it is not
download size or disk allocation. Both bundles use the project's development
Swift build configuration. Signing and embedded native dependencies are included.

## What moved

- **Intent inference:** original SentencePiece C++ tokenizer through Rust, CPU
  ONNX Runtime 1.31, encoder, merged greedy decoder, self/cross-attention cache
  ownership, brace tokens, input/output bounds, confidence calculation and JSON
  decisions. Swift calls through UniFFI off the UI executor. The same selected
  Run 6 model remains in use; all intent model/tokenizer/manifest files match
  the installed bundle.
- **Model loading:** Rust verifies managed model manifests/checksums and immutable
  version directories, retains a working engine when an update fails, and uses
  last-good/bundled fallback on cold start. Inference is lazy, bounded and rejects
  overlapping work; idle sessions can unload after five minutes.
- **Connections:** Rust owns local HTTP authentication, expiring single-use OAuth
  state, Spotify token refresh and native playback metadata lookup, PostgreSQL
  settings/status/test and settings persistence. The signed app remains the
  Keychain owner; secrets stay out of settings JSON and process arguments.
  Spotify playback remains the existing native macOS controller.
- **Voice:** the existing Resemblyzer 0.1.4 speaker encoder was exported to FP32
  ONNX without training. Native libsndfile/libsoxr, WebRTC VAD, normalization,
  silence handling, Hann/mel features, partial slicing and embedding aggregation
  match the Python reference within measured floating-point tolerances. Rust
  retains the weighted cosine score and confidence thresholds, compatible NumPy
  enrollments, atomic saves/reset, one running job plus one waiting job, upload
  bounds and idle model unload.
- **Packaging/lifecycle:** `JarvisBackend` is bundled and starts on demand. Setup
  starts the included helper; it no longer installs Python. Native assets,
  dependency notices and resampler source/rebuild instructions ship separately.
  SwiftUI, AppKit, native playback, accessibility, microphone/hardware adapters,
  security-scoped bookmarks and permissions remain in Swift.

## Compatibility evidence

- 199-case intent comparison and separate 704-case comparison: zero input-token,
  generated-token, raw-output or admission differences. Maximum confidence
  difference was about 1.3e-13. Corpora overlap; these are comparison counts,
  not a claim of 903 unique commands or new predictive accuracy.
- The initial Rust binding's automatic hardware selection changed confidence.
  CPU selection is now explicit, matching Python. No changed scores were accepted
  as a replacement benchmark label.
- 36 voice fixtures: three synthetic speakers, normal/quiet/noisy/padded/short
  speech, WAV/FLAC/OGG, mono/stereo and 8/16/22.05/44.1/48 kHz. Preprocessed lengths
  match; maximum embedding component difference 2.69e-7. 1,296 single-profile
  comparisons retain confidence categories. The separate HTTP benchmark verifies
  multiple-enrollment scoring and app thresholds too.
- Existing float32 enrollments, legacy float64/Fortran-order and one-dimensional
  profiles remain readable. Native enrollment/reset writes ordinary float32 NPY
  files. Isolated integration checks exercise old-profile verification, new
  enrollment, reset and authentication without launching Python.
- 393 Swift tests, 10 skipped, zero failures; Rust 91 library tests plus two
  helper tests and one shared-policy integration test passed, one ignored;
  64 Python reference tests, one skipped; six isolated native-helper integration
  checks passed. Native profile/concurrency tests are included in the Rust count.
- Packaged candidate: 18/18 plans match the installed benchmark's plans across
  seven rounds. Both retain the existing case-only song-title reference mismatch.
  Five direct model requests match Python and the installed app exactly.
  Bundle/dependency signatures verify, no external symlinks escape the app, and
  no Python environment is present.

These are compatibility tests, not human biometric false-accept/false-reject
validation. Numerical parity does not establish speaker-verification security
against attacks. Live Spotify playback, real database connections and microphone
recognition were not exercised in this migration; their native adapters remain.

## Build and reproduce

```zsh
./scripts/package_jarvis_app.zsh --refresh-app --no-open
```

The build provisions export/reference tools in `.build/native-tools/venv`, runs
native voice comparison and stages checked assets in `.build/native-runtime`.
It preserves the previous development venv outside the bundle during the first
cutover. A clean build requires development Python 3.11+, Rust, the macOS
toolchain and CMake. Native dependency versions/source hashes are pinned;
the speaker checkpoint must match the verified reference. The app itself needs
none of those development tools installed to use its bundled features.

```zsh
source scripts/macos_toolchain.zsh
cargo test --locked --manifest-path rust-core/Cargo.toml
swift test
PYTHONPATH=training:backend .build/native-tools/venv/bin/python -m unittest discover -s backend/tests
python3 scripts/test_native_backend.py
.build/native-tools/venv/bin/python scripts/benchmark_native_runtime.py --output .build/native-migration/runtime-benchmark.json
```

The development reference retains legacy Web API player-write endpoints; the
app-facing Rust implementation uses metadata lookup and native playback only.
Python rollback modes require an explicitly provisioned development reference;
the shipped native bundle contains no Python worker. The previous installed app
remains available for user comparison. Offline training/export scripts and their
datasets were retained unchanged except for the new speaker-export tool.
