# Jarvis

A local-first macOS assistant: talk to it, and it types, opens, searches, plays,
controls, and answers — with the speech model, the language models, and the
intent router all running on your Mac.

Three ways in:

| Shortcut / phrase | What it does |
|:---|:---|
| **⌘⇧D** — dictate | Voice → text at your cursor, in any app. Fillers cleaned, self-corrections resolved, punctuation fixed. |
| **⌘⇧A** — action | Push-to-talk command execution ("open chrome, play lofi on spotify"). |
| **"Jarvis …"** — wake word | Hands-free: say the wake word and the command in the same breath. |

---

## What it can do today

**Voice & dictation**
- **Manual-start listening**: nothing is captured at launch. Tap the orb — or just press ⌘⇧D / ⌘⇧A; a hotkey press is itself the manual start — and only then does the mic pipeline (VAD, wake word, dictation) come up.
- ⌘⇧D dictation with WISPR-style formatting: deterministic rules (fillers, stutters, self-corrections, punctuation, casing, `25%`, `3pm`) plus a small-model polish pass for messy or structured speech (lists get typeset).
- **Insert at cursor**: the formatted text is pasted into whatever app you were in — your clipboard is preserved. The card offers **Copy** (formatted), **Copy original** (raw STT, toggleable), and **Undo** (⌘Z in the target app), and it closes itself after 10 seconds no matter what. With no Accessibility grant it silently copies instead and tells you.
- **Last dictation is kept across restarts**: the System pane shows the latest original + polished pair — and only that pair. A new dictation immediately and unrecoverably replaces the previous one (no history by design).
- **"Jarvis" wake word**: wake-word command mode with a 0.7 s audio pre-roll so the wake word and the first syllables are never lost to VAD latency; "Jarvis" → pause → command works; continuous speech is segmented at 8 s with the tail re-armed, not dropped.
- **Speaker verification (optional)**: Resemblyzer voiceprint enrollment can gate execution to your voice.

**Command execution (⌘⇧A or "Jarvis …")**
- Apps: open/close with fuzzy matching and aliases ("get her desktop" → GitHub Desktop).
- Files & folders: create, move, and **explore** — "how many files are in my downloads folder", "what is the latest ppt I have", "open the most recent pdf in downloads", "how much space do my pdfs take" (count, folders, list, largest, oldest, newest, total size, open newest/oldest).
- Media & system: Spotify playback (play/pause/next/previous, by song, playlist, liked), volume, mute, display brightness (DDC + software), display modes.
- Web: search and open URLs.
- Chained commands: "open spotify, open whatsapp and also open youtube, in spotify play a song" — split and executed in order.
- **Routines**: reusable multi-action workflows, persisted.
- **SafetyGuard**: blocks sudo, destructive operations, protected paths, and installs before anything runs.

**The rest**
- **Insights**: local stats on dictation, commands, success rates, LLM usage.
- **Connections**: Spotify (OAuth via local backend) and PostgreSQL (schema-browsing status/credentials/test).
- **rail + panes shell**: Assistant, Voice, Routines, Connections, Insights, System, About.
- **Rust core (in progress)**: command understanding can route through the Rust pipeline (toggle in About), with shadow-parity logging.

---

## The intent model, and the loop that keeps training it

Commands are routed by a **compact learned router: t5-small, ~60M parameters**
(0.06B — small on purpose: it must run locally in milliseconds). It is exported
as int8 ONNX (~196 MB) and served by the local backend at `/parse_intent`,
where rules are tried first and the model handles the rest.

It does not stay frozen. Every routing decision the app makes is appended to:

```
~/Library/Application Support/Jarvis/logs/intent_router.jsonl
```

That log is the reward signal, and `training/post_train.py` closes the loop:

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

### 1) Prerequisites (macOS)

```zsh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cmake ffmpeg portaudio ollama postgresql@18 rust
```

### 2) Local models

```zsh
ollama pull qwen2.5-coder:1.5b-base   # planner / answers
ollama pull qwen2.5:1.5b-instruct     # dictation polish pass
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
Jarvis dim the display

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
