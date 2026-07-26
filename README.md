# JarvisMacOS (Phase 1 MVP Scaffold)

Offline-first macOS assistant scaffold in Swift with:

- Wake-word style command entry (`Jarvis ...`) in CLI
- Live microphone capture via `AVAudioEngine` (Step 1)
- Rule-based command parsing and system actions
- Local Ollama integration using `mistral:7b`
- Command logging to `logs/commands.log`

## 1) Install Dependencies (macOS)

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake
brew install ffmpeg
brew install portaudio
brew install ollama
brew install postgresql@18
```

## 2) Pull and Start LLM

```zsh
ollama pull mistral:7b
ollama run mistral:7b
```

Keep Ollama running in one terminal.

## PostgreSQL (Recognition Storage)

Jarvis now stores recognition/enrollment/command events in PostgreSQL if environment variables are set.

Start PostgreSQL:

```zsh
brew services start postgresql@18
```

Create user/database (example):

```zsh
createuser -s jarvis_user
createdb jarvis_db -O jarvis_user
```

Set connection variables before launching app:

```zsh
export PGHOST=127.0.0.1
export PGPORT=5432
export PGDATABASE=jarvis_db
export PGUSER=jarvis_user
export PGPASSWORD=your_password_if_needed
```

On launch, Jarvis auto-creates table `jarvis_recognition_events`.

## Microphone Permission (Important)

On first run, macOS may require microphone permission for your terminal app.

- If needed, enable it in:
  - `System Settings` → `Privacy & Security` → `Microphone`
  - Turn on access for your terminal (`Terminal`, `iTerm`, etc.)

## 3) Build and Run Jarvis

```zsh
cd /Users/chiteshvarun/D-drive/jarvis
swift build
./scripts/launch_jarvis_app.zsh
```

## 4) Speaker Authentication Backend (Offline)

Run this local Python service (Resemblyzer + FastAPI):

```zsh
cd /Users/chiteshvarun/D-drive/jarvis/backend
/opt/homebrew/bin/python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m uvicorn voice_auth_service:app --host 127.0.0.1 --port 8000
```

Speaker profile training now uses the existing phrase enrollment flow:

- Start enrollment in app UI
- Speak each of the 7 phrases, 3 times each
- Jarvis stores each accepted repetition as a backend voice sample
- Voice mode unlocks after all 21 samples are collected

## 5) Try Commands

```text
Jarvis open chrome
Jarvis close vscode
Jarvis create file test.txt
Jarvis create folder demo
Jarvis open folder downloads
Jarvis explain recursion
```

Type `help` for examples or `quit` to exit.

## Current Scope

This is a runnable MVP scaffold for milestone progression:

- ✅ Wake-word-gated flow (text mode)
- ✅ Mic input capture with `AVAudioEngine`
- ✅ Command parser + executor
- ✅ Ollama API call to local model
- ✅ Logging
- ⏳ Porcupine, Whisper.cpp, and SQLite remain placeholders for next implementation steps.
# jarvuss

## Bundled macOS App (No Terminal)

Jarvis now supports a fully bundled app flow where backend startup is automatic.

### Target bundle layout

```text
Jarvis.app/
 ├── Contents/
 │   ├── MacOS/
 │   │   ├── Jarvis
 │   │   └── start_backend.sh
 │   ├── Resources/
 │   │   └── backend/
 │   │       ├── main (optional PyInstaller onefile binary)
 │   │       ├── main.py
 │   │       ├── voice_auth_service.py
 │   │       ├── venv/
 │   │       └── requirements.txt
 │   └── Info.plist
```

### One-command local packaging

```zsh
cd /Users/chiteshvarun/D-drive/jarvis
chmod +x scripts/start_backend.sh scripts/package_jarvis_app.zsh scripts/launch_jarvis_app.zsh
./scripts/launch_jarvis_app.zsh
```

Optional backend compilation with PyInstaller:

```zsh
cd /Users/chiteshvarun/D-drive/jarvis
JARVIS_USE_PYINSTALLER=1 ./scripts/package_jarvis_app.zsh
```

### Swift backend lifecycle integration

- `AppState.bootstrap()` now starts bundled backend first.
- Uses `BackendServiceManager` (`Sources/JarvisMacOS/App/BackendServiceManager.swift`) with:
  - single-instance startup
  - health check (`/health`)
  - one retry on startup failure
  - clean shutdown via PID file on app termination
- UI status is visible in top bar via `backendStatus` and `backendStartupError`.

### Permissions

`Info.plist` includes:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `NSAppleEventsUsageDescription`

For stable permission persistence across launches:

- keep a stable `CFBundleIdentifier`
- sign the app consistently (same signing identity/team)

Accessibility/Automation grants are managed by macOS TCC and become persistent for the signed bundle identity.

### Xcode build phases (recommended)

In your app target, set up:

1. **Run Script: Copy backend resources**
  - Copy `backend/voice_auth_service.py`, `backend/requirements.txt`, optional `backend/embeddings.npy` to:
  - `$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/backend/`

2. **Run Script: Backend startup script**
  - Copy `scripts/start_backend.sh` to:
  - `$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/MacOS/start_backend.sh`
  - `chmod +x` it.

3. **Run Script: Prepare venv (optional in build)**
  - Create venv under `Resources/backend/venv` and install from `requirements.txt`.
  - Or let `start_backend.sh` perform first-run install automatically.

4. **Info.plist**
  - Ensure required usage descriptions are present as above.

### Runtime behavior (double-click app)

1. Launch `Jarvis.app`.
2. Swift app starts backend via `start_backend.sh` automatically.
3. Backend runs in background (`127.0.0.1:8000`).
4. App retries startup once if health check fails.
5. On app close, backend PID is terminated cleanly.
