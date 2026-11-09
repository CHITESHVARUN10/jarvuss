# Live speech alternatives — 8 November 2026

The current app uses `ggml-large-v3-turbo.bin`, about 1.624 GB on disk.
The [official Whisper Turbo card](https://huggingface.co/openai/whisper-large-v3-turbo)
lists 809 million parameters. The current Rust engine explicitly sets English,
even though the model supports many languages.

On this Mac, a fresh standalone Whisper process decoding one 3.221-second
synthetic command reached 1,742,864,384 bytes peak RSS and 1,780,746,280 bytes peak
footprint, loaded in 562 ms and decoded in 1,409 ms. This is a process-level,
single-clip observation, not whole-app RAM or an accuracy benchmark. Raw result:
`logs/whisper-current-20261108.json`.

Live command recognition is VAD-segmented Whisper, not incremental streaming:
`WhisperCommandListener` starts/stops utterances; `AppState` waits for 1.2 seconds
of silence and splits uninterrupted speech at eight seconds. STT partial preview
uses six-second chunks with one-second overlap. Final decoding, wake-word
matching and optional speaker verification add separate delay/failure points.
A faster recognizer alone will not fix bad segmentation or missed wake words.

## Candidates

| Model | Parameters | Fit | Important qualification |
| --- | ---: | --- | --- |
| Moonshine Medium Streaming | 245M | First candidate for low-memory English live dictation | Publisher reports 6.65% average English WER over eight datasets; shipped quantized LibriSpeech-clean WER is 2.17%, a different metric. No published Hindi STT model in the current catalog. |
| Nemotron 3.5 ASR Streaming | 600M | First candidate if both English and Hindi matter | True cached streaming, configurable 80–1120 ms chunks; English and Hindi are in its transcription-ready tier. Runtime integration and Mac memory still need measurement. |
| Parakeet TDT v3 | 600M | Strong candidate for completed English utterances / dictation | 25 European languages, no Hindi. Its batch model should not be confused with a native cache-aware streaming model; sliding-window wrappers exist. |

Sources: [Moonshine model catalog](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/),
[Moonshine deployed accuracy and methodology](https://moonshine-voice.readthedocs.io/en/latest/models/accuracy/),
[Nemotron model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
[Parakeet model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
These are publisher measurements, not Jarvis results or a common local comparison.

Moonshine offers native C/C++/ONNX runtime and macOS support. NVIDIA's
[NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp) provides native
GGUF/C ABI integration with CPU and Metal build options, avoiding a requirement
to ship NeMo/PyTorch. [FluidAudio](https://github.com/FluidInference/FluidAudio)
is another Apple-focused Core ML integration route. Verify the exact selected
model's runtime support and model license before adding it as a dependency.

## RAM and selection

Parameter count is not peak RAM: weight precision, encoder activations, audio
length, streaming caches, backend workspaces and GPU allocations matter. At
equal precision, 600M has about 74% of Turbo's parameter count and 245M about
30%; these are **weight-count ratios**, not promised memory savings. Quantized
weights and bounded streaming caches make fitting the current budget plausible,
but equal-or-lower peak RAM is not yet established on this Mac.

Recommended next experiment: compare Moonshine Medium Streaming (English) and
Nemotron 3.5 (English/Hindi) against Turbo using the same held-out recordings.
Measure WER and command success separately; include app names, project paths,
numbers, accents, noise, self-corrections and long uninterrupted speech. Record
first partial, finalization latency, peak process/Metal memory and false wake
activations. Benchmark the deployed quantization, not just a floating-point card.
Then integrate one recognizer behind the existing STT boundary, keeping model
selection reversible. No replacement weights were downloaded or activated in
this task; the requested research does not establish a universal accuracy winner.
