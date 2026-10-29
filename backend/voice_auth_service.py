from __future__ import annotations

import base64
import json
import os
import time
import threading
import random
import re
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import asyncio
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from typing import Any, Dict

import ssl
import logging
from functools import wraps

import numpy as np
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.responses import RedirectResponse, JSONResponse
from runtime_config import RuntimeConfig, data_directory, read_env
from local_auth import HEADER, OAuthStates, authorized, create_token

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
_oauth_states = OAuthStates()


@app.on_event("startup")
def initialize_local_auth():
    app.state.auth_token = create_token(data_directory())


@app.middleware("http")
async def require_local_auth(request, call_next):
    # OAuth redirects are browser requests; their single-use state is checked
    # by the callback before any token exchange or credential mutation.
    if request.method == "GET" and request.url.path in {"/spotify/callback", "/callback"}:
        return await call_next(request)
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
    request. A backend started only for Spotify/intent/health stays ~5x
    smaller in RAM than one that preloads torch at import time."""
    global _voice_stack
    if _voice_stack is None:
        from resemblyzer import VoiceEncoder as _VE, preprocess_wav as _pw
        _voice_stack = (_VE, _pw)
    return _voice_stack

SPOTIFY_AUTH_URL = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_SCOPES = [
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-library-read",
    "playlist-read-private",
]

def _https_context() -> ssl.SSLContext:
    # python.org Python ships its own OpenSSL WITHOUT system roots — the
    # bundled cert.pem is often missing, so every HTTPS call dies with
    # CERTIFICATE_VERIFY_FAILED. certifi (Mozilla bundle, already in the
    # venv via requirements) fixes it. Falls back to the default context
    # when certifi is unavailable.
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _spotify_token_error_detail(prefix: str, error: Exception) -> str:
    # Spotify answers failed token calls with JSON like
    # {"error": "invalid_grant", "error_description": "..."}. urlopen raises
    # HTTPError and DISCARDS that body unless we read it — so read it.
    if isinstance(error, HTTPError):
        try:
            raw = error.read().decode("utf-8")
        except Exception:
            raw = ""
        if raw:
            try:
                payload = json.loads(raw)
                err = str(payload.get("error", ""))
                desc = str(payload.get("error_description", ""))
                if err or desc:
                    return f"{prefix}: {err} — {desc}"
            except Exception:
                pass
            return f"{prefix}: HTTP {error.code}: {raw[:300]}"
        return f"{prefix}: HTTP {error.code}"
    return f"{prefix}: {error}"


_spotify_token_lock = threading.RLock()


def _token_serialized(function):
    @wraps(function)
    def protected(*args, **kwargs):
        with _spotify_token_lock:
            return function(*args, **kwargs)
    return protected


spotify_tokens: Dict[str, Any] = {
    "access_token": "",
    "refresh_token": "",
    "expires_at": 0,
}


# ──────────────────────────────────────────────────────────────────────
# Embedding storage
# ──────────────────────────────────────────────────────────────────────

def _load_embeddings() -> np.ndarray:
    with _embeddings_lock:
        path = EMBEDDINGS_FILE
        if not path.exists():
            # Read-only migration source for existing installations.
            path = BASE_DIR / "embeddings.npy"
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


def _spotify_config() -> dict[str, str]:
    env = _load_env_values({"SPOTIFY_CLIENT_SECRET"})
    client_id = env.get("SPOTIFY_CLIENT_ID", "")
    client_secret = env.get("SPOTIFY_CLIENT_SECRET", "")
    redirect_uri = env.get("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8000/spotify/callback")
    return {
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": redirect_uri,
    }


@_token_serialized
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

    logger.info(f"[Spotify] Exchange redirect_uri: {redirect_uri}")
    try:
        with urlopen(request, timeout=15, context=_https_context()) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return payload
    except Exception as error:
        raise HTTPException(
            status_code=400,
            detail=_spotify_token_error_detail("Spotify token exchange failed", error),
        )


@_token_serialized
def _refresh_spotify_token() -> str:
    config = _spotify_config()
    client_id = config["client_id"]
    client_secret = config["client_secret"]
    env_values = _load_env_values({"SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"})

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
        with urlopen(request, timeout=15, context=_https_context()) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as error:
        raise HTTPException(
            status_code=400,
            detail=_spotify_token_error_detail("Spotify token refresh failed", error),
        )

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
    logger.info("[Spotify] Token refreshed")
    return access_token


@_token_serialized
def _get_valid_spotify_access_token() -> str:
    env_values = _load_env_values({"SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"})
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
        with urlopen(request, timeout=15, context=_https_context()) as response:
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
    logger.info(f"[Spotify] GET /v1/me/player/devices status={status}")
    if status < 200 or status >= 300:
        logger.info(f"[Spotify][ERROR] devices failed: {raw}")
        return []
    devices = payload.get("devices", []) if isinstance(payload, dict) else []
    for device in devices:
        logger.info(
            "[Spotify] Device id={id} name={name} active={active} type={type}".format(
                id=device.get("id", ""),
                name=device.get("name", "unknown"),
                active=bool(device.get("is_active", False)),
                type=device.get("type", "unknown"),
            )
        )
    return devices


_device_cache_lock = threading.Lock()
_device_cache: dict[str, Any] = {"token": "", "id": "", "expires_at": 0.0}


def _cache_spotify_device(token: str, device_id: str) -> str:
    with _device_cache_lock:
        _device_cache.update(token=token, id=device_id, expires_at=time.monotonic() + 5)
    return device_id


def _invalidate_spotify_device() -> None:
    with _device_cache_lock:
        _device_cache["expires_at"] = 0.0


def _ensure_spotify_active_device(token: str) -> str | None:
    with _device_cache_lock:
        if _device_cache["token"] == token and _device_cache["expires_at"] > time.monotonic():
            return str(_device_cache["id"])
    devices = _spotify_devices(token)
    devices = [device for device in devices if device.get("id") and not device.get("is_restricted", False)]
    for device in devices:
        if device.get("is_active") and device.get("id"):
            return _cache_spotify_device(token, str(device["id"]))

    logger.info("[Spotify] No active device found; trying transfer")

    if not devices:
        return None

    candidate = next((device for device in devices if str(device.get("type", "")).lower() == "computer"), devices[0])
    candidate_id = str(candidate.get("id", ""))
    if not candidate_id:
        return None

    status, _, raw = _spotify_api_request(
        "PUT",
        "/v1/me/player",
        token,
        body={"device_ids": [candidate_id], "play": False},
    )
    logger.info(f"[Spotify] PUT /v1/me/player transfer status={status}")
    if status < 200 or status >= 300:
        logger.info(f"[Spotify][ERROR] transfer failed: {raw}")
        raise HTTPException(status_code=status if status in (401, 403, 429) else 502,
                            detail=f"Spotify device activation failed: {_spotify_error_reason(status, raw, 'try selecting this Mac in Spotify')}")

    # Device discovery is eventually consistent. A successful transfer gives
    # us an explicit target; do not require its is_active flag to update before
    # sending the command. The action request below confirms acceptance.
    return _cache_spotify_device(token, candidate_id)


def _spotify_playback_state(token: str) -> dict:
    status, payload, raw = _spotify_api_request("GET", "/v1/me/player", token)
    logger.info(f"[Spotify] GET /v1/me/player status={status}")
    if status == 204:
        state = {
            "is_playing": False,
            "device": "none",
            "device_id": "",
            "current_track": "none",
            "item": "none",
        }
        logger.info(f"[Spotify] Playback state {state}")
        return state

    if status < 200 or status >= 300 or not isinstance(payload, dict):
        logger.info(f"[Spotify][ERROR] playback state failed: {raw}")
        return {"is_playing": False, "device": "unknown", "item": "unknown"}

    device = payload.get("device") or {}
    item = payload.get("item") or {}
    state = {
        "is_playing": bool(payload.get("is_playing", False)),
        "device": device.get("name", "unknown"),
        "device_id": device.get("id", ""),
        "current_track": item.get("name", "unknown"),
        "item": item.get("name", "unknown"),
        "track_uri": item.get("uri", ""),
        "context_uri": (payload.get("context") or {}).get("uri", ""),
        "shuffle_state": payload.get("shuffle_state"),
    }
    logger.info(f"[Spotify] Playback state {state}")
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
    logger.info(f"[Spotify] endpoint={endpoint}")
    logger.info(f"[Spotify] status_code={status}")
    logger.info(f"[Spotify] raw_body={raw}")
    logger.info(f"[Spotify] interpreted_reason={reason}")


def _is_retryable_spotify_failure(status: int, raw: str) -> bool:
    lowered = (raw or "").lower()
    return "no active device" in lowered or (status in (403, 404) and "device" in lowered)


def _spotify_play(token: str, body: dict, action_label: str) -> dict:
    return _spotify_transport_action(token, "PUT", "/v1/me/player/play", action_label, body)


def _spotify_transport_action(token: str, method: str, path: str, action_label: str,
                              body: dict | None = None, query: dict[str, str] | None = None,
                              target_device: str | None = None) -> dict:
    endpoint = f"{method} {path}"
    for attempt in range(2):
        device_id = target_device or _ensure_spotify_active_device(token)
        if not device_id:
            if attempt == 0:
                # A newly launched Spotify process may not have registered
                # its Web API device yet. Wait only for this dependency.
                time.sleep(0.6)
                continue
            raise HTTPException(status_code=400, detail="No active Spotify device. Open Spotify, sign in, and select this Mac in its device menu, then try again.")
        status, _, raw = _spotify_api_request(
            method, path, token, query={**(query or {}), "device_id": device_id}, body=body,
        )
        reason = "accepted" if 200 <= status < 300 else _spotify_error_reason(status, raw, f"Spotify {action_label} failed")
        _log_spotify_action_attempt(endpoint, status, raw, reason)
        if 200 <= status < 300:
            # API acknowledgement confirms command acceptance. A fresh state
            # read is both expensive and eventually consistent (not a reliable
            # immediate playback check), so keep it on the status path.
            return {"status": "ok", "action": action_label, "action_confirmed": True,
                    "device_id": device_id, "message": f"{action_label} request accepted"}
        if attempt == 0 and _is_retryable_spotify_failure(status, raw):
            _invalidate_spotify_device()
            continue
        raise HTTPException(status_code=400, detail=f"Spotify {action_label} failed: {reason}")
    raise HTTPException(status_code=400, detail=f"Spotify {action_label} failed after retry")


def _spotify_set_shuffle(token: str, enabled: bool, target_device: str | None = None,
                         expected_context: str | None = None, expected_tracks: set[str] | None = None) -> dict:
    result = _spotify_transport_action(token, "PUT", "/v1/me/player/shuffle", "shuffle",
        query={"state": str(enabled).lower()}, target_device=target_device)
    # Spotify acknowledges player writes before the client necessarily applies
    # them. Confirm the mode AND the requested context on the same device.
    for attempt in range(3):
        if attempt: time.sleep(0.15 * attempt)
        state = _spotify_playback_state(token)
        matches_context = (not expected_context or state.get("context_uri") == expected_context)
        matches_track = (not expected_tracks or state.get("track_uri") in expected_tracks)
        if (state.get("shuffle_state") is enabled and state.get("device_id") == result["device_id"]
                and matches_context and matches_track
                and (not (expected_context or expected_tracks) or state.get("is_playing") is True)):
            result.update(shuffle_enabled=enabled, playback_state=state,
                          message=f"Shuffle {'on' if enabled else 'off'} confirmed")
            return result
    raise HTTPException(status_code=409, detail="Spotify did not confirm the requested shuffle mode on the target device. Try again.")


def _spotify_play_with_shuffle(token: str, body: dict, enabled: bool, label: str) -> dict:
    played = _spotify_play(token, body, label)
    try:
        confirmed = _spotify_set_shuffle(token, enabled, target_device=played["device_id"],
            expected_context=body.get("context_uri"), expected_tracks=set(body.get("uris", [])))
    except HTTPException as error:
        raise HTTPException(status_code=error.status_code,
            detail=f"Playback started, but shuffle could not be confirmed: {error.detail}") from error
    played.update(shuffle_enabled=enabled, playback_state=confirmed["playback_state"],
                  message=f"{label} with shuffle {'on' if enabled else 'off'} confirmed")
    return played


def _spotify_random_playlist_offset(token: str, uri: str) -> int:
    playlist_id = uri.rsplit(":", 1)[-1]
    if not re.fullmatch(r"[a-zA-Z0-9]+", playlist_id):
        raise HTTPException(status_code=400, detail="Invalid Spotify playlist identifier")
    # /items is the current API; older Spotify deployments expose /tracks.
    for suffix in ("items", "tracks"):
        status, payload, raw = _spotify_api_request("GET", f"/v1/playlists/{playlist_id}/{suffix}", token, query={"limit": "1"})
        if status == 404 and suffix == "items": continue
        if not 200 <= status < 300 or not isinstance(payload, dict):
            raise HTTPException(status_code=400, detail="Spotify could not read this playlist to choose a random starting track.")
        total = payload.get("total")
        if type(total) is not int or total <= 0:
            raise HTTPException(status_code=404, detail="No playable items found in this playlist")
        return random.SystemRandom().randrange(total)
    raise HTTPException(status_code=404, detail="Playlist items are unavailable")


def _spotify_search_track_uri(token: str, query_text: str) -> str | None:
    status, payload, raw = _spotify_api_request(
        "GET",
        "/v1/search",
        token,
        query={"q": query_text, "type": "track", "limit": "1"},
    )
    logger.info(f"[Spotify] GET /v1/search(track) status={status} q='{query_text}'")
    if status < 200 or status >= 300:
        logger.info(f"[Spotify][ERROR] track search failed: {raw}")
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
    logger.info(f"[Spotify] GET /v1/me/playlists status={status}")
    if status < 200 or status >= 300:
        logger.info(f"[Spotify][ERROR] playlist list failed: {raw}")
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
    logger.info(f"[Spotify] GET /v1/me/tracks status={status}")
    if status < 200 or status >= 300:
        logger.info(f"[Spotify][ERROR] liked tracks failed: {raw}")
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

def _spotify_shuffled_liked_track_uris(token: str) -> list[str]:
    # Sample up to five library pages after one count read; build a 50-track queue.
    # Pages are sampled across the full library, not always the newest saves.
    def page(offset: int) -> dict:
        status, payload, _ = _spotify_api_request("GET", "/v1/me/tracks", token,
            query={"limit": "50", "offset": str(offset)})
        if not 200 <= status < 300 or not isinstance(payload, dict):
            raise HTTPException(status_code=400, detail="Spotify could not load saved tracks for shuffle.")
        return payload

    first = page(0)
    first_items = first.get("items", [])
    if not isinstance(first_items, list):
        raise HTTPException(status_code=502, detail="Spotify returned invalid saved-track data")
    total = first.get("total", len(first_items))
    if type(total) is not int or total < 0:
        raise HTTPException(status_code=400, detail="Spotify returned an invalid saved-track count")
    if total == 0: return []
    rng = random.SystemRandom()
    pages = (total + 49) // 50
    selected = rng.sample(range(pages), min(5, pages))
    unique: dict[str, None] = {}
    for number in selected:
        payload = first if number == 0 else page(number * 50)
        items = payload.get("items", [])
        if not isinstance(items, list):
            raise HTTPException(status_code=502, detail="Spotify returned invalid saved-track data")
        for entry in items:
            track = entry.get("track") if isinstance(entry, dict) else None
            if not isinstance(track, dict) or track.get("is_local") or track.get("is_playable") is False: continue
            uri = track.get("uri")
            if isinstance(uri, str) and uri.startswith("spotify:track:"): unique[uri] = None
    uris = list(unique)
    rng.shuffle(uris)
    return uris[:50]

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
        "state": _oauth_states.issue(),
    }
    logger.info(f"[Spotify] Login redirect_uri: {redirect_uri}")
    auth_url = f"{SPOTIFY_AUTH_URL}?{urlencode(params)}"
    return RedirectResponse(url=auth_url, status_code=307)


@app.get("/spotify/callback")
@_token_serialized
def spotify_callback(
    code: str | None = Query(default=None),
    error: str | None = Query(default=None),
    state: str | None = Query(default=None),
) -> Dict[str, Any]:
    if not isinstance(state, str) or not _oauth_states.consume(state):
        raise HTTPException(status_code=400, detail="Invalid or expired OAuth state; connect again from Jarvis")
    if error:
        raise HTTPException(
            status_code=400, detail=f"Spotify authorization refused: {error}"
        )
    if not code:
        raise HTTPException(status_code=400, detail="Spotify callback missing code")
    token_payload = _exchange_code_for_token(code)

    access_token = token_payload.get("access_token", "")
    refresh_token = token_payload.get("refresh_token", "")
    expires_in = int(token_payload.get("expires_in", 3600))

    if not access_token:
        raise HTTPException(status_code=400, detail="Spotify callback missing access token")

    _store_spotify_tokens(access_token=access_token, refresh_token=refresh_token, expires_in=expires_in)
    logger.info("[Spotify] Access token received")
    logger.info(f"[Spotify] Refresh token received: {bool(refresh_token)}")

    return {
        "status": "ok",
        "message": "Spotify authorization successful",
        "expires_in": expires_in,
    }


@app.get("/callback")
def spotify_callback_alias(
    code: str | None = Query(default=None),
    error: str | None = Query(default=None),
    state: str | None = Query(default=None),
) -> Dict[str, Any]:
    return spotify_callback(code=code, error=error, state=state)


@app.get("/spotify/status")
@_token_serialized
def spotify_status() -> Dict[str, Any]:
    env_values = _load_env_values({"SPOTIFY_CLIENT_SECRET", "SPOTIFY_ACCESS_TOKEN", "SPOTIFY_REFRESH_TOKEN"})
    client_id = env_values.get("SPOTIFY_CLIENT_ID", "")
    has_secret = bool(env_values.get("SPOTIFY_CLIENT_SECRET", ""))
    access_present = bool(
        str(spotify_tokens.get("access_token") or "")
        or env_values.get("SPOTIFY_ACCESS_TOKEN", "")
    )
    expires_at_raw = str(spotify_tokens.get("expires_at") or "") or env_values.get(
        "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT", "0"
    )
    try:
        expires_at = int(expires_at_raw)
    except ValueError:
        expires_at = 0
    return {
        "status": "ok",
        "client_id_present": bool(client_id),
        "client_secret_present": has_secret,
        "access_token_present": access_present,
        "expires_at": expires_at,
        "expired": expires_at <= int(time.time()),
        "redirect_uri": env_values.get(
            "SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8000/spotify/callback"
        ),
    }


@app.post("/spotify/credentials")
@_token_serialized
def spotify_save_credentials(payload: Dict[str, Any]) -> Dict[str, Any]:
    client_id = str(payload.get("client_id", "") or "").strip()
    client_secret = str(payload.get("client_secret", "") or "").strip()
    redirect_uri = str(payload.get("redirect_uri", "") or "").strip()
    if not client_id or not client_secret:
        raise HTTPException(
            status_code=400, detail="client_id and client_secret are required"
        )
    updates = {
        "SPOTIFY_CLIENT_ID": client_id,
        "SPOTIFY_CLIENT_SECRET": client_secret,
        "SPOTIFY_ACCESS_TOKEN": "",
        "SPOTIFY_REFRESH_TOKEN": "",
        "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT": "0",
    }
    if redirect_uri:
        updates["SPOTIFY_REDIRECT_URI"] = redirect_uri
    _persist_env_updates(updates)
    # Drop cached tokens so the next call re-auths against the new app keys.
    spotify_tokens["access_token"] = ""
    spotify_tokens["refresh_token"] = ""
    spotify_tokens["expires_at"] = 0
    _invalidate_spotify_device()
    return {"status": "ok", "message": "Spotify credentials saved. Open the connect link to authorize."}


@app.get("/spotify/connect-url")
def spotify_connect_url() -> Dict[str, Any]:
    config = _spotify_config()
    if not config["client_id"]:
        raise HTTPException(status_code=500, detail="Missing SPOTIFY_CLIENT_ID")
    params = {
        "client_id": config["client_id"],
        "response_type": "code",
        "redirect_uri": config["redirect_uri"],
        "scope": " ".join(SPOTIFY_SCOPES),
        "state": _oauth_states.issue(),
    }
    return {
        "status": "ok",
        "url": f"{SPOTIFY_AUTH_URL}?{urlencode(params)}",
        "redirect_uri": config["redirect_uri"],
    }


@app.get("/spotify/token")
@_token_serialized
def spotify_token() -> Dict[str, Any]:
    token = _get_valid_spotify_access_token()
    expires_at = int(spotify_tokens.get("expires_at") or 0)
    return {
        "status": "ok",
        "access_token_present": bool(token),
        "expires_at": expires_at,
    }


# ── Postgres connection management (Connections pane) ─────────────────
# Same persistence mechanism as Spotify: values live in the backend .env
# via _persist_env_updates. Status never echoes the password back.

_PG_REQUIRED_KEYS = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER"]
_PG_ALL_KEYS = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"]


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


@app.post("/spotify/play")
def spotify_play() -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/play token_present={bool(token)}")
    return _spotify_play(token=token, body={}, action_label="play")


@app.post("/spotify/play-song")
def spotify_play_song(name: str = Query(..., min_length=1)) -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/play-song name='{name}' token_present={bool(token)}")
    uri = _spotify_search_track_uri(token, name)
    if not uri:
        raise HTTPException(status_code=404, detail=f"Song not found: {name}")
    return _spotify_play(token=token, body={"uris": [uri]}, action_label="play-song")


@app.post("/spotify/play-playlist")
def spotify_play_playlist(name: str = Query(..., min_length=1), shuffle: bool | None = None) -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/play-playlist name='{name}' token_present={bool(token)}")
    match = _spotify_find_playlist_uri(token, name)
    if not match:
        raise HTTPException(status_code=404, detail=f"Playlist not found: {name}")
    matched_name, uri = match
    body: dict[str, Any] = {"context_uri": uri}
    if shuffle is True:
        body["offset"] = {"position": _spotify_random_playlist_offset(token, uri)}
    result = (_spotify_play(token=token, body=body, action_label="play-playlist") if shuffle is None
              else _spotify_play_with_shuffle(token, body, shuffle, "play-playlist"))
    result["matched_playlist_name"] = matched_name
    return result


@app.post("/spotify/play-liked")
def spotify_play_liked(shuffle: bool | None = None) -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/play-liked token_present={bool(token)}")
    uris = _spotify_shuffled_liked_track_uris(token) if shuffle is True else _spotify_liked_track_uris(token)
    if not uris:
        detail = "No playable liked tracks were returned in the sampled pages. Try again." if shuffle is True else "No liked songs found"
        raise HTTPException(status_code=404, detail=detail)
    return (_spotify_play(token=token, body={"uris": uris}, action_label="play-liked") if shuffle is None
            else _spotify_play_with_shuffle(token, {"uris": uris}, shuffle, "play-liked"))


@app.post("/spotify/shuffle")
def spotify_shuffle(enabled: bool = Query(...)) -> dict:
    token = _get_valid_spotify_access_token()
    # A standalone mode change must not transfer a device with play=True.
    device = next((entry.get("id") for entry in _spotify_devices(token)
                   if entry.get("is_active") and entry.get("id")), None)
    if not device:
        raise HTTPException(status_code=400, detail="No active Spotify device. Select a device in Spotify before changing shuffle mode.")
    return _spotify_set_shuffle(token, enabled, target_device=str(device))


@app.post("/spotify/pause")
def spotify_pause() -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/pause token_present={bool(token)}")
    return _spotify_transport_action(token, "PUT", "/v1/me/player/pause", "pause")


@app.post("/spotify/next")
def spotify_next() -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/next token_present={bool(token)}")
    return _spotify_transport_action(token, "POST", "/v1/me/player/next", "next")


@app.post("/spotify/previous")
def spotify_previous() -> dict:
    token = _get_valid_spotify_access_token()
    logger.info(f"[Spotify] /spotify/previous token_present={bool(token)}")
    return _spotify_transport_action(token, "POST", "/v1/me/player/previous", "previous")


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
