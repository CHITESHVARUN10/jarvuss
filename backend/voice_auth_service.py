from __future__ import annotations

import base64
import json
import os
import time
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import urlencode
from urllib.error import HTTPError
from typing import Any, Dict

import numpy as np
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.responses import RedirectResponse
from resemblyzer import VoiceEncoder, preprocess_wav

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent
EMBEDDINGS_FILE = BASE_DIR / "embeddings.npy"
ENV_FILE = PROJECT_ROOT / ".env"

import sys
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

app = FastAPI(title="Jarvis Voice Auth Service", version="2.1.0")

# Encoder is initialised ONCE at startup — never reloaded.
encoder = VoiceEncoder()

SPOTIFY_AUTH_URL = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_SCOPES = [
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-library-read",
    "playlist-read-private",
]

spotify_tokens: Dict[str, Any] = {
    "access_token": "",
    "refresh_token": "",
    "expires_at": 0,
}


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


def _load_env_values() -> dict[str, str]:
    values: dict[str, str] = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            values[key.strip()] = value.strip()

    for key, value in os.environ.items():
        values[key] = value
    return values


def _persist_env_updates(updates: dict[str, str]) -> None:
    lines = []
    if ENV_FILE.exists():
        lines = ENV_FILE.read_text(encoding="utf-8").splitlines()

    line_index_by_key: dict[str, int] = {}
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key = stripped.split("=", 1)[0].strip()
        line_index_by_key[key] = index

    for key, value in updates.items():
        new_line = f"{key}={value}"
        if key in line_index_by_key:
            lines[line_index_by_key[key]] = new_line
        else:
            lines.append(new_line)

    ENV_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _spotify_config() -> dict[str, str]:
    env = _load_env_values()
    client_id = env.get("SPOTIFY_CLIENT_ID", "")
    client_secret = env.get("SPOTIFY_CLIENT_SECRET", "")
    redirect_uri = env.get("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8000/spotify/callback")
    return {
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": redirect_uri,
    }


def _store_spotify_tokens(access_token: str, refresh_token: str, expires_in: int) -> None:
    expires_at = int(time.time()) + int(expires_in)
    spotify_tokens["access_token"] = access_token
    if refresh_token:
        spotify_tokens["refresh_token"] = refresh_token
    spotify_tokens["expires_at"] = expires_at

    updates = {
        "SPOTIFY_ACCESS_TOKEN": access_token,
        "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT": str(expires_at),
    }
    if refresh_token:
        updates["SPOTIFY_REFRESH_TOKEN"] = refresh_token

    _persist_env_updates(updates)


def _exchange_code_for_token(code: str) -> dict:
    config = _spotify_config()
    client_id = config["client_id"]
    client_secret = config["client_secret"]
    redirect_uri = config["redirect_uri"]

    if not client_id or not client_secret:
        raise HTTPException(status_code=500, detail="Missing Spotify client credentials")

    auth_header = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("utf-8")
    body = urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
        }
    ).encode("utf-8")

    request = Request(
        SPOTIFY_TOKEN_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Basic {auth_header}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )

    try:
        with urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return payload
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Spotify token exchange failed: {error}")


def _refresh_spotify_token() -> str:
    config = _spotify_config()
    client_id = config["client_id"]
    client_secret = config["client_secret"]
    env_values = _load_env_values()

    refresh_token = (
        str(spotify_tokens.get("refresh_token") or "")
        or env_values.get("SPOTIFY_REFRESH_TOKEN", "")
    )

    if not client_id or not client_secret or not refresh_token:
        raise HTTPException(status_code=401, detail="Spotify refresh token unavailable")

    auth_header = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("utf-8")
    body = urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
    ).encode("utf-8")

    request = Request(
        SPOTIFY_TOKEN_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Basic {auth_header}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )

    try:
        with urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as error:
        raise HTTPException(status_code=400, detail=f"Spotify token refresh failed: {error}")

    access_token = payload.get("access_token", "")
    expires_in = int(payload.get("expires_in", 3600))
    returned_refresh = payload.get("refresh_token", refresh_token)

    if not access_token:
        raise HTTPException(status_code=400, detail="Spotify refresh response missing access token")

    _store_spotify_tokens(
        access_token=access_token,
        refresh_token=returned_refresh,
        expires_in=expires_in,
    )
    print("[Spotify] Token refreshed")
    return access_token


def _get_valid_spotify_access_token() -> str:
    env_values = _load_env_values()
    now = int(time.time())

    access_token = (
        str(spotify_tokens.get("access_token") or "")
        or env_values.get("SPOTIFY_ACCESS_TOKEN", "")
    )

    expires_at_raw = (
        str(spotify_tokens.get("expires_at") or "")
        or env_values.get("SPOTIFY_ACCESS_TOKEN_EXPIRES_AT", "0")
    )
    try:
        expires_at = int(expires_at_raw)
    except ValueError:
        expires_at = 0

    if access_token and expires_at > now + 30:
        spotify_tokens["access_token"] = access_token
        spotify_tokens["expires_at"] = expires_at
        if not spotify_tokens.get("refresh_token") and env_values.get("SPOTIFY_REFRESH_TOKEN"):
            spotify_tokens["refresh_token"] = env_values.get("SPOTIFY_REFRESH_TOKEN", "")
        return access_token

    return _refresh_spotify_token()


def _spotify_api_request(
    method: str,
    path: str,
    token: str,
    query: dict[str, str] | None = None,
    body: dict | None = None,
) -> tuple[int, dict | None, str]:
    query_text = f"?{urlencode(query)}" if query else ""
    url = f"https://api.spotify.com{path}{query_text}"
    data = json.dumps(body).encode("utf-8") if body is not None else None

    request = Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8")
            payload = json.loads(raw) if raw else None
            return int(response.status), payload, raw
    except HTTPError as error:
        raw = error.read().decode("utf-8") if error.fp else str(error)
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = None
        return int(error.code), payload, raw
    except Exception as error:
        return -1, None, str(error)


def _spotify_devices(token: str) -> list[dict]:
    status, payload, raw = _spotify_api_request("GET", "/v1/me/player/devices", token)
    print(f"[Spotify] GET /v1/me/player/devices status={status}")
    if status < 200 or status >= 300:
        print(f"[Spotify][ERROR] devices failed: {raw}")
        return []
    devices = payload.get("devices", []) if isinstance(payload, dict) else []
    for device in devices:
        print(
            "[Spotify] Device id={id} name={name} active={active} type={type}".format(
                id=device.get("id", ""),
                name=device.get("name", "unknown"),
                active=bool(device.get("is_active", False)),
                type=device.get("type", "unknown"),
            )
        )
    return devices


def _ensure_spotify_active_device(token: str) -> str | None:
    devices = _spotify_devices(token)
    for device in devices:
        if device.get("is_active") and device.get("id"):
            return str(device["id"])

    print("[Spotify] No active device found; trying transfer")

    if not devices:
        return None

    candidate_id = str(devices[0].get("id", ""))
    if not candidate_id:
        return None

    status, _, raw = _spotify_api_request(
        "PUT",
        "/v1/me/player",
        token,
        body={"device_ids": [candidate_id], "play": True},
    )
    print(f"[Spotify] PUT /v1/me/player transfer status={status}")
    if status < 200 or status >= 300:
        print(f"[Spotify][ERROR] transfer failed: {raw}")
        return None

    time.sleep(1.0)
    devices_after = _spotify_devices(token)
    for device in devices_after:
        if device.get("is_active") and device.get("id"):
            return str(device["id"])

    return None


def _spotify_playback_state(token: str) -> dict:
    status, payload, raw = _spotify_api_request("GET", "/v1/me/player", token)
    print(f"[Spotify] GET /v1/me/player status={status}")
    if status == 204:
        state = {
            "is_playing": False,
            "device": "none",
            "device_id": "",
            "current_track": "none",
            "item": "none",
        }
        print(f"[Spotify] Playback state {state}")
        return state

    if status < 200 or status >= 300 or not isinstance(payload, dict):
        print(f"[Spotify][ERROR] playback state failed: {raw}")
        return {"is_playing": False, "device": "unknown", "item": "unknown"}

    device = payload.get("device") or {}
    item = payload.get("item") or {}
    state = {
        "is_playing": bool(payload.get("is_playing", False)),
        "device": device.get("name", "unknown"),
        "device_id": device.get("id", ""),
        "current_track": item.get("name", "unknown"),
        "item": item.get("name", "unknown"),
    }
    print(f"[Spotify] Playback state {state}")
    return state


def _spotify_error_reason(status: int, raw: str, fallback: str) -> str:
    lowered = (raw or "").lower()
    if status == 403:
        return "403 restriction/premium or device limitation"
    if "no active device" in lowered:
        return "no active device"
    if status == 401:
        return "unauthorized token"
    if status == 404:
        return "resource not found"
    if status < 0:
        return "network/request failure"
    return fallback


def _log_spotify_action_attempt(endpoint: str, status: int, raw: str, reason: str) -> None:
    print(f"[Spotify] endpoint={endpoint}")
    print(f"[Spotify] status_code={status}")
    print(f"[Spotify] raw_body={raw}")
    print(f"[Spotify] interpreted_reason={reason}")


def _is_retryable_spotify_failure(status: int, raw: str) -> bool:
    lowered = (raw or "").lower()
    return status == 403 or "no active device" in lowered


def _spotify_play(token: str, body: dict, action_label: str) -> dict:
    endpoint = "PUT /v1/me/player/play"

    for attempt in range(2):
        state_before = _spotify_playback_state(token)
        print(
            "[Spotify] pre-action state device_id={id} is_playing={playing} current_track={track}".format(
                id=state_before.get("device_id", ""),
                playing=state_before.get("is_playing", False),
                track=state_before.get("current_track", "unknown"),
            )
        )

        device_id = _ensure_spotify_active_device(token)
        if not device_id:
            reason = "no active device"
            _log_spotify_action_attempt(endpoint, 400, "", reason)
            if attempt == 0:
                time.sleep(0.3)
                continue
            raise HTTPException(status_code=400, detail="No active Spotify device")

        status, _, raw = _spotify_api_request(
            "PUT",
            "/v1/me/player/play",
            token,
            query={"device_id": device_id},
            body=body,
        )

        reason = _spotify_error_reason(status, raw, "spotify play failed")
        _log_spotify_action_attempt(endpoint, status, raw, reason)

        if 200 <= status < 300:
            state_after = _spotify_playback_state(token)
            is_playing = bool(state_after.get("is_playing", False))
            if is_playing:
                return {
                    "status": "ok",
                    "action": action_label,
                    "action_confirmed": True,
                    "device_id": device_id,
                    "message": "Playback started",
                    "playback_state": state_after,
                }
            if attempt == 0:
                time.sleep(0.3)
                continue
            raise HTTPException(status_code=409, detail="Playback command accepted but playback did not start")

        if attempt == 0 and _is_retryable_spotify_failure(status, raw):
            time.sleep(0.3)
            continue

        raise HTTPException(status_code=400, detail=f"Spotify play failed: {reason}")

    raise HTTPException(status_code=400, detail="Spotify play failed after retry")


def _spotify_transport_action(token: str, method: str, path: str, action_label: str) -> dict:
    endpoint = f"{method} {path}"

    for attempt in range(2):
        state_before = _spotify_playback_state(token)
        print(
            "[Spotify] pre-action state device_id={id} is_playing={playing} current_track={track}".format(
                id=state_before.get("device_id", ""),
                playing=state_before.get("is_playing", False),
                track=state_before.get("current_track", "unknown"),
            )
        )

        device_id = _ensure_spotify_active_device(token)
        if not device_id:
            reason = "no active device"
            _log_spotify_action_attempt(endpoint, 400, "", reason)
            if attempt == 0:
                time.sleep(0.3)
                continue
            raise HTTPException(status_code=400, detail="No active Spotify device")

        status, _, raw = _spotify_api_request(
            method,
            path,
            token,
            query={"device_id": device_id},
            body={},
        )

        reason = _spotify_error_reason(status, raw, f"spotify {action_label} failed")
        _log_spotify_action_attempt(endpoint, status, raw, reason)

        if 200 <= status < 300:
            state_after = _spotify_playback_state(token)
            message = (
                "No content (valid for next/previous)"
                if raw == ""
                else f"{action_label} command accepted"
            )
            return {
                "status": "ok",
                "action": action_label,
                "action_confirmed": True,
                "device_id": device_id,
                "message": message,
                "playback_state": state_after,
            }

        if attempt == 0 and _is_retryable_spotify_failure(status, raw):
            time.sleep(0.3)
            continue

        raise HTTPException(status_code=400, detail=f"Spotify {action_label} failed: {reason}")

    raise HTTPException(status_code=400, detail=f"Spotify {action_label} failed after retry")


def _spotify_search_track_uri(token: str, query_text: str) -> str | None:
    status, payload, raw = _spotify_api_request(
        "GET",
        "/v1/search",
        token,
        query={"q": query_text, "type": "track", "limit": "1"},
    )
    print(f"[Spotify] GET /v1/search(track) status={status} q='{query_text}'")
    if status < 200 or status >= 300:
        print(f"[Spotify][ERROR] track search failed: {raw}")
        return None

    if not isinstance(payload, dict):
        return None
    tracks = payload.get("tracks") or {}
    items = tracks.get("items") if isinstance(tracks, dict) else []
    if not items:
        return None
    uri = items[0].get("uri")
    return str(uri) if uri else None


def _normalize_playlist_text(text: str) -> str:
    return " ".join(text.strip().lower().split())


def _spotify_find_playlist_uri(token: str, query_text: str) -> tuple[str, str] | None:
    status, payload, raw = _spotify_api_request(
        "GET",
        "/v1/me/playlists",
        token,
        query={"limit": "50"},
    )
    print(f"[Spotify] GET /v1/me/playlists status={status}")
    if status < 200 or status >= 300:
        print(f"[Spotify][ERROR] playlist list failed: {raw}")
        return None

    if not isinstance(payload, dict):
        return None
    items = payload.get("items", [])
    if not isinstance(items, list):
        return None

    normalized_query = _normalize_playlist_text(query_text)

    for item in items:
        name = str(item.get("name", ""))
        uri = str(item.get("uri", ""))
        if _normalize_playlist_text(name) == normalized_query and uri:
            return name, uri

    for item in items:
        name = str(item.get("name", ""))
        uri = str(item.get("uri", ""))
        candidate = _normalize_playlist_text(name)
        if uri and (normalized_query in candidate or candidate in normalized_query):
            return name, uri

    return None


def _spotify_liked_track_uris(token: str) -> list[str]:
    status, payload, raw = _spotify_api_request(
        "GET",
        "/v1/me/tracks",
        token,
        query={"limit": "50"},
    )
    print(f"[Spotify] GET /v1/me/tracks status={status}")
    if status < 200 or status >= 300:
        print(f"[Spotify][ERROR] liked tracks failed: {raw}")
        return []

    if not isinstance(payload, dict):
        return []
    items = payload.get("items", [])
    if not isinstance(items, list):
        return []

    uris: list[str] = []
    for item in items:
        track = item.get("track") if isinstance(item, dict) else None
        uri = track.get("uri") if isinstance(track, dict) else None
        if uri:
            uris.append(str(uri))
    return uris


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


@app.get("/spotify/login")
def spotify_login() -> RedirectResponse:
    config = _spotify_config()
    client_id = config["client_id"]
    redirect_uri = config["redirect_uri"]
    if not client_id:
        raise HTTPException(status_code=500, detail="Missing SPOTIFY_CLIENT_ID")

    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": " ".join(SPOTIFY_SCOPES),
    }
    print(f"[Spotify] Login redirect_uri: {redirect_uri}")
    auth_url = f"{SPOTIFY_AUTH_URL}?{urlencode(params)}"
    return RedirectResponse(url=auth_url, status_code=307)


@app.get("/spotify/callback")
def spotify_callback(code: str = Query(...)) -> Dict[str, Any]:
    token_payload = _exchange_code_for_token(code)

    access_token = token_payload.get("access_token", "")
    refresh_token = token_payload.get("refresh_token", "")
    expires_in = int(token_payload.get("expires_in", 3600))

    if not access_token:
        raise HTTPException(status_code=400, detail="Spotify callback missing access token")

    _store_spotify_tokens(access_token=access_token, refresh_token=refresh_token, expires_in=expires_in)
    print("[Spotify] Access token received")
    print(f"[Spotify] Refresh token received: {bool(refresh_token)}")

    return {
        "status": "ok",
        "message": "Spotify authorization successful",
        "expires_in": expires_in,
    }


@app.get("/callback")
def spotify_callback_alias(code: str = Query(...)) -> Dict[str, Any]:
    return spotify_callback(code=code)


@app.get("/spotify/token")
def spotify_token() -> Dict[str, Any]:
    token = _get_valid_spotify_access_token()
    expires_at = int(spotify_tokens.get("expires_at") or 0)
    return {
        "status": "ok",
        "access_token_present": bool(token),
        "expires_at": expires_at,
    }


@app.post("/spotify/play")
def spotify_play() -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/play token_present={bool(token)}")
    return _spotify_play(token=token, body={}, action_label="play")


@app.post("/spotify/play-song")
def spotify_play_song(name: str = Query(..., min_length=1)) -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/play-song name='{name}' token_present={bool(token)}")
    uri = _spotify_search_track_uri(token, name)
    if not uri:
        raise HTTPException(status_code=404, detail=f"Song not found: {name}")
    return _spotify_play(token=token, body={"uris": [uri]}, action_label="play-song")


@app.post("/spotify/play-playlist")
def spotify_play_playlist(name: str = Query(..., min_length=1)) -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/play-playlist name='{name}' token_present={bool(token)}")
    match = _spotify_find_playlist_uri(token, name)
    if not match:
        raise HTTPException(status_code=404, detail=f"Playlist not found: {name}")
    matched_name, uri = match
    result = _spotify_play(token=token, body={"context_uri": uri}, action_label="play-playlist")
    result["matched_playlist_name"] = matched_name
    return result


@app.post("/spotify/play-liked")
def spotify_play_liked() -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/play-liked token_present={bool(token)}")
    uris = _spotify_liked_track_uris(token)
    if not uris:
        raise HTTPException(status_code=404, detail="No liked songs found")
    return _spotify_play(token=token, body={"uris": uris}, action_label="play-liked")


@app.post("/spotify/pause")
def spotify_pause() -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/pause token_present={bool(token)}")
    return _spotify_transport_action(token, "PUT", "/v1/me/player/pause", "pause")


@app.post("/spotify/next")
def spotify_next() -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/next token_present={bool(token)}")
    return _spotify_transport_action(token, "POST", "/v1/me/player/next", "next")


@app.post("/spotify/previous")
def spotify_previous() -> dict:
    token = _get_valid_spotify_access_token()
    print(f"[Spotify] /spotify/previous token_present={bool(token)}")
    return _spotify_transport_action(token, "POST", "/v1/me/player/previous", "previous")


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

