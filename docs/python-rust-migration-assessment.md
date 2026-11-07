# Further Rust migration assessment — 2026-11-07

The shipped Python backend can be replaced incrementally by Rust orchestration
and native inference libraries. Preserving functionality is a verification
requirement, not an automatic consequence of changing language. Keep offline
training/export tooling in Python and macOS UI/hardware adapters in Swift.
No runtime migration or new performance measurement was performed in this audit.

## Current implementation

- `backend/intent_router_model.py`: lazy-loaded quantized T5 encoder and merged
  decoder, CPU ONNX Runtime, SentencePiece, brace-token handling, greedy decoding,
  decoder/cross-attention caches, confidence calculation and JSON response.
  The numerical model kernels already execute in native ONNX Runtime.
- `backend/intent_model_store.py`: manifest/file verification, managed release
  selection, checksums and last-good receipts. Must accompany native inference.
- `backend/voice_auth_service.py`: FastAPI service combining voice enrollment and
  verification, Spotify OAuth/search/API compatibility routes, health and
  PostgreSQL connection management. Voice work is deliberately lazy-loaded and
  uses a bounded single-worker queue.
- `backend/runtime_config.py`, `local_auth.py`: mutable configuration, credential
  broker client, legacy environment parsing, rotating local API authentication
  and expiring single-use OAuth state. Retain the signed app's Keychain broker.
- `training/`: model training, ONNX export/quantization, dataset generation and
  evaluation. These tools do not need to ship with the app.

## Measured size opportunity

Read-only inventory of `.build/Jarvis.app` on this date, sum of regular file
lengths, excluding symlink targets; decimal MB, not compressed download size:

| Area | Bytes | MB |
|---|---:|---:|
| Entire candidate bundle | 1,305,860,814 | 1,305.9 |
| Python environment | 1,035,054,606 | 1,035.1 |
| Model assets | 205,718,302 | 205.7 |
| Native executable and scripts | 50,412,633 | 50.4 |
| Other resources and signature | 14,675,273 | 14.7 |

Python site-packages independently totaled 1,035,029,695 bytes. Largest folders:
torch 426.3 MB, llvmlite 131.4 MB, scipy 98.8 MB, onnxruntime 82.4 MB, sympy
75.3 MB, sklearn 47.3 MB, numpy 34.2 MB and numba 29.3 MB. Folder sizes are
observations, not evidence that each package can be safely removed individually.
The Python environment is about 79.3% of this bundle. Its full size is not the
net saving: ONNX Runtime, tokenization, voice model weights, codecs and other
native replacement dependencies still need packaging. Quantized T5 weights
remain necessary. Do not promise a final bundle size before a native build.

## Recommended migration sequence

1. **Native intent inference proof, then cutover.** Retain Run 6 ONNX weights,
   CPU provider and numerical settings initially. Rust can drive ONNX Runtime
   through its C API or a pinned, reviewed community Rust binding, and use the
   original SentencePiece C++ engine through a narrow bridge. Preserve every
   tokenization/decoding/cache/confidence detail above, input/output limits,
   concurrency admission, fallback behavior and managed-model rollback. Run
   Python and native inference side by side before switching. Removing local
   HTTP requires an in-process FFI integration; a Rust HTTP server alone does
   not remove that overhead. Do inference off the UI thread. Python remains
   necessary for voice verification during this stage, so do not claim removal
   of the whole environment yet.
2. **Backend services and lifecycle.** Port still-used Spotify resolution/OAuth,
   settings, PostgreSQL connection checks, local authentication and model status
   contracts into Rust. Preserve current native macOS Spotify playback; audit
   callers before retiring API compatibility routes. Preserve request limits,
   errors, token expiry/state consumption, credential brokerage, cancellation,
   and startup/stop behavior. Existing clients may use a compatible Rust service
   during transition; choose in-process calls where they actually simplify it.
3. **Voice verification.** Export the existing Resemblyzer speaker encoder for
   native inference as a feasibility experiment, without retraining or changing
   speaker architecture. Match audio decoding, resampling, volume normalization,
   WebRTC voice activity detection, silence handling, mel features, overlapping
   partial slices, embedding normalization and weighted cosine scoring. Existing
   256-dimensional `.npy` enrollments must stay readable. Export compatibility
   and numerical equivalence are unproven; retaining Python is the fallback if
   native verification fails parity. Re-enrollment is not an acceptable silent
   workaround for a behavior-preserving migration.
4. **Remove shipped Python only after all runtime callers migrate.** Replace the
   venv/package/launcher path, retain license notices and native dependencies,
   verify signing and clean-machine launch, then remeasure bundle, backend plus
   app RSS, cold/warm latency and CPU. Keep Python in the development workflow.

The first stage offers reduced interpreter/request overhead for intent parsing;
the last stages unlock the major dependency-size opportunity. Neither implies
better model accuracy. Model matrix operations already use native libraries;
large inference speedups cannot be inferred from Python-versus-Rust alone.

## Additional Swift candidates

- Finish the shared Rust action/intent contract and migrate remaining planner,
  fast-path and intent-mapping policy. The existing Rust action enum lacks newer
  browser-destination, workspace, search/result and other action families despite
  several corresponding parsers already being Rust. Preserve precedence and
  literal arguments; do not just remove Swift branches or flip a global flag.
- Extract project-name matching and bounded traversal policy from
  `ProjectDirectoryResolver`; keep native bookmark/security-scoped access and
  locale-sensitive presentation sorting in Swift. Filesystem latency may dominate;
  measure traversal/caching before expecting a Rust speed benefit.
- Stats aggregation and its durable upload outbox are portable but lower priority.
  Preserve stable retry IDs, crash recovery, legacy JSON and timezone/day boundaries.
  Existing Rust queue, automation matching/persistence and intent JSONL logging
  already cover parts of the app; avoid duplicating those migrations.

Keep SwiftUI/AppKit, Accessibility, native Spotify control, CoreAudio, display
control, security-scoped bookmarks, permissions and Keychain ownership native.

## Acceptance evidence for each cutover

- Compare raw generated token IDs, output JSON/actions and failure/fallback
  decisions on existing and fresh held-out commands, including long input,
  punctuation, Unicode, exact file/project/song names and confidence boundaries.
  Allow explicit numerical tolerances for floating-point intermediates, while
  investigating any changed generated token or acceptance decision.
- For voice, compare fixed audio across sample rates, silence/noise and multiple
  speakers against existing enrolled profiles. Measure same/different-speaker
  decisions and false accept/reject rates, especially near current thresholds;
  check malformed uploads, queue saturation, cancellation and profile reset.
- Benchmark matched release configurations on the same hardware. Separate
  tokenizer, encoder, per-token decoder, full parse and full voice-command latency.
  Measure cold/warm cases and total app/helper memory; publish regressions as well
  as gains. Retain a rollback until parity and useful benefits are established.

## Primary references checked

- [ONNX Runtime APIs](https://onnxruntime.ai/docs/api/): C/C++ APIs and community
  Rust API listing.
- [ONNX Runtime C++ integration](https://onnxruntime.ai/docs/get-started/with-cpp.html):
  the C++ interface wraps the C API.
- [Google SentencePiece native library](https://github.com/google/sentencepiece/blob/master/doc/cli.md).
- [Resemblyzer encoder implementation](https://github.com/resemble-ai/Resemblyzer/blob/master/resemblyzer/voice_encoder.py).
- [Resemblyzer audio preprocessing](https://github.com/resemble-ai/Resemblyzer/blob/master/resemblyzer/audio.py).

Size baseline and prior executable comparison:
[installed versus Rust candidate benchmark](rust-app-benchmark-20261107.md).
