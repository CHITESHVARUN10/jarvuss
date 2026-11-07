#!/usr/bin/env python3
"""Offline experimental voice parity using supplied synthetic audio fixtures.
Never reads or writes user enrollments or invokes a microphone.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--audio", type=Path, required=True)
    p.add_argument("--model", type=Path, default=ROOT / ".build/native-voice")
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    import numpy as np
    import librosa
    import soundfile as sf
    import onnxruntime as ort
    from resemblyzer import VoiceEncoder, preprocess_wav
    sys.path.insert(0, str(ROOT / "backend"))
    from voice_auth_service import _trim_silence, _normalize_volume, _cosine_similarity, _compute_weighted_score
    encoder = VoiceEncoder(device="cpu", verbose=False)
    variants = args.model / "variants"
    variants.mkdir(parents=True, exist_ok=True)
    fixtures = []
    rng = np.random.default_rng(20261107)
    for path in sorted(args.audio.glob("*.wav")):
        wav, rate = sf.read(path, dtype="float32")
        if wav.ndim != 1 or rate != 16000:
            raise ValueError("Use mono 16 kHz source fixtures")
        for name, samples in [("normal", wav), ("quiet", wav * 0.01),
                              ("noise", wav + rng.normal(0, 0.0005, wav.shape).astype(np.float32)),
                              ("padding", np.pad(wav, (16000, 32000))), ("short", wav[:32000])]:
            destination = variants / f"{path.stem}-{name}.wav"
            sf.write(destination, samples, 16000, subtype="FLOAT")
            fixtures.append(destination)
        for rate in (8000, 22050, 44100, 48000):
            destination = variants / f"{path.stem}-{rate}.wav"
            samples = librosa.resample(wav, orig_sr=16000, target_sr=rate)
            sf.write(destination, samples, rate, subtype="PCM_16")
            fixtures.append(destination)
        for extension, subtype in (("flac", "PCM_16"), ("ogg", "VORBIS")):
            destination = variants / f"{path.stem}.{extension}"
            sf.write(destination, wav, 16000, subtype=subtype)
            fixtures.append(destination)
        destination = variants / f"{path.stem}-stereo.wav"
        sf.write(destination, np.stack((wav, wav * 0.7), axis=1), 16000, subtype="FLOAT")
        fixtures.append(destination)
    library = next((Path(ort.__file__).parent / "capi").glob("libonnxruntime.*.dylib"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    records = []
    with args.output.with_suffix(".native.log").open("w") as log:
        process = subprocess.Popen([str(ROOT / "rust-core/target/release/voice-probe"),
                                    str(args.model), str(library)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
        try:
            for path in fixtures:
                start = time.perf_counter()
                wav = _normalize_volume(_trim_silence(preprocess_wav(path)))
                reference = encoder.embed_utterance(wav).astype(np.float32)
                elapsed = (time.perf_counter() - start) * 1000
                process.stdin.write(json.dumps(str(path)) + "\n")
                process.stdin.flush()
                response = process.stdout.readline()
                if not response:
                    raise RuntimeError("Native voice probe exited")
                native = json.loads(response)
                current = native.get("result", {})
                vector = np.asarray(current.get("embedding", []), dtype=np.float32)
                delta = None if vector.shape != reference.shape else float(np.max(np.abs(vector-reference)))
                same_length = current.get("prepared_samples") == len(wav)
                records.append(dict(fixture=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                    reference=reference.tolist(), native=current,
                                    python_ms=elapsed, native_ms=native.get("elapsed_ms"),
                                    max_embedding_delta=delta, same_prepared_length=same_length,
                                    error=native.get("error")))
                print(path.name, "delta", delta, "same audio length", same_length, flush=True)
            process.stdin.close()
            if process.wait(timeout=30):
                raise RuntimeError("Native voice probe failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    decisions = []
    for record in records:
        if "embedding" not in record["native"]:
            continue
        vector = np.asarray(record["native"]["embedding"], dtype=np.float32)
        reference = np.asarray(record["reference"], dtype=np.float32)
        for profile in records:
            enrolled = np.asarray(profile["reference"], dtype=np.float32)
            old = _compute_weighted_score([_cosine_similarity(reference, enrolled)])
            new = _compute_weighted_score([_cosine_similarity(vector, enrolled)])
            decisions.append(dict(candidate=record["fixture"], profile=profile["fixture"],
                                  reference=old, native=new, same_confidence=old["confidence"] == new["confidence"]))
    failures = [r for r in records if r["max_embedding_delta"] is None or r["max_embedding_delta"] > 1e-4 or not r["same_prepared_length"]]
    report = dict(cases=len(records), failed=len(failures), decisions=len(decisions),
                  changed_confidence=sum(not d["same_confidence"] for d in decisions),
                  max_embedding_delta=max((r["max_embedding_delta"] or 0 for r in records), default=0),
                  complete_audio_format_coverage=False, production_cutover=False,
                  note="Synthetic speech, WAV/FLAC/OGG, mono/stereo and 8-48kHz. Saved-profile I/O, concurrent enrollment and broader speaker validation remain required.",
                  artifacts={path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in args.model.iterdir() if path.is_file() and path.suffix in (".onnx", ".dylib", ".json")
                             and path.name != args.output.name},
                  reference_source_sha256=hashlib.sha256((ROOT / "backend/voice_auth_service.py").read_bytes()).hexdigest(),
                  records=records, profile_decisions=decisions)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k:v for k,v in report.items() if k not in ["records","profile_decisions"]},indent=2))
    return bool(failures) or bool(report["changed_confidence"])


if __name__ == "__main__":
    raise SystemExit(main())
