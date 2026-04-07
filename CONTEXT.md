# Jarvis Project Context (Current State)

This file summarizes what has been implemented so far in this workspace, what features exist, and what commands Jarvis currently supports.

## 1) Project Goal

A local/offline-first macOS assistant built in Swift + SwiftUI that can:

- listen through microphone,
- process voice/text commands,
- run app/file/folder actions,
- control media (Spotify) via AppleScript,
- open URLs and perform web searches,
- answer AI queries via local Ollama,
- enforce speaker verification via local Python backend,
- log recognition/execution events to PostgreSQL.

---

## 2) Current Architecture

### macOS app (Swift Package)

- Root app: `Sources/JarvisMacOS/App/MainApp.swift`
- Core state/orchestration: `Sources/JarvisMacOS/App/AppState.swift`
- UI layout: `Sources/JarvisMacOS/App/ContentView.swift`

### Audio + speech

- Mic capture + audio level + sample export: `Sources/JarvisMacOS/Audio/MicManager.swift`
- Live speech transcription: `Sources/JarvisMacOS/Speech/SpeechRecognitionManager.swift`

### Command pipeline (v2 -- multi-action)

- **ActionPlanner** (rule-based -> Ollama fallback): `Sources/JarvisMacOS/Commands/ActionPlanner.swift`
- **ActionExecutor** (modular per-action runner): `Sources/JarvisMacOS/Commands/ActionExecutor.swift`
- **SafetyGuard** (pre-execution validation): `Sources/JarvisMacOS/Commands/SafetyGuard.swift`
- Legacy single-command parser: `Sources/JarvisMacOS/Commands/CommandParser.swift`
- Legacy single-command executor: `Sources/JarvisMacOS/Commands/CommandExecutor.swift`
- App control (open/close + aliases/fuzzy match): `Sources/JarvisMacOS/System/AppController.swift`
- File/folder actions + path safety: `Sources/JarvisMacOS/System/FileManager.swift`
- LLM normalization + AI responses: `Sources/JarvisMacOS/AI/CommandNormalizer.swift`, `Sources/JarvisMacOS/AI/OllamaClient.swift`

### UI components

- Mic orb: `Sources/JarvisMacOS/UI/MicOrbView.swift`
- Control panel sidebar: `Sources/JarvisMacOS/UI/ControlPanelView.swift`
- Transcript card: `Sources/JarvisMacOS/UI/TranscriptView.swift`
- Voice auth card: `Sources/JarvisMacOS/UI/VoiceAuthCard.swift`
- Enrollment panel: `Sources/JarvisMacOS/UI/EnrollmentView.swift`
- Event log drawer: `Sources/JarvisMacOS/UI/EventLogDrawer.swift`
- Popup overlay: `Sources/JarvisMacOS/UI/PopupView.swift`, `Sources/JarvisMacOS/UI/PopupManager.swift`
- Status badge: `Sources/JarvisMacOS/UI/StatusBadge.swift`

### Speaker authentication backend (local Python)

- Service: `backend/voice_auth_service.py`
- Requirements: `backend/requirements.txt`
- API client in app: `Sources/JarvisMacOS/VoiceAuth/VoiceAuthClient.swift`
- Embedding store: `backend/embeddings.npy`

### Database logging

- PostgreSQL manager: `Sources/JarvisMacOS/Database/DBManager.swift`
- Table auto-created: `jarvis_recognition_events`

---

## 3) Features Implemented

### A. Voice + UI

- Redesigned SwiftUI desktop app with central mic orb, sidebar controls, and collapsible log drawer.
- Mic start/stop with real-time audio level meter.
- Speech recognition integration for live/final transcripts.
- Wake-word command behavior (`Jarvis ...`) in voice mode.
- Quick-info popup overlay for time/date/month/day queries (auto-dismiss, 3s).

### B. Enrollment + speaker verification

- Phrase-based enrollment flow:
  - 7 phrases
  - each phrase repeated 3 times
  - total target: 21 speaker samples
- Each accepted repetition sends sample to backend `/enroll`.
- Voice command execution gated by speaker similarity.
- Verification threshold currently set to **0.70**.
- Enrollment/profile status shown in compact card UI.
- Backend sample count tracked via `/stats` and local restore state.

### C. Command understanding (v2 -- multi-action pipeline)

- **ActionPlanner**: rule-based intent parser splits natural language into structured multi-step plans.
  - Conjunction splitter: "Open Chrome and WhatsApp" -> 2 separate open_app actions.
  - Media parser: play/pause/next/previous via Spotify AppleScript.
  - Browser shortcuts: "Open YouTube" -> open_app + open_url.
  - Search parsing: "Search Google for X" -> open_url(google search).
  - Folder + latest-file: "Open Downloads and open latest file".
- **Ollama fallback**: only called when no rule matches (complex/unrecognised input).
- **Legacy path preserved**: single open/close/create/AI commands still route through CommandNormalizer -> CommandParser -> CommandExecutor.
- Handles prefix variants (`open`, `launch`, `start`, `run`).
- App alias resolver includes corrections for common misheard targets.
- Fuzzy app-name matching enabled with conservative distance threshold.

### D. Safety controls -- SafetyGuard

- Pre-execution validation on every action before it runs.
- Blocks destructive operations: `delete`, `remove`, `rm`, `format`, `wipe`, `erase`, `overwrite`, `shred`, `truncate`.
- Blocks protected system path access: `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/root`.
- **sudo commands permanently blocked** under all conditions.
- **Install commands blocked** with dry-run preview (future: face auth + confirmation UI).
- File manager rejects unsafe relative paths (`..`, absolute protected paths).

### E. Persistence and logging

- Enrollment completion state persisted in user defaults.
- Backend sample count persisted and synced.
- Events logged to PostgreSQL (if `PG*` env vars are configured).
- Collapsible log drawer with color-coded log lines, copy/clear, auto-scroll.

---

## 4) Commands Jarvis Can Run (Current)

### App commands

- `open <app>` / `launch <app>` / `start <app>` / `run <app>`
- `close <app>`

### Multi-app commands

- `open Chrome and WhatsApp`
- `open Chrome, VS Code, and Finder`

### Browser / URL commands

- `open YouTube` -> opens Chrome + YouTube URL
- `open YouTube in Chrome`
- `search Google for <query>` -> opens Google search
- `search YouTube for <query>`

### Media control (Spotify via AppleScript)

- `play` / `play music` / `resume`
- `pause` / `stop music`
- `next song` / `next track`
- `previous song` / `previous track`
- `play <playlist name>`

### File/folder commands

- `create file <filename>`
- `create folder <foldername>`
- `open folder <foldername>`
- `open Downloads and open latest file`

### Quick info (popup overlay)

- `what is the time` -> shows current time
- `what is today's date` -> shows full date
- `what day is it` -> shows weekday name
- `what month is it` -> shows month name

### AI query commands

- `explain <topic>`
- `what is <topic>`
- `who is <person>`
- Any non-matching text falls back to AI query via Ollama.

### Combined / multi-step commands

- `open Chrome, go to YouTube, and play lo-fi music`
- `open Spotify and play my playlist`

Examples:

- `Jarvis open chrome`
- `Jarvis open Chrome and WhatsApp`
- `Jarvis play music`
- `Jarvis next song`
- `Jarvis search Google for React tutorial`
- `Jarvis what is the time`

---

## 5) Commands/Actions Intentionally Blocked

Jarvis will reject commands involving:

- Destructive operations: delete, remove, rm, format, wipe, erase, overwrite, shred, truncate.
- Protected system locations: /System, /Library, /private, /usr, /bin, /sbin, /etc, /var, /root.
- **sudo commands** -- permanently blocked, no exceptions.
- **Install commands** (brew install, npm install, etc.) -- blocked with dry-run preview only.

This is by design for safety.

---

## 6) Backend API (Voice Auth)

Available endpoints:

- `GET /health`
- `GET /stats` -> `{ "enrolled_count": <int> }`
- `POST /enroll` (multipart `file`)
- `POST /verify` (multipart `file`) -> `{ "similarity": <0-1> }`
- `POST /reset` (manual reset of all stored embeddings)

---

## 7) Run Instructions (Current)

## App (macOS)

```zsh
cd /Users/chiteshvarun/D-drive/jarvis
./scripts/launch_jarvis_app.zsh
```

## Voice backend

```zsh
cd /Users/chiteshvarun/D-drive/jarvis/backend
source .venv/bin/activate
python -m uvicorn voice_auth_service:app --host 127.0.0.1 --port 8000
```

## Optional PostgreSQL env (for event logging)

```zsh
export PGHOST=127.0.0.1
export PGPORT=5432
export PGDATABASE=jarvis_db
export PGUSER=jarvis_user
export PGPASSWORD=your_password_if_needed
```

---

## 8) Known Current Limitations

- Recognition quality still depends on mic distance/noise conditions.
- Enrollment phrase matching can require multiple retries for noisy phrases.
- Spotify media control requires Spotify to be installed.
- Browser URL commands default to Google Chrome (configurable via alias map).
- Some doc sections in `README.md` still describe earlier MVP state and may lag behind this context file.

---

## 9) Suggested Next Upgrades

- Add explicit "Reset Voice Profile" button in UI (manual-only reset).
- Add diagnostics panel (mic/speech/backend/db/permission status in one place).
- Improve noise robustness (VAD tuning + confidence-aware phrase matcher).
- Add command confirmation mode for sensitive actions.
- Implement face-auth gated install commands.
- Add system volume control via AppleScript.
- Add calendar/reminder integration.
