from __future__ import annotations

from pathlib import Path
from tempfile import NamedTemporaryFile

import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from resemblyzer import VoiceEncoder, preprocess_wav

BASE_DIR = Path(__file__).resolve().parent
EMBEDDINGS_FILE = BASE_DIR / "embeddings.npy"

app = FastAPI(title="Jarvis Voice Auth Service", version="2.0.0")

# Encoder is initialised ONCE at startup — never reloaded.
encoder = VoiceEncoder()


# ──────────────────────────────────────────────────────────────────────
# Embedding storage
# ──────────────────────────────────────────────────────────────────────

def _load_embeddings() -> np.ndarray:
    if not EMBEDDINGS_FILE.exists():
        return np.empty((0, 256), dtype=np.float32)

    embeddings = np.load(EMBEDDINGS_FILE)
    if embeddings.ndim == 1:
        embeddings = embeddings.reshape(1, -1)
    return embeddings.astype(np.float32)


def _save_embeddings(embeddings: np.ndarray) -> None:
    np.save(EMBEDDINGS_FILE, embeddings.astype(np.float32))


# ──────────────────────────────────────────────────────────────────────
# Audio processing helpers
# ──────────────────────────────────────────────────────────────────────

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
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/stats")
def stats() -> dict[str, int]:
    enrolled = _load_embeddings().shape[0]
    return {"enrolled_count": int(enrolled)}


@app.post("/enroll")
async def enroll(file: UploadFile = File(...)) -> dict[str, int]:
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Empty audio file")

    suffix = Path(file.filename or "sample.wav").suffix or ".wav"

    try:
        embedding = _embedding_from_audio_bytes(content, suffix=suffix)
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Enrollment failed: {error}")

    existing = _load_embeddings()
    updated = (
        np.vstack([existing, embedding.reshape(1, -1)])
        if existing.size
        else embedding.reshape(1, -1)
    )
    _save_embeddings(updated)

    return {"enrolled_count": int(updated.shape[0])}


@app.post("/verify")
async def verify(file: UploadFile = File(...)) -> dict:
    """
    Verify speaker against ALL stored embeddings.
    Returns weighted score (0.6*max + 0.4*avg), confidence level,
    and detailed similarity breakdown.
    """
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Empty audio file")

    known = _load_embeddings()
    if known.shape[0] == 0:
        return {"similarity": 0.0, "max_similarity": 0.0,
                "avg_similarity": 0.0, "confidence": "none",
                "samples_compared": 0}

    suffix = Path(file.filename or "sample.wav").suffix or ".wav"

    try:
        candidate = _embedding_from_audio_bytes(content, suffix=suffix)
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Verification failed: {error}")

    similarities = [_cosine_similarity(candidate, row) for row in known]
    return _compute_weighted_score(similarities)


@app.post("/reset")
def reset() -> dict[str, int]:
    _save_embeddings(np.empty((0, 256), dtype=np.float32))
    return {"enrolled_count": 0}
