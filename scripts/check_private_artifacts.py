#!/usr/bin/env python3
"""Reject personal speaker profiles in source checkouts and app bundles.

Only paths are inspected or reported, never biometric contents. Runtime profiles
in Application Support are intentionally outside the inspected roots.
"""
import argparse
from pathlib import Path
import subprocess

PRIVATE_NAMES = {"embeddings.npy", "voice_profiles.npy", "speaker_embeddings.npy", "voice_profiles.lock"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.bundle:
        paths = (path for path in args.bundle.rglob("*") if path.name in PRIVATE_NAMES)
    else:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
        paths = (root / name.decode() for name in tracked if name and Path(name.decode()).name in PRIVATE_NAMES)
    found = [path for path in paths if path.exists() or path.is_symlink()]
    for path in found:
        print(f"Personal voice profile must not ship: {path}")
    if found:
        return 1
    print("PASS: no personal voice profiles in " + ("app bundle" if args.bundle else "source checkout"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
