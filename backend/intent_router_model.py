"""Learned intent parser — fine-tuned t5-small (int8 ONNX) exposed as /parse_intent.

The Swift app calls this before the regex FastPathRouter. On any failure the
app logs the request and falls back to the existing rule router + Ollama
pipeline, so this endpoint must never throw for "unparseable" input — it
returns parse_ok=false and the client decides.

Inference is plain onnxruntime + sentencepiece (no optimum / transformers /
torch): the backend venv runs Python 3.14 where the transformers/optimum
stack breaks on a torchvision ABI mismatch, and this path is faster to
import and has no effect on voice-auth boot time. The exported files
(encoder_model_quantized.onnx + decoder_model_merged_quantized.onnx) are
self-contained.

Heavy imports are intentionally lazy: the model loads on first request so
voice-auth boot time is unaffected, and a missing model directory degrades
to 503 instead of crashing the service.
"""
from __future__ import annotations

import json
import math
import os
import threading
import time
from pathlib import Path
from typing import Any

from runtime_config import data_directory
import intent_model_store as model_store

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent
MODEL_DIR = Path(os.environ.get("JARVIS_INTENT_MODEL_DIR", str(BASE_DIR / "models" / "intent-t5-small")))

INPUT_PREFIX = "parse: "
MAX_SOURCE_LEN = 128
MAX_TARGET_LEN = 448
ENCODER_FILE = "encoder_model_quantized.onnx"
DECODER_FILE = "decoder_model_merged_quantized.onnx"
EOS_ID = 1
PAD_ID = 0
UNK_ID = 2

router = APIRouter()

_lock = threading.Lock()
_inference_lock = threading.Lock()
_engine = None
_load_error: str | None = None
_selection_key: str | None = None
_active_release: dict[str, Any] = {"source": "not loaded"}
_update_error: str | None = None


class ParseIntentRequest(BaseModel):
    text: str = Field(max_length=4096)


class InputTooLong(ValueError):
    pass


class _OnnxIntentEngine:
    """Greedy seq2seq decode over the exported t5-small ONNX sessions."""

    def __init__(self, model_dir: Path) -> None:
        import numpy as np
        import onnxruntime as ort
        import sentencepiece as spm

        ort.disable_telemetry_events()
        self.np = np
        cfg = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
        self.layers = int(cfg["num_decoder_layers"])
        self.heads = int(cfg["num_heads"])
        self.d_kv = int(cfg["d_kv"])
        self.start_id = int(cfg.get("decoder_start_token_id", PAD_ID))

        added = json.loads((model_dir / "added_tokens.json").read_text(encoding="utf-8"))
        self.brace_to_id = {str(k): int(v) for k, v in added.items()}
        self.id_to_brace = {int(v): str(k) for k, v in added.items()}

        self.sp = spm.SentencePieceProcessor(model_file=str(model_dir / "spiece.model"))

        opts = ort.SessionOptions()
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.intra_op_num_threads = max(1, (os.cpu_count() or 4) // 2)
        available = ort.get_available_providers()
        providers = [p for p in ("CPUExecutionProvider",) if p in available]
        self.enc = ort.InferenceSession(str(model_dir / ENCODER_FILE), opts, providers=providers)
        self.dec = ort.InferenceSession(str(model_dir / DECODER_FILE), opts, providers=providers)
        self.dec_output_names = [o.name for o in self.dec.get_outputs()]

    def encode(self, text: str) -> list[int]:
        ids: list[int] = []
        buf: list[str] = []
        for ch in text:
            if ch in self.brace_to_id:
                if buf:
                    ids.extend(self.sp.encode("".join(buf)))
                    buf = []
                ids.append(self.brace_to_id[ch])
            else:
                buf.append(ch)
        if buf:
            ids.extend(self.sp.encode("".join(buf)))
        if len(ids) >= MAX_SOURCE_LEN:
            raise InputTooLong(f"Intent input exceeds {MAX_SOURCE_LEN - 1} tokens")
        return ids + [EOS_ID]

    def decode(self, token_ids: list[int]) -> str:
        parts: list[str] = []
        buf: list[int] = []

        def flush() -> None:
            if buf:
                parts.append(self.sp.decode(buf))
                buf.clear()

        for tid in token_ids:
            if tid == EOS_ID:
                flush()
                break
            if tid in self.id_to_brace:
                flush()
                parts.append(self.id_to_brace[tid])
            elif tid in (PAD_ID, UNK_ID):
                continue
            else:
                buf.append(int(tid))
        flush()
        return "".join(parts).strip()

    def generate(self, text: str) -> tuple[str, float]:
        np = self.np
        ids = self.encode(INPUT_PREFIX + text)
        src_len = len(ids)
        input_ids = np.array([ids], dtype=np.int64)
        attn_mask = np.ones((1, src_len), dtype=np.int64)
        enc_hidden = self.enc.run(None, {"input_ids": input_ids, "attention_mask": attn_mask})[0]

        feed: dict[str, Any] = {
            "encoder_attention_mask": attn_mask,
            "encoder_hidden_states": enc_hidden,
            # False selects the no-past subgraph on the first step (it computes
            # cross-attention K/V from encoder_hidden_states and returns them in
            # present.*.encoder.*); True uses the cached past on all later steps.
            "use_cache_branch": np.array([False], dtype=np.bool_),
        }
        for layer in range(self.layers):
            feed[f"past_key_values.{layer}.decoder.key"] = np.zeros((1, self.heads, 0, self.d_kv), dtype=np.float32)
            feed[f"past_key_values.{layer}.decoder.value"] = np.zeros((1, self.heads, 0, self.d_kv), dtype=np.float32)
            feed[f"past_key_values.{layer}.encoder.key"] = np.zeros((1, self.heads, 0, self.d_kv), dtype=np.float32)
            feed[f"past_key_values.{layer}.encoder.value"] = np.zeros((1, self.heads, 0, self.d_kv), dtype=np.float32)

        generated: list[int] = []
        logprobs: list[float] = []
        cur = np.array([[self.start_id]], dtype=np.int64)
        use_cache = False
        finished = False
        for _ in range(MAX_TARGET_LEN):
            feed["input_ids"] = cur
            feed["use_cache_branch"] = np.array([use_cache], dtype=np.bool_)
            outputs = self.dec.run(None, feed)
            by_name = dict(zip(self.dec_output_names, outputs))
            logits = by_name["logits"][0, -1].astype(np.float64)
            peak = float(logits.max())
            log_sum_exp = peak + math.log(float(np.exp(logits - peak).sum()))
            log_probs = logits - log_sum_exp
            next_id = int(log_probs.argmax())
            if next_id == EOS_ID:
                finished = True
                break
            logprobs.append(float(log_probs[next_id]))
            generated.append(next_id)
            cur = np.array([[next_id]], dtype=np.int64)
            for layer in range(self.layers):
                feed[f"past_key_values.{layer}.decoder.key"] = by_name[f"present.{layer}.decoder.key"]
                feed[f"past_key_values.{layer}.decoder.value"] = by_name[f"present.{layer}.decoder.value"]
                if not use_cache:
                    # The no-past subgraph computes cross-attention K/V and
                    # returns them here; the with-cache subgraph returns
                    # (0, heads, 1, d_kv) placeholders instead, so pin the
                    # step-1 values and keep reusing them.
                    feed[f"past_key_values.{layer}.encoder.key"] = by_name[f"present.{layer}.encoder.key"]
                    feed[f"past_key_values.{layer}.encoder.value"] = by_name[f"present.{layer}.encoder.value"]
            use_cache = True

        if not finished:
            return "", 0.0
        confidence = math.exp(sum(logprobs) / len(logprobs)) if logprobs else 0.0
        return self.decode(generated), confidence


def _load() -> None:
    global _engine, _load_error, _selection_key, _active_release, _update_error
    root = data_directory() / "models" / "intent"
    override = os.environ.get("JARVIS_INTENT_MODEL_DIR")
    desired = None if override else model_store.receipt(root)
    # An install after an earlier missing-model error must be noticed without
    # restarting the helper. No hashing or heavy imports on unchanged requests.
    key = json.dumps(desired, sort_keys=True) if desired else "local:" + str(MODEL_DIR)
    with _lock:
        if _selection_key == key: return
        _selection_key = key
        _update_error = None
        choices = []
        if desired: choices.append((desired, "downloaded"))
        if not override:
            previous = model_store.receipt(root, "last-good.json")
            if previous and previous != desired: choices.append((previous, "previous downloaded"))
        choices.append((None, "configured" if override else "bundled"))
        for selected, source in choices:
            try:
                # Keep an already loaded working engine if a requested update
                # fails. Never fall back to unrelated model files mid-session.
                if selected is None and _engine is not None: return
                folder = model_store.verify(root, selected) if selected else MODEL_DIR
                if not folder.is_dir(): raise ValueError("intent model is not installed")
                with _inference_lock:
                    candidate = _OnnxIntentEngine(folder)
                    if selected:
                        raw, _ = candidate.generate("pause")
                        parsed = json.loads(raw)
                        if not isinstance(parsed, list) or not parsed or not all(isinstance(item, dict) and isinstance(item.get("name"), str) for item in parsed):
                            raise ValueError("downloaded model failed its warm-up check")
                    _engine = candidate
                    _load_error = None
                    _active_release = {"source": source, "version": selected.get("version") if selected else None,
                                       "commit": selected.get("commit") if selected else None}
                if selected:
                    try: model_store.remember_good(root, selected)
                    except OSError: pass # A cache-write failure must not discard a loaded model.
                return
            except Exception as exc:
                _load_error = "Intent model validation failed (" + type(exc).__name__ + ")."
                if selected: _update_error = "The downloaded model failed validation; the previous model remains in use when available."
                if _engine is not None: return


@router.get("/intent_model/status")
def intent_model_status() -> dict[str, Any]:
    # Status queries never load a model or initialize ONNX Runtime.
    return {"loaded": _engine is not None, **_active_release, "update_error": _update_error}


@router.post("/parse_intent")
def parse_intent(req: ParseIntentRequest) -> dict[str, Any]:
    _load()
    engine = _engine
    if engine is None:
        raise HTTPException(status_code=503, detail=f"intent model unavailable: {_load_error}")

    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    start = time.perf_counter()
    if not _inference_lock.acquire(blocking=False):
        raise HTTPException(status_code=503, detail="Intent model busy")
    try:
        raw, confidence = engine.generate(text)
    except InputTooLong:
        # The caller can split or route the FULL request through its fallback.
        return {"actions": None, "parse_ok": False, "confidence": 0,
                "raw": "", "latency_ms": 0, "reason": "input_too_long"}
    finally:
        _inference_lock.release()
    latency_ms = int((time.perf_counter() - start) * 1000)

    actions = None
    parse_ok = False
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, list) and parsed and all(isinstance(x, dict) for x in parsed):
            actions = parsed
            parse_ok = True
    except Exception:
        parse_ok = False

    return {
        "actions": actions,
        "parse_ok": parse_ok,
        "confidence": round(confidence, 4),
        "raw": raw,
        "latency_ms": latency_ms,
    }
