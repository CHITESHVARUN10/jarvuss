# Jarvis — Learned Intent Router (FastPathRouter replacement): Session Handoff

Repo: `/Users/chiteshvarun/D-drive/jarvis_code` · Branch: `master`
Plan (approved): `~/.commandcode/plans/intent-model-router.md`
Updated: after the brace-token retrain + fine-tune + ONNX export + live endpoint test.

---

## 1. Goal

Replace `FastPathRouter` (regex, `Sources/JarvisMacOS/Commands/ActionPlanner.swift:126`) with a small fine-tuned
neural parser that:

1. Reads a raw utterance and outputs the dataset's intent JSON (`[{"name":..., "args":{...}}, ...]`).
2. Understands ordered multi-step plans (1–10+ actions) and open-vocabulary slots (song titles, search queries, file names).
3. Generalizes to unseen phrasings (no memorization).
4. On any failure (parse error, unknown intent, low confidence, backend down): logs the request + model output to a
   JSONL corpus for future RL, then falls through to the existing pipeline (regex router → Qwen/Ollama) unchanged.

FastPathRouter is **not deleted** — it stays as the safety net.

## 2. Architecture decision (already approved)

| Option | Verdict | Why |
|---|---|---|
| Random forest / isolation forest | ❌ | Can't emit variable-length ordered action sequences or copy free-text slots. |
| Encoder + token tagging | ❌ | Fixed label set; open-vocab slots need a separate NER; multi-step ordering awkward. |
| LoRA on Qwen 1.5B | ❌ | 100–300 ms; defeats "very fast". |
| **t5-small seq2seq, text → canonical intent JSON** | ✅ chosen | Built for generation + copying; 60M params; int8 ONNX. |

Target format: canonical compact JSON, fixed key order, `"parse: <utterance>"` input prefix.

## 3. What was built (status)

### 3.1 Dataset — DONE

- `dataset/` train shards: **60 files, 6,859 examples** (hand-authored) + `valid.jsonl` (36) + `test.jsonl` (35).
- `dataset/train-060.jsonl` — focus shard written after the first evaluation to fix failure families
  (mute/unmute synonyms, "sound level to N", rewind/previous synonyms, folder.open phrasings, name copying,
  math → ai.query, "search youtube for the …", install … through brew, multi-step chains).
- Split hygiene enforced: no valid/test text appears in train.
- 36-intent vocabulary + arg schema: `training/intent_schema.json`.

### 3.2 Training pipeline — DONE, TRAINED, FIXED, FINE-TUNED

| File | Purpose |
|---|---|
| `training/intent_schema.json` | Intent names + canonical arg order (source of truth). |
| `training/prepare_data.py` | Validates + canonicalizes dataset → `training/data/{train,dev,valid,test,novel}.jsonl`. Deterministic 95/5 train/dev split (seed 13). `--check` mode. Final: **train 6,517 / dev 342 / valid 36 / test 35 / novel 45**. |
| `training/eval_novel.jsonl` | 45 hand-written novel utterances never in any split (generalization proof). |
| `training/train.py` | HF `Seq2SeqTrainer`, t5-small, batch 8 × grad-accum 4 (batch 4 × accum 8 for the fine-tune), ≤20 epochs, early stop patience 3 on dev exact-match, max source 128 / target 448 tokens (~14 mega-chains dropped). Adds `{`/`}` tokens + `resize_token_embeddings` (vocab 32102). Supports `--init-from DIR` for continue-training. |
| `training/evaluate.py` | Exact-match (semantic JSON compare), parse-validity, action P/R/F1, latency p50/p95. `--onnx --model <dir>` evaluates the exported model. Writes `training/out/metrics.json`. |
| `training/export_onnx.py` | `main_export` (task `text2text-generation-with-past`) → int8 dynamic quantization of encoder + **merged** decoder → deletes fp32 onnx → `backend/models/intent-t5-small/` (196 MB). |
| `training/diagnose.py` | Dumps exact-match failures for valid/test/novel with per-example confidence (failure analysis tool). |
| `training/requirements.txt` | torch, transformers 5.x, datasets, accelerate, sentencepiece, `optimum[onnxruntime]==2.1.0`. |
| `training/.venv` | Python 3.11 venv (installed). |

Run artifacts: `training/out/best/` = **current shipped model** (2nd run); `training/out/best_prev/` = first (pre-focus-shard)
model; logs `out_train.log` (run 1), `out_train2.log` (fine-tune), `out/metrics.json`.

### 3.3 Training results — VALID THIS TIME

Two runs: (1) from base t5-small with the brace fix, 15 epochs early-stopped → dev 97.9 %; (2) continue-train
(`--init-from out/best_prev --epochs 6 --lr 3e-4`) after adding `train-060.jsonl` → dev **99.4 %**.

Independent evaluation (also re-verified with the raw onnxruntime engine: exact parity — test 32/35, novel 41/45):

| Split | exact-match | parse-valid | action F1 |
|---|---|---|---|
| dev (trainer) | 0.994 | 1.000 | – |
| valid | 0.944 | 0.972 | 0.947 |
| test (held out) | **0.914** | 1.000 | 0.932 |
| novel (hand-written) | **0.911** | ~1.000 | 0.923 |

Latency (Mac CPU, int8 ONNX): p50 ~84–100 ms, p95 ~460 ms; live endpoint returned 73–214 ms per request
(multi-step chains are the slow cases). No torch in the serving path.

**Remaining known misses (9/116)** — all cases where the model is confidently fluent-but-wrong (token confidence does
NOT discriminate: correct answers 0.996–1.0, wrong 0.972–1.0):
`check the date and time` → `[date, date]` · `search youtube for song of ice and fire` → truncates + opens Firefox ·
`volume at half` → invalid level `halb` (parse rejects → fallback) · `mute the mic` → `volume.mute` (gold: ai.query) ·
`close spotify and shut the music` → closes Music instead of pausing · `play some jazz on spotify` → playlist name
includes "on spotify" · `i feel like listening to bohemian rhapsody` → ai.query garbage · `tell me how much battery
remains` → ai.query · `put on some kesariya` → playlist (label ambiguity in the corpus). These feed the RL corpus.

The original root-cause bug (t5-small vocabulary had **no `{`/`}`** → JSON targets were silently mangled) is fixed in
`train.py`; `added_tokens.json` in the model dir confirms the brace tokens ship with the exporter.

### 3.4 Backend — DONE, LIVE-TESTED

- `backend/models/intent-t5-small/` — 196 MB: `encoder_model_quantized.onnx` (34 MB),
  `decoder_model_merged_quantized.onnx` (159 MB), tokenizer files + `config.json` + `added_tokens.json` + `model_meta.json`.
- `backend/intent_router_model.py` — FastAPI router: `POST /parse_intent {text}` →
  `{actions, parse_ok, confidence, raw, latency_ms}`. **Serving path is plain onnxruntime + sentencepiece** (no
  optimum/transformers/torch): the backend venv has a broken torchvision (Python 3.14) that the optimum import chain
  triggers, and raw ORT is lighter and faster to import. Greedy decode with KV cache; confidence = geometric mean of
  chosen-token probabilities computed in numpy. Missing model dir → 503.
- `backend/voice_auth_service.py` — imports + registers the router (`app.include_router`).
- `backend/requirements.txt` — replaced `transformers`/`optimum[onnxruntime]` with `onnxruntime>=1.20.0`
  (+ existing `sentencepiece`). **Backend venv note:** an `optimum[onnxruntime]` install attempt downgraded
  `transformers` to 4.57.6 (breaks mlx-audio/mlx-vlm); it was restored to 5.14.1 and `optimum` uninstalled. Do not
  reinstall optimum/transformers into `backend/venv`.
- Live test (uvicorn + curl) verified: `open chrome` 81 ms · 3-action chain 214 ms · `set volume to seventy` → 70 ·
  multi-step/arg fidelity correct.

### 3.5 Swift app — BUILT (compiles), NOT YET RUNTIME TESTED

| File | Role |
|---|---|
| `Sources/JarvisMacOS/AI/IntentModelClient.swift` | POST `http://127.0.0.1:8000/parse_intent`, 2 s timeout, env override `JARVIS_BACKEND_URL`/`BACKEND_BASE_URL`. |
| `Sources/JarvisMacOS/Commands/IntentActionMapper.swift` | Strict JSON → `PlannedAction` mapping for all 36 intents; any unknown/malformed → nil. |
| `Sources/JarvisMacOS/Commands/IntentRouterLog.swift` | Append-only JSONL at `~/Library/Application Support/Jarvis/logs/intent_router.jsonl` (thread-safe). |
| `Sources/JarvisMacOS/Commands/IntentModelRouter.swift` | Call → parse → confidence gate (0.75) → map → log. Returns nil on ANY failure. Kill switch: `JARVIS_INTENT_MODEL=off`. |

Modified: `ActionPlanner.swift` (model attempt after SafetyGuard, before FastPathRouter; branch logging),
`AppState.swift` (request ID + per-step execution events). `swift build` → **Build complete**.

### 3.6 Repo hygiene — DONE

- `.gitignore`: `training/.venv/`, `training/out/`, `training/data/`, `training/__pycache__/`, `training/*.log`,
  `backend/models/` (`.commandcode/` already ignored).
- **Model bundling NOT done on purpose** (user instruction: don't bundle until asked). When ready, add a guarded
  `cp -R` of `backend/models/` in `scripts/package_jarvis_app.zsh` next to the `embeddings.npy` copy (~line 53).

## 4. Exact next steps (in order)

1. **Decide on bundling** (user call): 196 MB model dir — copy into the app bundle or keep server-side only.
2. **In-app manual matrix**: multi-step, out-of-range brightness passthrough, files, novel phrasings, and the fallback
   test (`JARVIS_INTENT_MODEL=off` or backend stopped → behavior identical to today; Qwen path works;
   `intent_router.jsonl` shows `model_miss` + `plan(branch:qwen)`).
3. **Optional latency work**: p95 ~460 ms comes from long/looping generations; consider early-stop heuristics
   (e.g. max 12 actions) and/or CoreML EP for the encoder. Do not regress correctness for this.
4. **RL loop (later)**: `intent_router.jsonl` is the corpus; failures are confidently-wrong phrasings — this is where
   hard examples for the next training round come from.

## 5. Command cheat sheet

```bash
# training venv
cd /Users/chiteshvarun/D-drive/jarvis_code/training && ./.venv/bin/python <script>

# data prep / validation
./.venv/bin/python prepare_data.py --check

# (re)train from base (background, memory-safe for MPS; pass the env to the actual process!)
PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 nohup ./.venv/bin/python train.py --epochs 20 --batch 8 --accum 4 > out_train.log 2>&1 &

# continue-training on new data
./.venv/bin/python train.py --init-from out/best --epochs 6 --lr 3e-4 --batch 4 --accum 8

# evaluate (torch) / evaluate the exported ONNX
./.venv/bin/python evaluate.py
./.venv/bin/python evaluate.py --onnx --model ../backend/models/intent-t5-small

# failure analysis
./.venv/bin/python diagnose.py

# export int8 ONNX
./.venv/bin/python export_onnx.py

# backend (service): start + smoke
cd ../backend && ./venv/bin/python -m uvicorn voice_auth_service:app --host 127.0.0.1 --port 8000
curl -s localhost:8000/parse_intent -H 'content-type: application/json' -d '{"text":"close whatsapp and open spotify"}'

# swift build
cd /Users/chiteshvarun/D-drive/jarvis_code && swift build
```

## 6. Gotchas / constraints (read before touching)

- **MPS OOM**: heavy GPU users on the machine can exhaust the shared pool mid-run ("other allocations" in the error).
  Use batch 4–8 + accum, and `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0`; when launching via `subprocess.Popen` pass
  `env=...` explicitly (forgetting it cost a crashed run).
- **Second-run OOM crash fix**: batch 4 × accum 8 + env passed → completed cleanly on the same machine.
- **transformers 5.x API**: `tokenizer(text_target=...)`; `Trainer(processing_class=)`; `eval_strategy`.
- **t5-small vocab lacks `{` `}`** — the add_tokens fix must exist in any future training run (it is in `train.py`).
- **Merged-decoder KV-cache protocol** (if you touch the ONNX engine): first step `use_cache_branch=False` with
  zero-length pasts; afterwards `True` and update only `past_key_values.*.decoder.*` — `present.*.encoder.*` come back
  as `(0, 8, 1, 64)` placeholders after step 1, so **pin the step-1 encoder K/V for all later steps**.
- **Confidence gate is weak by design**: correct answers 0.996–1.0 vs wrong 0.972–1.0 — it only catches degenerate
  outputs. Real safety = `parse_ok` + strict `IntentActionMapper` validation + fallback chain.
- Kill switch: `JARVIS_INTENT_MODEL=off`. RL corpus: `~/Library/Application Support/Jarvis/logs/intent_router.jsonl`.
- Do NOT bundle, do NOT commit unless the user asks; no Command Code co-author trailer; `.commandcode/` stays ignored.
