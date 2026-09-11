# JarvisMacOS

Offline-first macOS assistant in Swift & Python with:

- **Local Ollama Integration**: Powered by `mistral:7b` for offline reasoning & answer synthesis, plus `qwen2.5-coder:1.5b-base` for command planning fallback.
- **Voice Auth & Enrollment**: Resemblyzer speaker verification and 2-layer phrase enrollment.
- **System Automation**: Open/close apps, create files/folders, media/volume/display control, and multi-action workflows.

---

## 🚀 Key Features

### 1. Voice Control
Wake-word (`Jarvis ...`) voice commands with speaker verification gating, session follow-ups, and typed-command fallback.

### 2. System Automation
Open/close apps (alias + fuzzy match), file/folder actions, Spotify playback via backend Web API, volume/brightness/display control, web search + URL open, quick time/date popups.

### 3. Safety First
`SafetyGuard` blocks sudo, destructive ops, protected paths, and install commands (preview only). All checks run pre-plan and per-action.

---

## 🛠️ Installation & Setup

### 1) Prerequisites (macOS)

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake ffmpeg portaudio ollama postgresql@18
```

### 2) Ollama Model Setup

```zsh
ollama pull mistral:7b
ollama pull qwen2.5-coder:1.5b-base
ollama serve
```

### 3) Python Backend Environment

```zsh
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

## 🖥️ Launching Jarvis

### Automated Single-Script Launcher (App + Backend):

```zsh
./scripts/launch_jarvis_app.zsh
```

Or manually start backend & app:

```zsh
# Terminal 1: Backend
python3 -m uvicorn voice_auth_service:app --app-dir backend --host 127.0.0.1 --port 8000

# Terminal 2: Swift App
swift build
.build/debug/Jarvis
```

---

## 📂 API Reference

### Local Python Backend Endpoints (`http://127.0.0.1:8000`)

| Endpoint | Method | Description |
|:---|:---:|:---|
| `/health` | `GET` | Backend health check |
| `/stats` | `GET` | Enrolled voice sample count |
| `/enroll` | `POST` | Store voice embedding (form field `file`) |
| `/verify` | `POST` | Speaker verification → `{ similarity, confidence }` |
| `/reset` | `POST` | Clear enrolled embeddings |
| `/spotify/login` | `GET` | Spotify OAuth login redirect |
| `/spotify/callback` | `GET` | Spotify OAuth callback |
| `/spotify/play` | `POST` | Resume/start Spotify playback |
| `/spotify/play-song` | `POST` | Play a song by name (`?name=`) |
| `/spotify/play-playlist` | `POST` | Play a playlist by name (`?name=`) |
| `/spotify/play-liked` | `POST` | Play liked songs |
| `/spotify/pause` | `POST` | Pause playback |
| `/spotify/next` | `POST` | Next track |
| `/spotify/previous` | `POST` | Previous track |

---

## 🎙️ Voice & Text Command Syntax

```text
# App Controls
Jarvis open brave browser
Jarvis close spotify

# File Operations
Jarvis create file test.txt
Jarvis create folder demo
Jarvis open folder downloads

# General AI Queries
Jarvis explain quantum computing
```

---

## 🔒 Permissions & Security

- **Microphone**: Require `NSMicrophoneUsageDescription` permission grant in macOS Settings.
- **Offline First**: Speaker verification and LLM operations run 100% locally on your Mac (Ollama + Resemblyzer). Spotify Web API requires network.
