from __future__ import annotations

import json
import os
import time
import threading
import re
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import asyncio
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any, Dict

import logging

import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from runtime_config import RuntimeConfig, data_directory, read_env
from local_auth import HEADER, authorized, create_token

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent
EMBEDDINGS_FILE = data_directory() / "embeddings.npy"
_embeddings_lock = threading.RLock()
_runtime_config = RuntimeConfig()
_voice_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="jarvis-voice")
_voice_slots = threading.BoundedSemaphore(2)


def _repo_env_file() -> Path:
    override = os.environ.get("JARVIS_ENV_FILE")
    if override:
        return Path(override).expanduser()
    return PROJECT_ROOT / ".env"


ENV_FILE = _repo_env_file()

import sys
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

app = FastAPI(title="Jarvis Voice Auth Service", version="2.1.0")
logger = logging.getLogger("uvicorn.error.jarvis")
app.state.auth_token = None


@app.on_event("startup")
def initialize_local_auth():
    # The Rust parent owns the public token file. Its private voice worker
    # receives the token through its environment and never rotates that file.
    supplied = os.environ.get("JARVIS_HELPER_AUTH_TOKEN", "") if os.environ.get("JARVIS_VOICE_ONLY") == "1" else ""
    if supplied and (not 32 <= len(supplied) <= 128 or not re.fullmatch(r"[A-Za-z0-9_-]+", supplied)):
        raise RuntimeError("Invalid private helper authentication")
    app.state.auth_token = supplied or create_token(data_directory())


@app.middleware("http")
async def require_local_auth(request, call_next):
    if not authorized(app.state.auth_token, request.headers.get(HEADER)):
        return JSONResponse(status_code=401, content={"detail": "Local authentication required"})
    return await call_next(request)



# Learned intent parser (t5-small int8 ONNX) — lazy-loaded on first request;
# missing model degrades to 503 and the app falls back to the rule router.
from intent_router_model import router as intent_router  # noqa: E402

app.include_router(intent_router)

# Load on first voice request, on the dedicated worker. Command routing and
# health checks no longer wait for the voice model to initialize at startup.
encoder = None
_voice_stack = None


def _load_voice_stack():
    """Import resemblyzer (and transitively torch) on the first voice
    request. A backend started only for intent/health stays ~5x
    smaller in RAM than one that preloads torch at import time."""
    global _voice_stack
    if _voice_stack is None:
        from resemblyzer import VoiceEncoder as _VE, preprocess_wav as _pw
        _voice_stack = (_VE, _pw)
    return _voice_stack

def _load_embeddings() -> np.ndarray:
    with _embeddings_lock:
        path = EMBEDDINGS_FILE
        if not path.exists():
            return np.empty((0, 256), dtype=np.float32)
        embeddings = np.load(path, allow_pickle=False)
        if embeddings.ndim == 1:
            embeddings = embeddings.reshape(1, -1)
        if embeddings.ndim != 2 or embeddings.shape[1] != 256:
            raise ValueError("Invalid voice profile shape")
        return embeddings.astype(np.float32)


def _save_embeddings(embeddings: np.ndarray) -> None:
    with _embeddings_lock:
        EMBEDDINGS_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = None
        try:
            with NamedTemporaryFile(dir=EMBEDDINGS_FILE.parent, suffix=".npy", delete=False) as handle:
                temporary = Path(handle.name)
                np.save(handle, embeddings.astype(np.float32), allow_pickle=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, EMBEDDINGS_FILE)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def _load_env_values(secret_keys=None) -> dict[str, str]:
    defaults = {**read_env(BASE_DIR / ".env"), **read_env(_repo_env_file()), **os.environ}
    return _runtime_config.load(defaults) if secret_keys is None else _runtime_config.load(defaults, secret_keys=secret_keys)


def _persist_env_updates(updates: dict[str, str]) -> None:
    # Kept as a compatibility wrapper; never writes or executes .env files.
    try:
        _runtime_config.save(updates)
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Could not save connection settings: {error}") from error


def _trim_silence(wav: np.ndarray, threshold_db: float = -40.0, frame_len: int = 1024) -> np.ndarray:
    """Trim leading/trailing silence from a waveform."""
    if len(wav) == 0:
        return wav

    threshold = 10.0 ** (threshold_db / 20.0)

    # Find first frame above threshold
    start = 0
    for i in range(0, len(wav) - frame_len, frame_len):
        rms = np.sqrt(np.mean(wav[i : i + frame_len] ** 2))
        if rms > threshold:
            start = max(0, i - frame_len)
            break

    # Find last frame above threshold
    end = len(wav)
    for i in range(len(wav) - frame_len, 0, -frame_len):
        rms = np.sqrt(np.mean(wav[i : i + frame_len] ** 2))
        if rms > threshold:
            end = min(len(wav), i + 2 * frame_len)
            break

    trimmed = wav[start:end]
    # Guard: if trimming removed everything, return original
    return trimmed if len(trimmed) > 4000 else wav


def _normalize_volume(wav: np.ndarray) -> np.ndarray:
    """Peak-normalize waveform to [-1, 1]."""
    peak = np.max(np.abs(wav))
    if peak > 0:
        return wav / peak
    return wav


def _embedding_from_audio_bytes(content: bytes, suffix: str) -> np.ndarray:
    global encoder
    voice_encoder_cls, preprocess_wav = _load_voice_stack()
    if encoder is None:
        encoder = voice_encoder_cls()
    with NamedTemporaryFile(delete=True, suffix=suffix) as temp_file:
        temp_file.write(content)
        temp_file.flush()

        wav = preprocess_wav(temp_file.name)

    # Lightweight noise handling
    wav = _trim_silence(wav)
    wav = _normalize_volume(wav)

    embedding = encoder.embed_utterance(wav)
    return embedding.astype(np.float32)


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denominator == 0.0:
        return 0.0
    return float(np.dot(a, b) / denominator)


# ──────────────────────────────────────────────────────────────────────
# Weighted similarity scoring
# ──────────────────────────────────────────────────────────────────────

def _compute_weighted_score(similarities: list[float]) -> dict:
    """
    Compute final similarity score using weighted combination:
      final = 0.6 * max + 0.4 * average
    Also returns confidence classification.
    """
    if not similarities:
        return {"similarity": 0.0, "max_similarity": 0.0,
                "avg_similarity": 0.0, "confidence": "none"}

    max_sim = max(similarities)
    avg_sim = sum(similarities) / len(similarities)
    final = 0.6 * max_sim + 0.4 * avg_sim

    # Confidence classification
    if final >= 0.75:
        confidence = "strong"
    elif final >= 0.65:
        confidence = "low"
    else:
        confidence = "rejected"

    return {
        "similarity": round(float(final), 4),
        "max_similarity": round(float(max_sim), 4),
        "avg_similarity": round(float(avg_sim), 4),
        "confidence": confidence,
        "samples_compared": len(similarities),
    }


# ──────────────────────────────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────────────────────────────

@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "api_version": 4,
            "credential_owner_pid": int(os.environ.get("JARVIS_CREDENTIAL_OWNER_PID", "0"))}


def _postgres_values() -> dict[str, str]:
    env = _load_env_values({"PGPASSWORD"})
    return {key: (str(env.get(key, "") or "") if key == "PGPASSWORD"
                  else str(env.get(key, "") or "").strip()) for key in _PG_ALL_KEYS}


def _postgres_missing(values: dict[str, str]) -> list[str]:
    return [key for key in _PG_REQUIRED_KEYS if not values.get(key)]


@app.get("/postgres/status")
def postgres_status() -> Dict[str, Any]:
    values = _postgres_values()
    missing = _postgres_missing(values)
    return {
        "status": "ok",
        "configured": not missing,
        "host": values["PGHOST"],
        "port": values["PGPORT"] or "5432",
        "database": values["PGDATABASE"],
        "user": values["PGUSER"],
        "password_present": bool(values["PGPASSWORD"]),
        "missing": missing,
    }


@app.post("/postgres/credentials")
def postgres_save_credentials(payload: Dict[str, Any]) -> Dict[str, Any]:
    host = str(payload.get("host", "") or "").strip()
    port = str(payload.get("port", "") or "").strip() or "5432"
    database = str(payload.get("database", "") or "").strip()
    user = str(payload.get("user", "") or "").strip()
    password = str(payload.get("password", "") or "")
    if not host or not database or not user:
        raise HTTPException(
            status_code=400, detail="host, database and user are required"
        )
    updates = {
        "PGHOST": host,
        "PGPORT": port,
        "PGDATABASE": database,
        "PGUSER": user,
    }
    if password:
        updates["PGPASSWORD"] = password
    _persist_env_updates(updates)
    return {"status": "ok", "message": "Postgres credentials saved."}


@app.post("/postgres/test")
def postgres_test(payload: Dict[str, Any]) -> Dict[str, Any]:
    import shutil
    import subprocess

    values = _postgres_values()
    override_password = str(payload.get("password", "") or "")
    missing = _postgres_missing(values)
    if missing:
        raise HTTPException(
            status_code=400, detail=f"missing: {', '.join(missing)}"
        )
    candidates = ["/opt/homebrew/bin/psql", "/opt/homebrew/opt/postgresql@18/bin/psql",
                  "/usr/local/bin/psql", "/usr/local/opt/postgresql@18/bin/psql", "/usr/bin/psql"]
    psql = shutil.which("psql") or next((path for path in candidates if os.access(path, os.X_OK)), candidates[-1])
    env = dict(os.environ)
    env["PGPASSWORD"] = override_password or values["PGPASSWORD"]
    env["PGCONNECT_TIMEOUT"] = "5"
    env["PGOPTIONS"] = (env.get("PGOPTIONS", "") + " -c statement_timeout=8000")
    try:
        proc = subprocess.run(
            [psql, "-h", values["PGHOST"], "-p", values["PGPORT"] or "5432",
             "-d", values["PGDATABASE"], "-U", values["PGUSER"],
             "-X", "-w", "-v", "ON_ERROR_STOP=1", "-tAc", "SELECT 1"],
            capture_output=True, text=True, timeout=10, env=env,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="connection timed out after 10s")
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"could not run psql: {exc}")
    if proc.returncode != 0 or proc.stdout.strip() != "1":
        detail = (proc.stderr or proc.stdout).strip()[:300] or "connection refused"
        raise HTTPException(status_code=500, detail=detail)
    return {"status": "ok", "message": "Connection OK — SELECT 1 returned 1."}


@app.get("/stats")
def stats() -> dict[str, int]:
    enrolled = _load_embeddings().shape[0]
    return {"enrolled_count": int(enrolled)}


async def _read_voice_upload(file: UploadFile) -> tuple[bytes, str]:
    # Bound decoded work and memory before handing off to the single worker.
    content = await file.read(10 * 1024 * 1024 + 1)
    if not content:
        raise HTTPException(status_code=400, detail="Empty audio file")
    if len(content) > 10 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Audio file exceeds 10 MB")
    return content, Path(file.filename or "sample.wav").suffix or ".wav"


async def _run_voice_job(function, *args):
    # The thread pool is intentionally single-worker (one shared encoder).
    # Admission is bounded so repeated requests cannot build an unbounded queue.
    if not _voice_slots.acquire(blocking=False):
        raise HTTPException(status_code=503, detail="Voice service busy; try again shortly")
    try:
        future = _voice_executor.submit(partial(function, *args))
    except BaseException:
        _voice_slots.release()
        raise
    # Release when CPU work actually ends, even if its HTTP caller disconnects.
    future.add_done_callback(lambda _: _voice_slots.release())
    return await asyncio.wrap_future(future)


def _enroll_audio(content: bytes, suffix: str) -> dict[str, int]:
    try:
        embedding = _embedding_from_audio_bytes(content, suffix=suffix)
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Enrollment failed: {error}")
    with _embeddings_lock:
        existing = _load_embeddings()
        updated = np.vstack([existing, embedding.reshape(1, -1)]) if existing.size else embedding.reshape(1, -1)
        _save_embeddings(updated)
    return {"enrolled_count": int(updated.shape[0])}


def _verify_audio(content: bytes, suffix: str) -> dict:
    known = _load_embeddings()
    if known.shape[0] == 0:
        return {"similarity": 0.0, "max_similarity": 0.0,
                "avg_similarity": 0.0, "confidence": "none", "samples_compared": 0}
    try:
        candidate = _embedding_from_audio_bytes(content, suffix=suffix)
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Verification failed: {error}")
    return _compute_weighted_score([_cosine_similarity(candidate, row) for row in known])


@app.post("/enroll")
async def enroll(file: UploadFile = File(...)) -> dict[str, int]:
    content, suffix = await _read_voice_upload(file)
    return await _run_voice_job(_enroll_audio, content, suffix)


@app.post("/verify")
async def verify(file: UploadFile = File(...)) -> dict:
    content, suffix = await _read_voice_upload(file)
    return await _run_voice_job(_verify_audio, content, suffix)


def _reset_profile() -> dict[str, int]:
    _save_embeddings(np.empty((0, 256), dtype=np.float32))
    return {"enrolled_count": 0}


@app.post("/reset")
async def reset() -> dict[str, int]:
    return await _run_voice_job(_reset_profile)
