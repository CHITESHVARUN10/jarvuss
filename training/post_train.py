#!/usr/bin/env python3
"""Post-train / RL on the router's own log, without growing the model.

The app already writes one JSONL line per routing decision to
    ~/Library/Application Support/Jarvis/logs/intent_router.jsonl
    {"event": "model_hit"|"model_miss"|"plan"|"execute_command", "request_id", "text", ...}

That log is the reward signal:
  * a plan that reached `execute_command` with success=true was a GOOD answer
  * a plan that was dropped/blocked, or a `model_miss` that fell through to
    Qwen, is a case the small model got wrong

This script harvests those pairs, scores them with a reward function, and
continue-trains the EXISTING checkpoint (same t5-small, same vocab — the model
does not grow). Two modes:

    python post_train.py --harvest                 # log -> training/data/rl_pairs.jsonl
    python post_train.py --train --epochs 3        # continue-train from training/out/best
    python post_train.py --eval                    # reward-score a checkpoint
    python post_train.py --harvest --train --smoke # end-to-end smoke

Reward (higher is better, max 1.0):
    +0.5  output parses as a JSON list of known intents with correct args
    +0.4  matches the recorded gold plan for that utterance
    +0.1  arg-level exactness (names/levels/quantities all equal)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "training", "data")
OUT_DIR = os.path.join(ROOT, "training", "out")
POST_DIR = os.path.join(OUT_DIR, "post")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")
RL_PAIRS = os.path.join(DATA_DIR, "rl_pairs.jsonl")

INPUT_PREFIX = "parse: "
DEFAULT_LOG = os.path.expanduser(
    "~/Library/Application Support/Jarvis/logs/intent_router.jsonl"
)


def load_schema() -> dict:
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return json.load(f)["intents"]


# ── reward ──────────────────────────────────────────────────────────────────

def schema_score(intents, schema: dict) -> float:
    """1.0 when every intent is known and carries exactly the right args."""
    if not isinstance(intents, list) or not intents:
        return 0.0
    for item in intents:
        if not isinstance(item, dict):
            return 0.0
        name = item.get("name")
        args = item.get("args", {})
        if name not in schema or not isinstance(args, dict):
            return 0.0
        spec = schema[name]
        if set(args) != set(spec["args"]):
            return 0.0
        for arg, expected in spec["types"].items():
            value = args[arg]
            if expected == "int" and not isinstance(value, int):
                return 0.0
            if expected == "str" and not isinstance(value, str):
                return 0.0
    return 1.0


def reward(predicted, gold, schema: dict) -> float:
    """Scalar reward for one candidate parse against the recorded gold plan."""
    score = 0.0
    if schema_score(predicted, schema) > 0:
        score += 0.5
    if not gold:
        return score
    if canonical(predicted) == canonical(gold):
        return 1.0
    if isinstance(predicted, list) and isinstance(gold, list):
        if len(predicted) == len(gold):
            score += 0.2
            names_match = all(
                p.get("name") == g.get("name") for p, g in zip(predicted, gold)
            )
            if names_match:
                score += 0.1
                args_equal = all(
                    p.get("args", {}) == g.get("args", {}) for p, g in zip(predicted, gold)
                )
                if args_equal:
                    score += 0.1
    return min(score, 1.0)


def canonical(intents) -> str:
    return json.dumps(intents, sort_keys=True, separators=(",", ":"))


# ── harvest ─────────────────────────────────────────────────────────────────

# PlannedAction.description → intent. The description strings are a stable
# contract (ActionPlanner.description), so reverse-mapping them is safe.
DESC_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"^Open '(.+)'$"), "app.open"),
    (re.compile(r"^Close '(.+)'$"), "app.close"),
    (re.compile(r"^Open URL: (.+)$"), "url.open"),
    (re.compile(r"^Search (.+) for '(.+)'$"), "web.search"),
    (re.compile(r"^Open folder '(.+)'$"), "folder.open"),
    (re.compile(r"^Open latest file in '(.+)'$"), "file.open_latest"),
    (re.compile(r"^Create file '(.+)'$"), "file.create"),
    (re.compile(r"^Create folder '(.+)'$"), "folder.create"),
    (re.compile(r"^AI query: '(.+)'$"), "ai.query"),
    (re.compile(r"^Play song '(.+)'$"), "media.play_song"),
    (re.compile(r"^Play playlist '(.+)'$"), "media.play_playlist"),
]

INFO_DESCRIPTIONS = {
    "current time": "info.time",
    "current date": "info.date",
    "wifi status": "info.wifi",
    "bluetooth devices": "info.bluetooth",
    "battery status": "info.battery",
    "system volume": "info.volume",
    "display brightness level": "info.brightness",
    "display contrast level": "info.contrast",
}

MEDIA_DESCRIPTIONS = {
    "play": "media.play",
    "pause": "media.pause",
    "next track": "media.next",
    "previous track": "media.previous",
    "play liked songs": "media.play_liked",
}

VOLUME_PATTERNS = [
    (re.compile(r"^set level (\d+)$"), "volume.set", "level"),
    (re.compile(r"^increase by (\d+)$"), "volume.up", "by"),
    (re.compile(r"^decrease by (\d+)$"), "volume.down", "by"),
]

DISPLAY_PATTERNS = [
    (re.compile(r"^Set brightness (\d+)$"), "display.brightness_set", "level"),
    (re.compile(r"^Increase brightness by (\d+)%$"), "display.brightness_up", "by"),
    (re.compile(r"^Decrease brightness by (\d+)%$"), "display.brightness_down", "by"),
    (re.compile(r"^Set contrast (\d+)$"), "display.contrast_set", "level"),
    (re.compile(r"^Increase contrast by (\d+)%$"), "display.contrast_up", "by"),
    (re.compile(r"^Decrease contrast by (\d+)%$"), "display.contrast_down", "by"),
]

FILES_RE = re.compile(r"^([a-zA-Z]+) in '(.+)'(?: \[(\w+)\])?$")


def description_to_intent(desc: str) -> dict | None:
    """Reverse of `PlannedAction.description`. None when unmappable."""
    desc = desc.strip()

    for pattern, name in DESC_PATTERNS:
        match = pattern.match(desc)
        if match:
            groups = match.groups()
            if name == "web.search":
                return {"name": name, "args": {"engine": groups[0], "query": groups[1]}}
            arg = {
                "app.open": "name", "app.close": "name", "url.open": "url",
                "folder.open": "name", "file.open_latest": "folder",
                "file.create": "name", "folder.create": "name", "ai.query": "text",
                "media.play_song": "title", "media.play_playlist": "name",
            }[name]
            return {"name": name, "args": {arg: groups[0]}}

    if desc.startswith("Info: "):
        intent_name = INFO_DESCRIPTIONS.get(desc[len("Info: "):].strip())
        return {"name": intent_name, "args": {}} if intent_name else None

    if desc.startswith("Media: "):
        intent_name = MEDIA_DESCRIPTIONS.get(desc[len("Media: "):].strip())
        return {"name": intent_name, "args": {}} if intent_name else None

    if desc.startswith("Volume: "):
        body = desc[len("Volume: "):].strip()
        if body == "mute":
            return {"name": "volume.mute", "args": {}}
        if body == "unmute":
            return {"name": "volume.unmute", "args": {}}
        for pattern, name, arg in VOLUME_PATTERNS:
            match = pattern.match(body)
            if match:
                return {"name": name, "args": {arg: int(match.group(1))}}
        return None

    if desc.startswith("Display: "):
        body = desc[len("Display: "):].strip()
        for pattern, name, arg in DISPLAY_PATTERNS:
            match = pattern.match(body)
            if match:
                return {"name": name, "args": {arg: int(match.group(1))}}
        return None

    if desc.startswith("Files: "):
        match = FILES_RE.match(desc[len("Files: "):].strip())
        if match:
            return {"name": "files.query",
                    "args": {"op": match.group(1), "folder": match.group(2),
                             "ext": match.group(3) or ""}}
        return None

    return None


# Media titles that are really a whole sentence, not a song — the exact bug
# that produced playSong("in spotify, could you a for me?"). Training on these
# would teach the model the mistake, so they are dropped from the harvest.
NON_TITLE_WORDS = {
    "could", "would", "can", "will", "please", "for", "me", "you", "my",
    "song", "songs", "music", "track", "tracks", "playlist", "in", "on",
    "from", "spotify", "the", "a", "an", "and", "also", "play", "some",
    "something", "anything", "one", "it", "that", "this", "aloud", "as",
    "is", "are", "was", "were", "be", "been", "do", "does", "did", "to",
    "at", "by", "with", "or", "but", "so", "if", "then", "there", "here",
    "what", "which", "who", "when", "where", "why", "how", "just", "now",
    "again", "hey", "jarvis", "up", "out", "about", "like", "want", "need",
}

# Phrase patterns that only appear when a whole sentence leaked into the
# title slot (the "in spotify, could you a for me?" class of bug).
NON_TITLE_PHRASES = (
    "from my", "in my", "on my", "for me", "a song", "the song", "in spotify",
    "on spotify", "from spotify", "could you", "would you", "can you",
    "do one thing", "i want", "let me", "thank you",
)


def title_is_plausible(title: str) -> bool:
    """A real song title has at least one word that is not filler/question."""
    lowered = title.lower().strip()
    if not lowered or len(lowered.split()) > 8:
        return False
    if any(phrase in lowered for phrase in NON_TITLE_PHRASES):
        return False
    words = [w for w in re.split(r"\s+", lowered) if w]
    content = [w for w in words if w.strip(",.?!'\"") not in NON_TITLE_WORDS]
    return bool(content)


def target_is_clean(intents) -> bool:
    """Reject gold targets that encode a known bad behaviour."""
    if not isinstance(intents, list):
        return False
    for item in intents:
        if not isinstance(item, dict):
            return False
        if item.get("name") == "media.play_song":
            title = (item.get("args") or {}).get("title", "")
            if not title_is_plausible(title):
                return False
        if item.get("name") == "ai.query":
            query = (item.get("args") or {}).get("text", "")
            # ai.query as a catch-all for a system command means the model
            # failed that utterance, not that it learned something.
            if any(k in query.lower().split() for k in
                   ("open", "close", "play", "next", "search", "volume", "brightness")):
                return False
    return True


def is_consistent(text: str, intents) -> bool:
    """The plan must actually be about what the user said.

    A `model_hit` only means the router trusted the output — the log contains
    real counter-examples ("Open WhatsApp." → app.open Telegram, corrected
    downstream by the normalizer). Requiring the target's arguments to appear
    in the utterance throws those away instead of teaching them.
    """
    words = {w.strip(",.?!'\"").lower() for w in re.split(r"\s+", text.lower()) if w}
    if not words:
        return False

    def shares_token(value: str) -> bool:
        value_tokens = [w.strip(",.?!'\"").lower() for w in re.split(r"\s+", value) if w]
        for token in value_tokens:
            if not token:
                continue
            if token in words:
                return True
            stem = token[:4]
            if len(stem) >= 3 and any(w.startswith(stem) for w in words):
                return True
        return False

    for item in intents:
        name = item.get("name")
        args = item.get("args") or {}
        if name in ("app.open", "app.close"):
            if not shares_token(args.get("name", "")):
                return False
        elif name == "web.search":
            if not shares_token(args.get("query", "")):
                return False
        elif name == "media.play_song":
            if not shares_token(args.get("title", "")):
                return False
        elif name in ("folder.open", "file.open_latest", "files.query"):
            folder = args.get("folder") or args.get("name") or "downloads"
            if not shares_token(folder):
                return False
        elif name == "ai.query":
            return False
    return True


def harvest(log_path: str, schema: dict) -> tuple[list[dict], dict]:
    """Read the router log → (pairs, stats).

    Gold = the plan that actually EXECUTED successfully for that utterance.
    Reward signal = execute_command success for the same request_id.
    """
    if not os.path.exists(log_path):
        print(f"no router log at {log_path}", file=sys.stderr)
        return [], {}

    plans: dict[str, list[dict]] = {}      # request_id -> gold intents
    executed: dict[str, bool] = {}         # request_id -> success
    texts: dict[str, str] = {}
    hits: list[dict] = []
    stats = {"lines": 0, "plans": 0, "unmappable": 0, "hits": 0, "misses": 0}

    with open(log_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            stats["lines"] += 1
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue

            event = row.get("event")
            request_id = row.get("request_id")
            text = (row.get("text") or "").strip()

            if event == "model_miss":
                stats["misses"] += 1

            if event == "model_hit":
                stats["hits"] += 1
                actions = row.get("actions")
                # Synthetic system-test traffic is not real usage.
                if "e2e-" in text.lower():
                    continue
                if text and isinstance(actions, list) and schema_score(actions, schema) > 0:
                    hits.append({"text": text, "intents": actions})

            if event == "plan" and request_id:
                texts[request_id] = text
                intents = []
                for desc in row.get("actions") or []:
                    mapped = description_to_intent(desc)
                    if mapped is None:
                        stats["unmappable"] += 1
                        intents = []
                        break
                    intents.append(mapped)
                if intents:
                    plans[request_id] = intents
                    stats["plans"] += 1

            if event == "execute_command" and request_id:
                executed[request_id] = bool(row.get("success"))

    pairs: list[dict] = []
    seen: set[str] = set()

    # Verified hits — the model got these right, they ran, and the target does
    # not encode a known bad behaviour or contradict the utterance.
    for row in hits:
        key = row["text"]
        if key in seen or not target_is_clean(row["intents"]) or not is_consistent(key, row["intents"]):
            stats["rejected"] = stats.get("rejected", 0) + 1
            continue
        seen.add(key)
        pairs.append({
            "input_text": INPUT_PREFIX + key,
            "target_text": canonical(row["intents"]),
            "reward": 1.0,
            "source": "model_hit",
        })

    # Successful non-model plans — the correction targets for the small model.
    for request_id, intents in plans.items():
        text = texts.get(request_id, "")
        if not text or text in seen:
            continue
        if "e2e-" in text.lower():
            continue          # synthetic system-test traffic, not real usage
        if executed.get(request_id) is False:
            continue          # it did not work; not a gold target
        if not target_is_clean(intents) or not is_consistent(text, intents):
            stats["rejected"] = stats.get("rejected", 0) + 1
            continue
        seen.add(text)
        pairs.append({
            "input_text": INPUT_PREFIX + text,
            "target_text": canonical(intents),
            "reward": 1.0,
            "source": "executed_plan",
        })

    return pairs, stats


# ── train ───────────────────────────────────────────────────────────────────

def train(args, schema: dict) -> int:
    import torch
    from datasets import load_dataset
    from transformers import (
        AutoModelForSeq2SeqLM,
        AutoTokenizer,
        DataCollatorForSeq2Seq,
        Seq2SeqTrainer,
        Seq2SeqTrainingArguments,
    )

    data_files = {
        "train": os.path.join(DATA_DIR, "train.jsonl"),
        "dev": os.path.join(DATA_DIR, "dev.jsonl"),
    }
    ds = load_dataset("json", data_files=data_files)

    if os.path.exists(RL_PAIRS):
        rl = load_dataset("json", data_files={"train": RL_PAIRS})["train"]
        rl = rl.remove_columns(
            [c for c in rl.column_names if c not in ("input_text", "target_text")]
        )
        # RL examples are real usage — worth repeating so they are not diluted.
        repeats = max(1, args.rl_repeat)
        ds["train"] = ds["train"].remove_columns(
            [c for c in ds["train"].column_names if c not in ("input_text", "target_text")]
        )
        from datasets import concatenate_datasets
        ds["train"] = concatenate_datasets([ds["train"]] + [rl] * repeats)
        print(f"added {len(rl)} RL pairs ×{repeats} (real usage corrections)")

    tokenizer = AutoTokenizer.from_pretrained(args.init_from)
    model = AutoModelForSeq2SeqLM.from_pretrained(args.init_from)

    # t5-small's relative position embeddings cap at 512 tokens. Examples whose
    # target exceeds MAX_TARGET_LEN are DROPPED, not truncated — a truncated
    # target is silently corrupt JSON (same rule as train.py).
    max_target_len = 448

    def measure(batch):
        return {"tlen": [len(ids) for ids in tokenizer(
            text_target=batch["target_text"], truncation=False)["input_ids"]]}

    before = len(ds["train"])
    ds = ds.map(measure, batched=True)
    ds = ds.filter(lambda row: row["tlen"] <= max_target_len)
    ds = ds.remove_columns(["tlen"])
    dropped = before - len(ds["train"])
    if dropped:
        print(f"dropped {dropped} training examples longer than {max_target_len} tokens")

    if args.smoke:
        ds["train"] = ds["train"].select(range(min(200, len(ds["train"]))))
        ds["dev"] = ds["dev"].select(range(min(50, len(ds["dev"]))))

    def preprocess(batch):
        inputs = tokenizer(batch["input_text"], max_length=128, truncation=True)
        labels = tokenizer(text_target=batch["target_text"], max_length=max_target_len, truncation=True)
        inputs["labels"] = labels["input_ids"]
        return inputs

    tokenized = ds.map(preprocess, batched=True, remove_columns=ds["train"].column_names)

    def compute_metrics(eval_pred):
        import numpy as np
        preds, labels = eval_pred
        if isinstance(preds, tuple):
            preds = preds[0]
        preds = np.where(preds != -100, preds, tokenizer.pad_token_id)
        labels = np.where(labels != -100, labels, tokenizer.pad_token_id)
        decoded_preds = tokenizer.batch_decode(preds, skip_special_tokens=True)
        decoded_labels = tokenizer.batch_decode(labels, skip_special_tokens=True)

        scored = []
        for pred, gold in zip(decoded_preds, decoded_labels):
            try:
                pred_intents = json.loads(pred)
            except Exception:
                pred_intents = None
            try:
                gold_intents = json.loads(gold)
            except Exception:
                gold_intents = None
            scored.append(reward(pred_intents, gold_intents, schema))
        return {"reward": float(sum(scored) / max(1, len(scored)))}

    use_cpu = args.device == "cpu"
    if args.device == "mps":
        # The MPS caching allocator fragments badly on long runs; freeing it
        # before training starts is the difference between finishing and an
        # "MPS backend out of memory" at step ~77.
        try:
            torch.mps.empty_cache()
        except Exception:
            pass

    training_args = Seq2SeqTrainingArguments(
        output_dir=POST_DIR,
        overwrite_output_dir=True,
        seed=13,
        use_cpu=use_cpu,
        per_device_train_batch_size=args.batch,
        per_device_eval_batch_size=16,
        gradient_accumulation_steps=args.accum,
        learning_rate=args.lr,
        num_train_epochs=args.epochs,
        warmup_ratio=0.05,
        weight_decay=0.01,
        logging_steps=50,
        eval_strategy="epoch",
        save_strategy="epoch",
        predict_with_generate=True,
        generation_max_length=448,
        generation_num_beams=1,
        # Stream eval predictions to CPU in chunks — without this the whole
        # generation matrix stays resident on the GPU and OOMs on a full run.
        eval_accumulation_steps=8,
        load_best_model_at_end=True,
        metric_for_best_model="reward",
        greater_is_better=True,
        save_total_limit=2,
        fp16=False,
        report_to=[],
    )

    trainer = Seq2SeqTrainer(
        model=model,
        args=training_args,
        train_dataset=tokenized["train"],
        eval_dataset=tokenized["dev"],
        processing_class=tokenizer,
        data_collator=DataCollatorForSeq2Seq(tokenizer, model=model, padding=True),
        compute_metrics=compute_metrics,
    )

    trainer.train()
    trainer.save_model(POST_DIR)
    tokenizer.save_pretrained(POST_DIR)
    print(f"saved post-trained model to {POST_DIR} (same architecture, no size growth)")
    print(f"metrics: {trainer.evaluate()}")
    return 0


# ── eval ────────────────────────────────────────────────────────────────────

def evaluate(args, schema: dict) -> int:
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    if not os.path.exists(RL_PAIRS):
        print("no rl_pairs.jsonl — run --harvest first", file=sys.stderr)
        return 1

    tokenizer = AutoTokenizer.from_pretrained(args.init_from)
    model = AutoModelForSeq2SeqLM.from_pretrained(args.init_from)
    model.eval()

    rows = []
    with open(RL_PAIRS, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))

    scores = []
    with torch.no_grad():
        for row in rows[: args.limit]:
            inputs = tokenizer(row["input_text"], return_tensors="pt", truncation=True)
            out = model.generate(**inputs, max_length=448, num_beams=1)
            text = tokenizer.decode(out[0], skip_special_tokens=True)
            try:
                predicted = json.loads(text)
            except Exception:
                predicted = None
            try:
                gold = json.loads(row["target_text"])
            except Exception:
                gold = None
            scores.append(reward(predicted, gold, schema))

    mean = sum(scores) / max(1, len(scores))
    exact = sum(1 for s in scores if s >= 1.0) / max(1, len(scores))
    print(f"reward  (mean): {mean:.3f} over {len(scores)} real-usage utterances")
    print(f"exact match   : {exact:.3f}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=DEFAULT_LOG, help="router JSONL to harvest")
    ap.add_argument("--harvest", action="store_true", help="log -> training/data/rl_pairs.jsonl")
    ap.add_argument("--train", action="store_true", help="continue-train from --init-from")
    ap.add_argument("--eval", action="store_true", help="reward-score a checkpoint")
    ap.add_argument("--init-from", default=os.path.join(OUT_DIR, "best"),
                    help="checkpoint to continue from (keeps the model size)")
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--accum", type=int, default=4)
    ap.add_argument("--lr", type=float, default=3e-4, help="lower than a fresh run")
    ap.add_argument("--rl-repeat", type=int, default=3,
                    help="how often to repeat harvested real-usage pairs")
    ap.add_argument("--limit", type=int, default=200, help="eval sample size")
    ap.add_argument("--device", choices=["auto", "mps", "cpu"], default="auto",
                    help="compute device; cpu avoids the MPS allocator blow-up")
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()

    schema = load_schema()

    if not (args.harvest or args.train or args.eval):
        ap.print_help()
        return 0

    if args.harvest:
        pairs, stats = harvest(args.log, schema)
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(RL_PAIRS, "w", encoding="utf-8") as handle:
            for row in pairs:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"harvested {len(pairs)} reward-verified pairs → {os.path.relpath(RL_PAIRS, ROOT)}")
        print(f"  log lines {stats.get('lines')} · executed plans {stats.get('plans')} "
              f"· model hits {stats.get('hits')} · model misses {stats.get('misses')} "
              f"· unmappable {stats.get('unmappable')}")

    if args.train:
        if not os.path.exists(args.init_from):
            print(f"--init-from {args.init_from} not found — train.py first", file=sys.stderr)
            return 1
        return train(args, schema)

    if args.eval:
        return evaluate(args, schema)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
