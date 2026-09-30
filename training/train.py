#!/usr/bin/env python3
"""Fine-tune t5-small as the Jarvis intent parser (utterance -> canonical intent JSON).

Usage:
    python train.py                 # full run (uses training/data/*.jsonl)
    python train.py --epochs 3      # quick smoke run

Output: training/out/best/ (best checkpoint by dev exact-match).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
import torch
from datasets import load_dataset
from transformers import (
    AutoModelForSeq2SeqLM,
    AutoTokenizer,
    DataCollatorForSeq2Seq,
    EarlyStoppingCallback,
    Seq2SeqTrainer,
    Seq2SeqTrainingArguments,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "training", "data")
OUT_DIR = os.path.join(ROOT, "training", "out")
SCHEMA_PATH = os.path.join(ROOT, "training", "intent_schema.json")

BASE_MODEL = "t5-small"
MAX_SOURCE_LEN = 128
# t5-small's relative position embeddings cap at 512; the longest mega-chain
# targets exceed that, so they are dropped (exact tokenizer check below).
MAX_TARGET_LEN = 448
SEED = 13


def load_schema_names() -> set:
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return set(json.load(f)["intents"].keys())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--accum", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--base", type=str, default=BASE_MODEL)
    ap.add_argument("--init-from", type=str, default=None,
                    help="continue-training: load model+tokenizer weights from this dir first")
    ap.add_argument("--smoke", action="store_true", help="tiny subset for a pipeline smoke run")
    args = ap.parse_args()

    torch.manual_seed(SEED)
    np.random.seed(SEED)
    valid_names = load_schema_names()

    data_files = {
        "train": os.path.join(DATA_DIR, "train.jsonl"),
        "dev": os.path.join(DATA_DIR, "dev.jsonl"),
    }
    ds = load_dataset("json", data_files=data_files)
    if args.smoke:
        ds["train"] = ds["train"].select(range(200))
        ds["dev"] = ds["dev"].select(range(50))

    source = args.init_from or args.base
    tokenizer = AutoTokenizer.from_pretrained(source)
    model = AutoModelForSeq2SeqLM.from_pretrained(source)

    # t5-small's SentencePiece vocab has no `{` / `}` — they encode to <unk>
    # and are dropped on decode, which silently corrupts the JSON targets.
    # Add them as real tokens so the model can emit valid JSON.
    added = tokenizer.add_tokens(["{", "}"])
    if added:
        model.resize_token_embeddings(len(tokenizer))
        print(f"added {added} tokens ({{ }}) — vocab now {len(tokenizer)}")

    # Exact filter: drop examples whose target exceeds t5-small's 512-token
    # position-embedding cap (a handful of 13+-action mega-chains).
    def measure(batch):
        return {
            "tlen": [len(ids) for ids in tokenizer(text_target=batch["target_text"], truncation=False)["input_ids"]]
        }

    before = len(ds["train"])
    ds = ds.map(measure, batched=True)
    ds = ds.filter(lambda row: row["tlen"] <= MAX_TARGET_LEN)
    dropped = before - len(ds["train"])
    if dropped:
        print(f"dropped {dropped} training examples longer than {MAX_TARGET_LEN} tokens")
    ds = ds.remove_columns(["tlen"])

    def preprocess(batch):
        inputs = tokenizer(batch["input_text"], max_length=MAX_SOURCE_LEN, truncation=True)
        labels = tokenizer(text_target=batch["target_text"], max_length=MAX_TARGET_LEN, truncation=True)
        inputs["labels"] = labels["input_ids"]
        return inputs

    tokenized = ds.map(preprocess, batched=True, remove_columns=ds["train"].column_names)

    def parse_valid(text: str) -> bool:
        try:
            obj = json.loads(text)
        except Exception:
            return False
        if not isinstance(obj, list) or not obj:
            return False
        return all(isinstance(x, dict) and x.get("name") in valid_names for x in obj)

    def canonical(text: str) -> str:
        """Semantic normalization: added `{`/`}` tokens decode with a cosmetic
        space, so exact-match compares parsed JSON, not raw strings."""
        try:
            return json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))
        except Exception:
            return text.strip()

    def compute_metrics(eval_pred):
        preds, labels = eval_pred
        if isinstance(preds, tuple):
            preds = preds[0]
        preds = np.where(preds != -100, preds, tokenizer.pad_token_id)
        labels = np.where(labels != -100, labels, tokenizer.pad_token_id)
        decoded_preds = tokenizer.batch_decode(preds, skip_special_tokens=True)
        decoded_labels = tokenizer.batch_decode(labels, skip_special_tokens=True)
        exact = np.mean([canonical(p) == canonical(l) for p, l in zip(decoded_preds, decoded_labels)])
        valid = np.mean([parse_valid(p) for p in decoded_preds])
        return {"exact_match": float(exact), "parse_valid": float(valid)}

    collator = DataCollatorForSeq2Seq(tokenizer, model=model, padding=True)

    training_args = Seq2SeqTrainingArguments(
        output_dir=OUT_DIR,
        overwrite_output_dir=True,
        seed=SEED,
        per_device_train_batch_size=args.batch,
        per_device_eval_batch_size=16,
        gradient_accumulation_steps=args.accum,
        learning_rate=args.lr,
        num_train_epochs=args.epochs,
        warmup_ratio=0.05,
        weight_decay=0.01,
        logging_steps=100,
        eval_strategy="epoch",
        save_strategy="epoch",
        predict_with_generate=True,
        generation_max_length=MAX_TARGET_LEN,
        generation_num_beams=1,
        load_best_model_at_end=True,
        metric_for_best_model="exact_match",
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
        data_collator=collator,
        compute_metrics=compute_metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=3)],
    )

    trainer.train()

    best_dir = os.path.join(OUT_DIR, "best")
    trainer.save_model(best_dir)
    tokenizer.save_pretrained(best_dir)
    print(f"saved best model to {best_dir}")
    print(f"best dev metrics: {trainer.evaluate()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
