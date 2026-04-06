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
