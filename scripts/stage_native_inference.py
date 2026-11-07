#!/usr/bin/env python3
"""Stage pinned native inference binaries from the provisioned development wheel.

This is build tooling, never executed by the shipped application. No models or
credentials are changed. The Rust binding is pinned to the matching ORT ABI.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil

PINNED_ORT = "1.31.0"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--link-runtime", action="store_true", help="Share the existing library inside a bundle that retains Python")
    args = parser.parse_args()
    dist = importlib.metadata.distribution("onnxruntime")
    if dist.version != PINNED_ORT:
        raise SystemExit(f"Expected onnxruntime {PINNED_ORT}, found {dist.version}; update bindings and reverify parity before changing it.")
    source = Path(dist.locate_file(f"onnxruntime/capi/libonnxruntime.{PINNED_ORT}.dylib"))
    if not source.is_file():
        raise SystemExit("Missing macOS ONNX Runtime native library")
    args.destination.mkdir(parents=True, exist_ok=True)
    target = args.destination / source.name
    if args.link_runtime:
        # Keep this relative so copying the app to Applications remains valid.
        target.unlink(missing_ok=True)
        target.symlink_to(os.path.relpath(source.absolute(), args.destination.absolute()))
    else:
        if target.is_symlink():
            target.unlink()
        shutil.copy2(source, target)
    notices = args.destination / "notices"
    notices.mkdir(exist_ok=True)
    for name in ("LICENSE", "ThirdPartyNotices.txt"):
        path = Path(dist.locate_file("onnxruntime/" + name))
        if not path.is_file():
            raise SystemExit(f"Missing ONNX Runtime notice: {name}")
        shutil.copy2(path, notices / ("onnxruntime-" + name))
    cargo = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo")))
    sources = list((cargo / "registry/src").glob("*/sentencepiece-sys-0.14.0/source"))
    if len(sources) != 1:
        raise SystemExit("Build the pinned Rust core first to stage SentencePiece notices")
    for path in sources[0].rglob("LICENSE*"):
        if path.is_file():
            target = notices / "sentencepiece" / path.relative_to(sources[0])
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    for file in dist.files or []:
        name = str(file)
        if ".dist-info/" in name and any(k in file.name.upper() for k in ("LICENSE", "NOTICE", "THIRD_PARTY")):
            path = Path(dist.locate_file(file))
            if path.is_file():
                shutil.copy2(path, notices / file.name)
    manifest = {"onnxruntime_version": dist.version, "library": source.name,
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "source": "onnxruntime development wheel", "runtime_python_required": False}
    (args.destination / "runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest))


if __name__ == "__main__":
    main()
