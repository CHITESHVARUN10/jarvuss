# Jarvis Speaker Auth Backend (Offline)

FastAPI service using Resemblyzer for local speaker recognition.

## Setup

```zsh
cd /Users/chiteshvarun/D-drive/jarvis/backend
/opt/homebrew/bin/python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

## Run

```zsh
cd /Users/chiteshvarun/D-drive/jarvis/backend
source .venv/bin/activate
python -m uvicorn voice_auth_service:app --host 127.0.0.1 --port 8000
```

## Endpoints

- `POST /enroll` with form field `file` (audio) -> stores voice embedding
- `POST /verify` with form field `file` (audio) -> returns `{ "similarity": <0-1> }`
- `POST /reset` -> clears enrolled embeddings for a fresh enrollment session
- `GET /stats` -> returns `{ "enrolled_count": <int> }`
- `GET /health` -> service health

Embeddings are stored in `backend/embeddings.npy`.
