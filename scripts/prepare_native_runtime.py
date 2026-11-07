#!/usr/bin/env python3
"""Build/stage native runtime assets using a development Python environment.
The app never invokes this script or installs Python at runtime.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOXR_URL = "https://files.pythonhosted.org/packages/ed/11/27cebce4a108f77afea7c80545115536b45e3f11ebfb914f638fdd9ba847/soxr-1.1.0.tar.gz"
SOXR_SHA = "9f228ae21c78fa9359ca98d8a5e8e91f30639e438e574133dace62c5b5309e44"
CHECKPOINT_SHA = "39373b86598fa3da9fcddee6142382efe09777e8d37dc9c0561f41f0070f134e"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, env=None):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True, env=env)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--destination", type=Path, required=True)
    p.add_argument("--work", type=Path, default=ROOT / ".build/native-voice")
    args = p.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    import resemblyzer
    import librosa
    import scipy.signal
    source = Path(resemblyzer.__file__).parent
    checkpoint = source / "pretrained.pt"
    if sha(checkpoint) != CHECKPOINT_SHA:
        raise SystemExit("Speaker weights differ from the verified reference; revalidate before packaging")
    graph = args.work / "speaker_encoder.onnx"
    export = args.work / "voice-export.json"
    if not graph.exists() or not export.exists() or json.loads(export.read_text())["checkpoint_sha256"] != CHECKPOINT_SHA or json.loads(export.read_text())["graph_sha256"] != sha(graph):
        run(sys.executable, ROOT / "training/export_voice_onnx.py", "--checkpoint", checkpoint, "--destination", args.work)
    frontend = dict(mel_filters=librosa.filters.mel(sr=16000, n_fft=400, n_mels=40).tolist(),
                    window=scipy.signal.get_window("hann", 400, fftbins=True).tolist(),
                    librosa_version=librosa.__version__)
    (args.work / "audio_frontend.json").write_text(json.dumps(frontend))
    archive = args.work / "source/soxr-1.1.0.tar.gz"
    archive.parent.mkdir(exist_ok=True)
    if not archive.exists() or sha(archive) != SOXR_SHA:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
        with urllib.request.urlopen(SOXR_URL, context=context, timeout=60) as response:
            data = response.read(2_000_001)
        if hashlib.sha256(data).hexdigest() != SOXR_SHA:
            raise SystemExit("libsoxr source checksum mismatch")
        archive.write_bytes(data)
    source_dir = archive.parent / "soxr-1.1.0"
    if not source_dir.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(archive.parent, filter="data")
    build = args.work / "soxr-build"
    run("cmake", "-S", source_dir / "libsoxr", "-B", build, "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON", "-DWITH_OPENMP=OFF", "-DWITH_LSR_BINDINGS=OFF",
        "-DBUILD_TESTS=OFF", "-DBUILD_EXAMPLES=OFF")
    run("cmake", "--build", build, "--parallel", "4")
    shutil.copy2(build / "src/libsoxr.dylib", args.work / "libsoxr.dylib")
    sound = importlib.metadata.distribution("soundfile")
    decoder = Path(sound.locate_file("_soundfile_data/libsndfile_arm64.dylib"))
    if not decoder.exists():
        raise SystemExit("Missing arm64 native audio decoder")
    shutil.copy2(decoder, args.work / decoder.name)
    # Test fixtures contain only synthetic speech. Build tools never record.
    audio = args.work / "audio"
    audio.mkdir(exist_ok=True)
    for voice in ("Samantha", "Daniel", "Fred"):
        path = audio / (voice.lower() + ".wav")
        if not path.exists():
            run("say", "-v", voice, "-o", path, "--file-format=WAVE", "--data-format=LEI16@16000",
                "Jarvis please open my portfolio project in Visual Studio Code. Then open a new tab in Brave and search for the weather tomorrow.")
    run("cargo", "build", "--locked", "--release", "--manifest-path", ROOT / "rust-core/Cargo.toml", "--bin", "voice-probe", "--bin", "jarvis-backend")
    # Cargo has now fetched the pinned SentencePiece source/notices, including
    # on a clean checkout; stage libraries before the native comparison runs.
    run(sys.executable, ROOT / "scripts/stage_native_inference.py", "--destination", args.destination)
    report_path = args.work / "parity-formats.json"
    run(sys.executable, ROOT / "scripts/compare_native_voice.py", "--audio", audio,
        "--model", args.work, "--output", report_path)
    report = json.loads(report_path.read_text())
    if report["cases"] < 36 or report["failed"] or report["changed_confidence"]:
        raise SystemExit("Native voice compatibility gate failed; existing application remains available")
    run(sys.executable, ROOT / "scripts/test_native_backend.py",
        env=dict(os.environ, JARVIS_NATIVE_TEST_RUNTIME=str(args.destination.resolve()),
                 JARVIS_NATIVE_TEST_VOICE=str(args.work.resolve())))
    approved_export = json.loads(export.read_text())
    approved_export.update(audio_preprocessing_verified=True,
                           runtime_cutover_approved_by_parity=True,
                           compatibility_report_sha256=sha(report_path))
    export.write_text(json.dumps(approved_export, indent=2) + "\n")
    destination = args.destination / "voice"
    destination.mkdir(exist_ok=True)
    names = ["speaker_encoder.onnx", "audio_frontend.json", "voice-export.json", "libsoxr.dylib", decoder.name]
    for name in names:
        shutil.copy2(args.work / name, destination / name)
    notices = destination / "notices"
    notices.mkdir(exist_ok=True)
    # Retain the full resampler source and rebuild recipe for the shared library.
    shutil.copy2(archive, notices / archive.name)
    for path in (source_dir / "libsoxr/LICENCE", source_dir / "libsoxr/COPYING.LGPL", source_dir / "cmake/LICENSE-PFFFT.txt", source_dir / "LICENSE.txt"):
        shutil.copy2(path, notices / (path.parent.name + "-" + path.name))
    for item in sound.files or []:
        if "license" in str(item).lower() and Path(sound.locate_file(item)).is_file():
            shutil.copy2(sound.locate_file(item), notices / ("soundfile-" + item.name))
    shutil.copy2(sound.locate_file("_soundfile_data/COPYING"), notices / "libsndfile-COPYING")
    (notices / "REBUILD.txt").write_text("libsoxr source: " + SOXR_URL + "\nSHA256: " + SOXR_SHA +
        "\nRebuild shared library using scripts/prepare_native_runtime.py and its CMake options.\n" +
        "libsndfile 1.2.0 source: https://github.com/libsndfile/libsndfile/releases/tag/1.2.0\n" +
        "Resemblyzer 0.1.4 encoder and audio algorithms: https://github.com/resemble-ai/Resemblyzer (Apache-2.0).\n" +
        "Native libraries remain separate dynamically loaded files.\n")
    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--format-version", "1",
                                                  "--manifest-path", str(ROOT / "rust-core/Cargo.toml")], cwd=ROOT))
    rust_notices = args.destination / "notices/rust"
    for package in metadata["packages"]:
        directory = Path(package["manifest_path"]).parent
        if package.get("source") is None:
            continue
        for path in directory.rglob("*"):
            if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "COPYING")):
                target = rust_notices / (package["name"] + "-" + package["version"]) / path.relative_to(directory)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
    shutil.copy2(ROOT / "docs/licenses/Resemblyzer-LICENSE.txt", notices / "Resemblyzer-APACHE-2.0.txt")
    manifest = dict(format_version=1, reference_checkpoint_sha256=CHECKPOINT_SHA,
                    file_hashes_stage="before code signing of native dylibs",
                    compatibility_report_sha256=sha(report_path), isolated_api_checks_passed=True,
                    voice_comparison=dict(cases=report["cases"], decisions=report["decisions"],
                                          max_embedding_delta=report["max_embedding_delta"], failed=0, changed_confidence=0),
                    files={name: sha(destination / name) for name in names})
    (destination / "native-voice-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Native voice assets verified and staged")


if __name__ == "__main__":
    main()
