# Jarvis

A local-first macOS assistant: talk to it, and it types, opens, searches, plays,
controls, and answers — with the speech model, the language models, and the
intent router all running on your Mac.

Requires **macOS 26.0 or later**. For the local speech and language models,
16 GB RAM or more is recommended; 24 GB gives more room for other apps.

Three ways in:

| Shortcut / phrase | What it does |
|:---|:---|
| **⌘⇧D** — dictate | Voice → text at your cursor, in any app. Fillers cleaned, self-corrections resolved, punctuation fixed. |
| **⌘⇧A** — action | Push-to-talk command execution ("open chrome, play lofi on spotify"). |
| **"Jarvis …"** — wake word | Hands-free: say the wake word and the command in the same breath. |

Full walkthrough with every command and exact phrasings: **[practice.md](practice.md)**.

---

## What it can do today

**Voice & dictation**
- **Manual-start listening**: nothing is captured at launch. Tap the orb — or just press ⌘⇧D / ⌘⇧A; a hotkey press is itself the manual start — and only then does the mic pipeline (VAD, wake word, dictation) come up.
- **One-shot microphone lifecycle**: the second shortcut press ends recording and releases its microphone before transcription/polish completes. Pressing the shortcut on a result card closes it; during processing it cancels. Closing a pill cancels pending model/permission starts and discards late results. Live listening remains on only when explicitly started with the orb.
- ⌘⇧D dictation with WISPR-style formatting: deterministic rules (fillers, stutters, self-corrections, punctuation, casing, `25%`, `3pm`) plus a small-model polish pass for messy or structured speech (lists get typeset).
- **Insert at cursor**: the formatted text is pasted into whatever app you were in — your clipboard is preserved. The card offers **Copy** (formatted), **Copy original** (raw STT, toggleable), and **Undo** (⌘Z in the target app); how long it stays is user-settable — System → Dictation → *Card stays visible* (1–10 s, default 10). With no Accessibility grant it silently copies instead and tells you.
- **Last dictation is kept across restarts**: the System pane shows the latest original + polished pair — and only that pair. A new dictation immediately and unrecoverably replaces the previous one (no history by design).
- **Dictation diagnostics (dev)**: Assistant → Behaviour → *Dictation diagnostics* writes one JSONL line per dictation — raw input, rules and final text, and the timing breakdown (wall, speech, STT, rules, polish, insert) to `~/Library/Application Support/Jarvis/logs/dictation_dev.jsonl`.
- **"Jarvis" wake word**: wake-word command mode with a 0.7 s audio pre-roll so the wake word and the first syllables are never lost to VAD latency; "Jarvis" → pause → command works; continuous speech is segmented at 8 s with the tail re-armed, not dropped.
- **Speaker verification (optional, per mode)**: Resemblyzer voiceprint enrollment can gate execution to your voice — independently for ⌘⇧A commands and for live mode (Assistant → Privacy). With live-mode verification off, the wake word alone is the gate.

**Command execution (⌘⇧A or "Jarvis …")**
- Apps: open/close with fuzzy matching and aliases ("get her desktop" → GitHub Desktop).
- Files & folders: create, move, and **explore** — "how many files are in my downloads folder", "what is the latest ppt I have", "open the most recent pdf in downloads", "how much space do my pdfs take" (count, folders, list, largest, oldest, newest, total size, open newest/oldest).
- Media & system: Spotify playback (play/pause/next/previous, by song, playlist, liked), volume, mute, display brightness (DDC + software), display modes.
- Web: search and open URLs.
- Chained commands: "open spotify, open whatsapp and also open youtube, in spotify play a song" — split and executed in order.
- **Routines**: reusable multi-action workflows, persisted.
- **SafetyGuard**: blocks sudo, destructive operations, protected paths, and installs before anything runs.

**The rest**
- **Setup pane (first run)**: a checklist that detects what's missing and fixes it in-app — microphone and Accessibility grants, the Whisper model plus a custom model-folder picker, Ollama (install via brew / start / pull `qwen2.5:1.5b-instruct` with download status), PostgreSQL (install, start, **create the jarvis database with an editable user + password**, configure itself, enable logging), and a Spotify API-app guide. Reopen it anytime from the rail.
- **On-demand backend (default: Automatic)**: the Python helper that serves voice auth, Spotify and the learned intent router starts only when a feature needs it and idles out after 5 minutes — `pgrep uvicorn` is empty on a fresh boot and torch loads only on the first voice request. Assistant → Behaviour → *Backend* offers Automatic / Always running / Off.
- **Insights**: local stats on dictation, commands, success rates, LLM usage.
- **Connections**: Spotify (OAuth via local backend) and PostgreSQL (schema-browsing status/credentials/test).
- **rail + panes shell**: Setup, Assistant, Voice, Routines, Connections, Insights, System, About.
- **Start at login**: Assistant → Behaviour — macOS opens Jarvis for you when you log in (Login Items via `SMAppService`; no helper app).
- **Memory guard**: if the app's footprint ever exceeds the limit (Assistant → Behaviour, default ~¼ of RAM), it writes the reason to `~/Library/Application Support/Jarvis/logs/memory.log` and terminates itself instead of dragging your Mac into swap.
- **Rust core (in progress)**: command understanding can route through the Rust pipeline (toggle in About), with shadow-parity logging. Safety, priority and instant information patterns share one Rust policy in both modes. Model HTTP requests use the same cancellable Swift client in both modes.

---

## The intent model, and the loop that keeps training it

Commands are routed by a **compact learned router: t5-small, ~60M parameters**
(0.06B — small on purpose: it must run locally in milliseconds). It is exported
as int8 ONNX (~196 MB) and served by the local backend at `/parse_intent`.
The app handles unambiguous single commands locally first, then asks the model
to resolve ambiguous or compound commands.

It does not stay frozen. Every routing decision the app makes is appended to:

```
~/Library/Application Support/Jarvis/logs/intent_router.jsonl
```

That log supplies candidate training labels. `training/post_train.py` harvests
only complete, explicitly successful runs with successful steps and the matching
final plan. Failed, cancelled, and incomplete runs are excluded. Execution
success is a proxy, not human confirmation of the interpretation; retain
independent evaluations and human corrections.

```zsh
cd training
python post_train.py --harvest              # log → reward-scored training pairs
python post_train.py --train --epochs 3     # continue-train the SAME checkpoint
python post_train.py --eval                 # score a checkpoint
./run_post_train.sh                         # MPS run with CPU fallback (logs to post_train.log)
python export_onnx.py                       # re-export int8 ONNX → backend/models
```

- The model **never grows** — same t5-small, same vocab. The loop sharpens it.
- Reward: +0.5 valid JSON plan of known intents, +0.4 matches the recorded gold
  plan, +0.1 arg-level exactness. `model_miss` → Qwen fallback cases are the
  training signal for the next round.
- Failure harvests are also added as corrected pairs — e.g. a 4-clause chain the
  model truncated, or an extension the FileExplorer did not recognize — so each
  round fixes what the last round exposed. Run it after busy weeks and repeat.
- Latest run: 3 epochs on ~8.3k examples (MPS), eval reward 0.9952, and 33/35
  exact match on a held-out set of unseen phrasings.

The general-purpose planner behind it is local Ollama
(`qwen2.5:1.5b-instruct`). Why instruct and not a base model? Every caller —
the planner, the normalizer, the polish pass — asks the model to **obey**
("convert this to that JSON", "clean this up, change nothing else"). A base
model isn't tuned for instruction-following; it continues text in the style of
its corpus (prose around the JSON, dropped fields), while an instruct model was
post-trained on instruction→answer pairs and treats the prompt as a command.
One 1.5B instruct model now serves the whole app, so only one model sits
resident in memory instead of two.

---

## Try the dictation formatting (the read-aloud test)

Press **⌘⇧D**, read one line, and pause ~1.5 s before the next. Each line lands
at your cursor when you pause; lines 4 and 5 show "Polishing…" (they take the
model pass), the rest are instant.

> **um so, basically, we should, you know, move the the standup to ten am**
>
> **push the release friday, no wait monday**
>
> **i, actually, like the slower version and the new theme is twenty five percent faster**
>
> **also meet thursday no wait friday to review it**
>
> **first draft the email second book the room third send the invites**

What good looks like:

| You said | You should get |
|:---|:---|
| um so, basically, we should, you know, move the the standup to ten am | `So we should move the standup to 10am.` |
| push the release friday, no wait monday | `Push the release Monday.` |
| i, actually, like the slower version and the new theme is twenty five percent faster | `I like the slower version and the new theme is 25% faster.` |
| also meet thursday no wait friday to review it | `Also meet Friday to review it.` — the correction is resolved by the polish pass |
| first draft the email second book the room third send the invites | A numbered/bulleted list of the three items |

(These exact examples are locked as unit tests — `TranscriptFormatterTests` —
so the docs cannot drift from the behavior.)

Notes:
- The card offers **Copy** (what lands), **Original** (raw text, settings-toggled), **Undo** after a paste, and **Close** — and it auto-closes after **10 s** in every path, so it can never linger on screen.
- Dictation settings live in **System → Dictation**: *Auto-paste at cursor* (default on) and *Copy original* (default on). The same pane shows the **last dictation pair** — original + polished — kept across app restarts; only the latest is ever stored.
- Line 2 needs a small **pause after "Friday"** — that is the comma the
  correction rules key on. Without it, the polish pass resolves it from context
  instead (slightly slower, same result).
- "like" is the formatter's hard case: it survives as a verb (`I like it.`) and
  as a noun, and is only dropped when comma-delimited ("so, like, go") — never
  when it carries meaning.
- Short checks: `i like it` → `I like it.` · `um open chrome please` →
  `Open Chrome please.` (Chrome is a known proper noun) · `the the dog` →
  `The dog.`
- The LLM pass is strictly guarded: if it drifts (rewrites rather than cleans,
  answers instead of formatting), the deterministic rules output is used
  instead and the rejection is logged to
  `~/Library/Application Support/Jarvis/logs/dictation_polish.jsonl`.

For command types instead of dictation, press **⌘⇧A** and say things like
"how many files are in my downloads folder", "open spotify and play a song",
or say "Jarvis, open chrome" hands-free.

---

## 🛠️ Installation & Setup

### First run: the Setup pane

On first launch the app opens on **Setup** — a checklist with inline fixes, so
the manual steps below become optional:

- **Microphone / Accessibility** — grant buttons, right there.
- **Whisper model** — status + auto-download; optionally point it at a folder that already has `ggml-large-v3-turbo.bin`.
- **Ollama** — Install (brew, else the download page), Start, and **Pull model** with download status.
- **PostgreSQL (optional)** — Install & start, then **Create** the `jarvis_db` database + `jarvis_user` role (defaults prefilled, fully editable; the generated password is saved to the Keychain and event logging turns on).
- **Python helper (optional)** — Prepare installs Python 3.11 via Homebrew if needed and prepares the helper dependencies. Voice models remain lazy-loaded.
- **Spotify (optional)** — a two-step guide (create the API app with the right redirect, then paste keys in Connections).

Nothing on this checklist blocks dictation: mic + Whisper are the only requirements, and the Whisper download starts automatically at launch. PostgreSQL setup preserves existing role passwords; use the existing password or configure an existing database in Connections.

### 1) Prerequisites (macOS)

macOS **26.0+**, with Xcode and a matching macOS SDK installed. Swift, Rust,
and the native speech dependencies all use a 26.0 deployment target.

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake ffmpeg portaudio ollama postgresql@18 rust
```

### 2) Local models

```zsh
ollama pull qwen2.5:1.5b-instruct     # one model serves planner, answers, and the polish pass
ollama serve
```

Speech is offline Whisper (`large-v3-turbo`, via the Rust `stt-core`) and needs
no extra setup — the model downloads on first use.

### 3) Python backend

The packaging script creates and maintains the venv for you. Manually:

```zsh
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

---

## 🖥️ Launching Jarvis

Build + package + launch (this is the path that has the mic usage descriptions
and the backend bundled — prefer it):

```zsh
./scripts/package_jarvis_app.zsh     # builds Rust cores + app, bundles backend, signs, opens
```

During development:

```zsh
./scripts/build_stt.sh --release     # after Rust stt-core changes
./scripts/build_rust_core.sh --release
swift build && swift run             # dev run; the window opens behind your terminal
```

Manual backend + app:

```zsh
python3 -m uvicorn voice_auth_service:app --app-dir backend --host 127.0.0.1 --port 8000
swift run
```

### Start at login

Toggle **Assistant → Behaviour → Start at login** and macOS opens Jarvis for you when you log in. Enable it from the packaged app (`./scripts/package_jarvis_app.zsh`) — a bare `swift run` binary has no bundle identity to register. If macOS wants approval first, the same card shows an **Open Settings** row that lands in System Settings → General → Login Items.

### Permissions — read this once

- **Microphone** is required for everything voice-related. Grant it and restart.
- **Accessibility** is what lets Jarvis paste dictated text into other apps
  (`Privacy & Security → Accessibility → Jarvis`).

The Accessibility grant is matched to the app's **signature**. The packaging
script signs with your Apple Development identity when one exists — then the
grant survives rebuilds. If the app was ever signed ad-hoc (or you switch
machines), the toggle can show ON while the grant actually belongs to an older
build: if dictation reports "Auto-paste blocked" or pastes nothing, remove
Jarvis from that list with **−** and re-add it — once. The app logs
`[AX] Auto-paste permission: …` at every mic start so this is never a mystery.

---

## 🎙️ Command syntax

New here? **[practice.md](practice.md)** is the hands-on tutorial — every capability with exact phrasings. The short version:

```text
# Apps
Jarvis open brave browser
Jarvis close spotify

# Files
Jarvis create file test.txt
Jarvis create folder demo
Jarvis how many files are in my downloads folder
Jarvis what is the latest ppt I have
Jarvis open the most recent pdf in downloads

# Media / system
Jarvis play lofi beats on spotify
Jarvis set the volume to forty percent
Jarvis dim the screen

# Questions
Jarvis explain quantum computing
```

---

## 📂 Local backend endpoints (`http://127.0.0.1:8000`)

| Endpoint | Method | Description |
|:---|:---:|:---|
| `/health` | `GET` | Backend health check |
| `/stats` | `GET` | Enrolled voice sample count |
| `/enroll` | `POST` | Store voice embedding (form field `file`) |
| `/verify` | `POST` | Speaker verification → `{ similarity, confidence }` |
| `/reset` | `POST` | Clear enrolled embeddings |
| `/parse_intent` | `POST` | Learned intent router (t5-small int8 ONNX) → JSON plan |
| `/spotify/login`, `/spotify/callback` | `GET` | Spotify OAuth |
| `/spotify/status`, `/spotify/connect-url`, `/spotify/token` | `GET` | Connection state |
| `/spotify/play`, `/pause`, `/next`, `/previous` | `POST` | Transport |
| `/spotify/play-song`, `/play-playlist`, `/play-liked` | `POST` | Play by name / liked songs |
| `/postgres/status`, `/postgres/credentials`, `/postgres/test` | mixed | PostgreSQL connection management |

---

## 🔒 Security & privacy

- Speech (Whisper), the intent router, the planner LLM, and speaker verification
  all run **locally**. Only Spotify's Web API needs the network.
- **SafetyGuard** screens every plan pre-execution and each action: sudo and
  destructive operations, protected paths (system dirs), and install commands
  are blocked or previewed, never run.
- Stats and command history are stored locally (SQLite/PostgreSQL if you
  connect it); away from a database, nothing leaves the machine.
- Saved connection secrets use macOS **Keychain**. Non-secret settings,
  voice embeddings, and the statistics outbox live in
  `~/Library/Application Support/Jarvis` (or `JARVIS_DATA_DIR`). Runtime updates
  never modify the signed app bundle. Existing `.env` files are read as literal
  data and migrated; saved connection edits take precedence.
- Usage uploads retain immutable batch IDs until PostgreSQL acknowledges them,
  so an outage or a retry does not lose or double-count usage. Local events are
  batched for up to one second and persisted immediately on shutdown.

## Development checks

```zsh
swift test                              # real system actions are opt-in
cargo test --locked --manifest-path rust-core/Cargo.toml
zsh scripts/test_stt.zsh                 # no microphone/model required
python3 -m venv /tmp/jarvis-tests
/tmp/jarvis-tests/bin/pip install -r backend/requirements-test.txt
/tmp/jarvis-tests/bin/python -B -m unittest discover -s backend/tests -v
python3 scripts/test_postgres.py         # disposable DB; never uses your database
```

`JARVIS_RUN_SYSTEM_TESTS=1 swift test --filter SystemPipelineE2ETests` runs the
separate harness that opens/closes real apps and controls Spotify. See
[docs/architecture.md](docs/architecture.md) for policy ownership and lifecycle rules.
