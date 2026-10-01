#!/usr/bin/env python3
"""Generate the two post-training datasets Jarvis was missing.

Both files are written in the hand-authored dataset schema
(`{"text", "intents"}` per line) and are picked up automatically by
`prepare_data.py`, which globs `dataset/train*.jsonl`.

  train-061-files.jsonl     file exploration  (count / list / size / oldest / newest / open)
  train-062-compound.jsonl  multi-intent compound commands (2-4 ordered intents)

The model had ZERO multi-intent examples before this — every existing shard is
single-intent — which is why "open spotify, open whatsapp and also open youtube
and in spotify play a song" never produced a plan.

Usage:
    python generate_datasets.py            # write both files
    python generate_datasets.py --check    # validate the written files only
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET_DIR = os.path.join(ROOT, "dataset")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")
SEED = 20261001

FILES_PATH = os.path.join(DATASET_DIR, "train-061-files.jsonl")
COMPOUND_PATH = os.path.join(DATASET_DIR, "train-062-compound.jsonl")


# ── schema helper ───────────────────────────────────────────────────────────

def load_schema() -> dict:
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return json.load(f)["intents"]


def intent(intent_name: str, /, **args) -> dict:
    """Build one intent. The first parameter is positional-only so arg keys
    like `name` (app.open) can never collide with it."""
    return {"name": intent_name, "args": args}


def validate_row(row: dict, schema: dict) -> list[str]:
    """Mirror prepare_data.canonicalize's checks so a bad row never lands."""
    errors: list[str] = []
    intents = row.get("intents")
    if not isinstance(row.get("text"), str) or not row["text"].strip():
        errors.append("empty text")
    if not isinstance(intents, list) or not intents:
        errors.append("empty intents")
        return errors
    for i, item in enumerate(intents):
        name = item.get("name")
        args = item.get("args", {})
        if name not in schema:
            errors.append(f"[{i}] unknown intent {name!r}")
            continue
        spec = schema[name]
        unknown = set(args) - set(spec["args"])
        missing = set(spec["args"]) - set(args)
        if unknown:
            errors.append(f"[{i}] {name}: unexpected args {sorted(unknown)}")
        if missing:
            errors.append(f"[{i}] {name}: missing args {sorted(missing)}")
        for arg, expected in spec["types"].items():
            if arg not in args:
                continue
            value = args[arg]
            if expected == "int" and not isinstance(value, int):
                errors.append(f"[{i}] {name}.{arg}: expected int")
            if expected == "str" and not isinstance(value, str):
                errors.append(f"[{i}] {name}.{arg}: expected str")
    return errors


# ── dataset 1: file exploration ─────────────────────────────────────────────

FOLDERS = ["downloads", "documents", "desktop", "pictures", "movies", "music"]

EXTENSIONS = ["pdf", "pptx", "docx", "xlsx", "csv", "txt", "png", "jpg", "mp4", "zip"]

FILLERS = ["", "jarvis ", "hey jarvis ", "please ", ""]

# op → templates. {folder} {ext} {Ext} are filled per row.
FILE_TEMPLATES: dict[str, list[str]] = {
    "count": [
        "how many files are there in my {folder} folder",
        "how many files are in {folder}",
        "how many {ext} files are in my {folder}",
        "count the files in {folder}",
        "count the {ext} files in my {folder} folder",
        "number of files in {folder}",
        "how many files do i have in {folder}",
        "tell me how many files are in {folder}",
        "what is the total number of files in {folder}",
        "how many files are in the {folder} folder",
        "lets see how many files are in {folder}",
        "how many {ext} files do i have in {folder}",
    ],
    "countFolders": [
        "how many folders are in {folder}",
        "how many folders are there in my {folder} folder",
        "count the folders in {folder}",
        "how many subfolders does {folder} have",
        "number of folders in my {folder}",
        "how many folders do i have in {folder}",
        "tell me how many folders are in {folder}",
        "how many folders does the {folder} folder have",
        "count how many folders are in my {folder} folder",
        "give me the number of folders in {folder}",
        "how many directories are in {folder}",
        "how many sub folders are in my {folder} folder",
        "what is the number of folders in {folder}",
        "how many folders sit inside {folder}",
        "tell me the folder count in {folder}",
        "how many folders are in my {folder}",
        "count subfolders in {folder}",
        "how many folders have i got in {folder}",
    ],
    "list": [
        "list the files in {folder}",
        "list all the files in my {folder} folder",
        "what files are in {folder}",
        "what are the files in my {folder} folder",
        "show me the files in {folder}",
        "show all {ext} files in {folder}",
        "tell me the names of the files in {folder}",
        "give me the list of files in {folder}",
        "which files are in my {folder} folder",
        "list the {ext} files in {folder}",
        "what {ext} files do i have in {folder}",
        "list everything in {folder}",
    ],
    "listFolders": [
        "list the folders in {folder}",
        "what folders are in {folder}",
        "what are the folders in my {folder} folder",
        "show me the folders in {folder}",
        "name the folders in {folder}",
        "which folders are in {folder}",
        "list all the folders in my {folder} folder",
        "give me the folder names in {folder}",
        "tell me the names of the folders in {folder}",
        "what folders do i have in {folder}",
        "list the subfolders in {folder}",
        "show all folders inside {folder}",
        "what subfolders does {folder} have",
        "list every folder in my {folder} folder",
        "tell me what folders are in {folder}",
        "list the directories in {folder}",
        "which subfolders are in {folder}",
        "give me a list of folders in {folder}",
    ],
    "largest": [
        "what is the biggest file in {folder}",
        "what is the largest file in my {folder} folder",
        "which is the biggest {ext} file in {folder}",
        "what is the heaviest file in {folder}",
        "show me the largest {ext} in {folder}",
        "which {ext} file in {folder} is the biggest",
    ],
    "oldest": [
        "what is the oldest file in {folder}",
        "what is the oldest {ext} i have in {folder}",
        "which is the oldest {ext} in my {folder} folder",
        "what is the earliest {ext} in {folder}",
        "tell me the oldest {ext} in {folder}",
        "which {ext} in {folder} is the oldest",
    ],
    "newest": [
        "what is the newest file in {folder}",
        "what is the latest {ext} i have",
        "what is the most recent {ext} in my {folder} folder",
        "which is the latest {ext} in {folder}",
        "what is the latest {ext} in {folder}",
        "tell me the newest {ext} in {folder}",
        "which {ext} did i add most recently in {folder}",
    ],
    "totalSize": [
        "how much space do my {ext} files take in {folder}",
        "what is the total size of the files in {folder}",
        "total size of {ext} files in {folder}",
        "how much space do the files in {folder} take up",
        "how big are the {ext} files in {folder} altogether",
    ],
    "openNewest": [
        "open the latest {ext} in {folder}",
        "open the most recent {ext} from my {folder} folder",
        "open the newest file in {folder}",
        "show me the recent {ext} in {folder}",
        "open the recent {ext} in my {folder} folder",
        "open the last {ext} i downloaded",
    ],
    "openOldest": [
        "open the oldest {ext} in {folder}",
        "open the earliest file in {folder}",
        "open the oldest file in my {folder} folder",
        "show me the oldest {ext} in {folder}",
    ],
}

# Ops where the extension slot is meaningful; ext-sensitive ops get an ext
# every time, the rest only sometimes (ext="" means "any file").
EXT_ALWAYS = {"oldest", "newest", "openNewest", "openOldest", "totalSize"}
EXT_SOMETIMES = {"count", "list", "largest"}


def build_file_rows(rng: random.Random) -> list[dict]:
    rows: list[dict] = []
    seen: set[str] = set()

    for op, templates in FILE_TEMPLATES.items():
        for template in templates:
            needs_ext = "{ext}" in template
            for folder in FOLDERS:
                exts = [""]
                if needs_ext or op in EXT_ALWAYS:
                    exts = EXTENSIONS
                elif op in EXT_SOMETIMES:
                    exts = [""] + rng.sample(EXTENSIONS, 4)

                for ext in exts:
                    text = template.format(folder=folder, ext=ext, Ext=ext.upper())
                    text = rng.choice(FILLERS) + text
                    text = text.strip()
                    if text in seen:
                        continue
                    seen.add(text)
                    rows.append({
                        "text": text,
                        "intents": [intent("files.query", op=op, folder=folder, ext=ext)],
                    })

    rng.shuffle(rows)
    return balanced(rows, per_op=FILES_PER_OP, rng=rng)


# Per-op cap so one verb ("count") cannot swamp the corpus — the model sees
# every file operation, not just the most-templated one.
FILES_PER_OP = 120


def balanced(rows: list[dict], per_op: int, rng: random.Random) -> list[dict]:
    """Keep at most `per_op` rows per `op` argument, then reshuffle."""
    buckets: dict[str, list[dict]] = {}
    for row in rows:
        op = row["intents"][0]["args"].get("op", "?")
        buckets.setdefault(op, []).append(row)

    kept: list[dict] = []
    for op, bucket in sorted(buckets.items()):
        rng.shuffle(bucket)
        kept.extend(bucket[:per_op])

    rng.shuffle(kept)
    return kept


# ── dataset 2: compound multi-intent ────────────────────────────────────────

APPS = ["Spotify", "Google Chrome", "WhatsApp", "Telegram", "Notes", "Mail",
        "Calendar", "Slack", "Notion", "Visual Studio Code", "Safari", "Music"]

SONGS = ["blinding lights", "shape of you", "wonderwall", "kesariya", "believer",
         "starboy", "levitating", "perfect", "heat waves", "jailer", "ordinary",
         "flowers", "as it was", "vaseegara", "tum hi ho"]

QUERIES = ["iphone 18 pro review", "best laptops 2026", "kotlin coroutines tutorial",
           "python pandas merge", "macbook air m5", "f1 highlights", "recipe for biryani"]

CONNECTORS = [" and ", ", ", " and then ", ", and also ", " and also ", " then "]


def build_compound_rows(rng: random.Random) -> list[dict]:
    rows: list[dict] = []
    seen: set[str] = set()

    def add(text: str, intents: list[dict]) -> None:
        text = text.strip()
        if not text or text in seen:
            return
        seen.add(text)
        rows.append({"text": text, "intents": intents})

    def join(parts: list[str]) -> str:
        """Join clauses with a natural connector, no connector before the first."""
        out = parts[0]
        for part in parts[1:]:
            out += rng.choice(CONNECTORS) + part
        return out

    # 1. open app + play a named song
    for app in APPS:
        for song in rng.sample(SONGS, 6):
            add(join([f"open {app}", f"play {song}"]),
                [intent("app.open", name=app), intent("media.play_song", title=song)])
    for app in APPS[:6]:
        for song in rng.sample(SONGS, 3):
            add(join([f"open {app}", f"play {song} on spotify"]),
                [intent("app.open", name=app), intent("media.play_song", title=song)])

    # 2. open two apps
    for _ in range(40):
        a, b = rng.sample(APPS, 2)
        add(join([f"open {a}", f"open {b}"]),
            [intent("app.open", name=a), intent("app.open", name=b)])
    for _ in range(20):
        a, b = rng.sample(APPS, 2)
        add(join([f"open {a}", f"open {b}"]).replace(f"open {b}", b),
            [intent("app.open", name=a), intent("app.open", name=b)])

    # 3. open app + brightness
    for app in rng.sample(APPS, 8):
        for pct in (5, 10, 15, 20, 25):
            add(join([f"open {app}", f"increase the brightness by {pct} percent"]),
                [intent("app.open", name=app), intent("display.brightness_up", by=pct)])
    for app in rng.sample(APPS, 6):
        for pct in (10, 20, 30):
            add(join([f"open {app}", f"decrease the brightness by {pct} percent"]),
                [intent("app.open", name=app), intent("display.brightness_down", by=pct)])
    for app in rng.sample(APPS, 6):
        for level in (40, 60, 70, 80):
            add(join([f"open {app}", f"set the brightness to {level}"]),
                [intent("app.open", name=app), intent("display.brightness_set", level=level)])

    # 4. open app + volume
    for app in rng.sample(APPS, 8):
        for pct in (10, 20, 30, 50):
            add(join([f"open {app}", f"increase the volume by {pct} percent"]),
                [intent("app.open", name=app), intent("volume.up", by=pct)])
    for app in rng.sample(APPS, 6):
        for level in (0, 20, 35, 50):
            add(join([f"open {app}", f"set the volume to {level}"]),
                [intent("app.open", name=app), intent("volume.set", level=level)])
    for app in rng.sample(APPS, 4):
        add(join([f"open {app}", "mute"]),
            [intent("app.open", name=app), intent("volume.mute")])

    # 5. open app + web search
    for app in rng.sample(APPS, 8):
        for query in rng.sample(QUERIES, 3):
            add(join([f"open {app}", f"search google for {query}"]),
                [intent("app.open", name=app), intent("web.search", engine="Google", query=query)])

    # 6. close then open
    for _ in range(20):
        a, b = rng.sample(APPS, 2)
        add(join([f"close {a}", f"open {b}"]),
            [intent("app.close", name=a), intent("app.open", name=b)])

    # 7. folder + file exploration
    for folder in ["downloads", "documents", "desktop"]:
        for ext in ["pdf", "pptx", "docx", "xlsx"]:
            add(join([f"open the {folder} folder", f"open the latest {ext}"]),
                [intent("folder.open", name=folder), intent("files.query", op="openNewest", folder=folder, ext=ext)])
            add(join([f"open the {folder} folder", f"tell me how many {ext} files are in it"]),
                [intent("folder.open", name=folder), intent("files.query", op="count", folder=folder, ext=ext)])
            add(join([f"open the {folder} folder", f"how many files are there"]),
                [intent("folder.open", name=folder), intent("files.query", op="count", folder=folder, ext="")])

    # 8. media control chains
    for song in rng.sample(SONGS, 6):
        add(join([f"play {song}", "turn the volume up"]),
            [intent("media.play_song", title=song), intent("volume.up", by=10)])
        add(join([f"play {song}", "increase the volume by 20 percent"]),
            [intent("media.play_song", title=song), intent("volume.up", by=20)])
    for _ in range(10):
        add(join(["play the next song", "turn the volume up"]),
            [intent("media.next"), intent("volume.up", by=10)])
    for _ in range(8):
        add(join(["pause the music", "open spotify"]),
            [intent("media.pause"), intent("app.open", name="Spotify")])

    # 9. three apps
    for _ in range(30):
        a, b, c = rng.sample(APPS, 3)
        add(join([f"open {a}", f"open {b}", f"open {c}"]),
            [intent("app.open", name=a), intent("app.open", name=b), intent("app.open", name=c)])

    # 10. app + app + media
    for _ in range(24):
        a, b = rng.sample(APPS, 2)
        song = rng.choice(SONGS)
        add(join([f"open {a}", f"open {b}", f"play {song}"]),
            [intent("app.open", name=a), intent("app.open", name=b),
             intent("media.play_song", title=song)])

    # 11. app + brightness + volume
    for _ in range(20):
        app = rng.choice(APPS)
        pct = rng.choice([5, 10, 15, 20])
        level = rng.choice([20, 30, 40, 50, 60])
        add(join([f"open {app}", f"increase the brightness by {pct} percent", f"set the volume to {level}"]),
            [intent("app.open", name=app), intent("display.brightness_up", by=pct),
             intent("volume.set", level=level)])

    # 12. the exact utterances that failed in the field, plus close variants
    add("open spotify, open whatsapp and also open youtube and in spotify play a song",
        [intent("app.open", name="Spotify"), intent("app.open", name="WhatsApp"),
         intent("app.open", name="YouTube"), intent("media.play")])
    add("Open Spotify and WhatsApp. Also open YouTube and play a song from Spotify.",
        [intent("app.open", name="Spotify"), intent("app.open", name="WhatsApp"),
         intent("app.open", name="YouTube"), intent("media.play")])
    add("Open Chrome and in Chrome open YouTube and in that search for iPhone. Thank you.",
        [intent("app.open", name="Google Chrome"), intent("web.search", engine="YouTube", query="iphone")])
    add("open spotify and also increase the brightness by 5% percent.",
        [intent("app.open", name="Spotify"), intent("display.brightness_up", by=5)])
    add("open spotify and play a song",
        [intent("app.open", name="Spotify"), intent("media.play")])
    add("jarvis open chrome, open telegram and play some music",
        [intent("app.open", name="Google Chrome"), intent("app.open", name="Telegram"),
         intent("media.play")])
    add("please open spotify and set the volume to 30",
        [intent("app.open", name="Spotify"), intent("volume.set", level=30)])
    add("open notes and increase the brightness by 10 percent",
        [intent("app.open", name="Notes"), intent("display.brightness_up", by=10)])
    add("open mail, open calendar and set the brightness to 70",
        [intent("app.open", name="Mail"), intent("app.open", name="Calendar"),
         intent("display.brightness_set", level=70)])
    add("open downloads, open the oldest pdf and tell me how many files are in downloads",
        [intent("folder.open", name="downloads"),
         intent("files.query", op="openOldest", folder="downloads", ext="pdf"),
         intent("files.query", op="count", folder="downloads", ext="")])

    # 13. four-intent chains
    for _ in range(24):
        a, b = rng.sample(APPS, 2)
        song = rng.choice(SONGS)
        pct = rng.choice([10, 15, 20])
        add(join([f"open {a}", f"open {b}", f"play {song}", f"increase the brightness by {pct} percent"]),
            [intent("app.open", name=a), intent("app.open", name=b),
             intent("media.play_song", title=song), intent("display.brightness_up", by=pct)])

    # 14. wider three- and four-step chains — the shape that failed in the field
    for _ in range(60):
        a, b = rng.sample(APPS, 2)
        add(join([f"open {a}", f"open {b}", "play some music"]),
            [intent("app.open", name=a), intent("app.open", name=b), intent("media.play")])
    for _ in range(40):
        a, b = rng.sample(APPS, 2)
        query = rng.choice(QUERIES)
        add(join([f"open {a}", f"open {b}", f"search google for {query}"]),
            [intent("app.open", name=a), intent("app.open", name=b),
             intent("web.search", engine="Google", query=query)])
    for _ in range(40):
        a = rng.choice(APPS)
        pct = rng.choice([5, 10, 15, 20])
        level = rng.choice([20, 30, 40, 50, 60, 70])
        add(join([f"open {a}", f"increase the brightness by {pct} percent", f"set the volume to {level}", "play some music"]),
            [intent("app.open", name=a), intent("display.brightness_up", by=pct),
             intent("volume.set", level=level), intent("media.play")])
    for _ in range(36):
        a, b, c = rng.sample(APPS, 3)
        add(join([f"open {a}", f"open {b}", f"open {c}", "set the volume to 40"]),
            [intent("app.open", name=a), intent("app.open", name=b),
             intent("app.open", name=c), intent("volume.set", level=40)])
    for _ in range(30):
        a, b = rng.sample(APPS, 2)
        pct = rng.choice([10, 20])
        add(join([f"open {a}", f"open {b}", f"decrease the brightness by {pct} percent", "pause the music"]),
            [intent("app.open", name=a), intent("app.open", name=b),
             intent("display.brightness_down", by=pct), intent("media.pause")])

    rng.shuffle(rows)
    return rows


# ── writing ─────────────────────────────────────────────────────────────────

def write(path: str, rows: list[dict], schema: dict) -> int:
    bad = 0
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            errors = validate_row(row, schema)
            if errors:
                bad += 1
                print(f"{os.path.basename(path)}: {errors} in {row['text']!r}", file=sys.stderr)
                continue
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return bad


def check(path: str, schema: dict) -> int:
    bad = 0
    total = 0
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            total += 1
            row = json.loads(line)
            for error in validate_row(row, schema):
                bad += 1
                print(f"{os.path.basename(path)}:{lineno}: {error}", file=sys.stderr)
    print(f"{os.path.basename(path)}: {total} rows, {bad} errors")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="validate existing files only")
    args = ap.parse_args()

    schema = load_schema()

    if args.check:
        bad = check(FILES_PATH, schema) + check(COMPOUND_PATH, schema)
        return 1 if bad else 0

    rng = random.Random(SEED)
    files_rows = build_file_rows(rng)
    compound_rows = build_compound_rows(rng)

    bad = write(FILES_PATH, files_rows, schema)
    bad += write(COMPOUND_PATH, compound_rows, schema)

    print(f"wrote {os.path.relpath(FILES_PATH, ROOT)}: {len(files_rows) - bad} rows")
    print(f"wrote {os.path.relpath(COMPOUND_PATH, ROOT)}: {len(compound_rows)} rows")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
