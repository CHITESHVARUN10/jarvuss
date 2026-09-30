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

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
MODEL_DIR = Path(os.environ.get("JARVIS_INTENT_MODEL_DIR", str(BASE_DIR / "models" / "intent-t5-small")))

INPUT_PREFIX = "parse: "
MAX_SOURCE_LEN = 96
MAX_TARGET_LEN = 256
ENCODER_FILE = "encoder_model_quantized.onnx"
DECODER_FILE = "decoder_model_merged_quantized.onnx"
EOS_ID = 1
PAD_ID = 0
UNK_ID = 2

router = APIRouter()

_lock = threading.Lock()
_engine = None
_load_error: str | None = None


class ParseIntentRequest(BaseModel):
    text: str


class _OnnxIntentEngine:
    """Greedy seq2seq decode over the exported t5-small ONNX sessions."""

    def __init__(self, model_dir: Path) -> None:
        import numpy as np
        import onnxruntime as ort
        import sentencepiece as spm

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
        np = self.np
        ids: list[int] = []
        buf: list[str] = []
        for ch in text[:MAX_SOURCE_LEN]:
            if ch in self.brace_to_id:
                if buf:
                    ids.extend(self.sp.encode("".join(buf)))
                    buf = []
                ids.append(self.brace_to_id[ch])
            else:
                buf.append(ch)
        if buf:
            ids.extend(self.sp.encode("".join(buf)))
        ids.append(EOS_ID)
        return ids[:MAX_SOURCE_LEN]

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

        confidence = math.exp(sum(logprobs) / len(logprobs)) if logprobs else 0.0
        return self.decode(generated), confidence


def _load() -> None:
    global _engine, _load_error
    with _lock:
        if _engine is not None or _load_error is not None:
            return
        if not MODEL_DIR.is_dir():
            _load_error = f"model directory not found: {MODEL_DIR}"
            return
        try:
            _engine = _OnnxIntentEngine(MODEL_DIR)
        except Exception as exc:  # pragma: no cover - environment dependent
            _load_error = str(exc)


@router.post("/parse_intent")
def parse_intent(req: ParseIntentRequest) -> dict[str, Any]:
    _load()
    if _engine is None:
        raise HTTPException(status_code=503, detail=f"intent model unavailable: {_load_error}")

    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    start = time.perf_counter()
    raw, confidence = _engine.generate(text)
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
