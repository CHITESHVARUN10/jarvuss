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
- **Manual-start listening**: nothing is captured at launch. Tap the orb — or just press ⌘⇧D / ⌘⇧A; a hotkey press is itself the manual start. Shortcut recordings use their own native capture without starting the continuous VAD/wake-word engine.
- **One-shot microphone lifecycle**: the second shortcut press ends recording and releases its microphone before transcription/polish completes. Pressing the shortcut on a result card closes it; during processing it cancels. Closing a pill cancels pending model/permission starts and discards late results. Live listening remains on only when explicitly started with the orb.
- ⌘⇧D dictation with WISPR-style formatting: deterministic rules (fillers, stutters, self-corrections, punctuation, casing, `25%`, `3pm`) plus a small-model polish pass for messy or structured speech (lists get typeset).
- **Insert at cursor**: the formatted text is pasted into whatever app you were in — your clipboard is preserved. The card offers **Copy** (formatted), **Copy original** (raw STT, toggleable), and **Undo** (⌘Z in the target app); how long it stays is user-settable — System → Dictation → *Card stays visible* (1–10 s, default 10). With no Accessibility grant it silently copies instead and tells you.
- **Last dictation is kept across restarts**: the System pane shows the latest original + polished pair — and only that pair. A new dictation immediately and unrecoverably replaces the previous one (no history by design).
- **Dictation diagnostics (dev)**: Assistant → Behaviour → *Dictation diagnostics* writes one JSONL line per dictation — raw input, rules and final text, and the timing breakdown (wall, speech, STT, rules, polish, insert) to `~/Library/Application Support/Jarvis/logs/dictation_dev.jsonl`.
- **"Jarvis" wake word**: wake-word command mode with a 0.7 s audio pre-roll so the wake word and the first syllables are never lost to VAD latency; "Jarvis" → pause → command works; continuous speech is segmented at 8 s with the tail re-armed, not dropped.
- **Display safety and rescue**: Jarvis clamps hardware brightness to at least 10%, external contrast to at least 20%, and software dimming to a nonzero floor. These guards apply to sliders, commands, and legacy combined dimming. They cannot prevent another app from blacking out a screen. With Jarvis running, **⌘⇧R** requests immediate display recovery without a microphone, model, backend, verification, or visible dialog. Alternatively press **⌘⇧A**, say **“Restore my display”** (or **“Screen rescue”**), then press **⌘⇧A** again. Only whole recovery phrases bypass verification; ⌘⇧D remains text-only. Recovery restores ColorSync gamma, requests 60% brightness and 50% external contrast on all detected displays, and asks a running BetterDisplay to remove software dimming and suspend software image adjustments. Re-enable those adjustments in BetterDisplay when ready. BetterDisplay is optional: Jarvis builds, launches, and uses native recovery without it. If BetterDisplay is absent or not running, its integration is skipped without launching it or waiting for a response. If you use BetterDisplay, its notification integration must be enabled (Settings → Application → Integration); timeouts/unsupported controls are reported rather than claimed successful. System → Display safety provides the same recovery button and shortcut status. Jarvis does not change display values automatically at launch.
- **Speaker verification (optional, per mode)**: Resemblyzer voiceprint enrollment can gate execution to your voice — independently for ⌘⇧A commands and for live mode (Assistant → Privacy). With live-mode verification off, enrollment is not required and the wake word alone is the gate. When verification is required, unavailable or rejected verification never executes the command.

**Command execution (⌘⇧A or "Jarvis …")**
- Apps: open/close with fuzzy matching and aliases ("get her desktop" → GitHub Desktop).
- Files & folders: create files/folders in `~/Documents/Jarvis`, move, and **explore** — "how many files are in my downloads folder", "what is the latest ppt I have", "open the most recent pdf in downloads", "how much space do my pdfs take" (count, folders, list, largest, oldest, newest, total size, open newest/oldest).
- Media & system: Spotify playback (play/pause/next/previous, by song, playlist, liked), volume, mute, display brightness (DDC + software), display modes.
- Spotify shuffle: “shuffle my liked songs”, “play my Gym playlist on shuffle”,
  “play a song from my light songs, shuffle it”, “shuffle it”, and “turn shuffle
  off”. Explicit “play … in order” disables shuffle for that collection.
  Named playlists start at a random position and retain their full Spotify
  context. Liked Songs uses a randomized queue of up to 50 playable tracks,
  sampled from up to five pages across the saved library (plus one count read),
  so it is not restricted to the newest 50 saves. Shuffle is confirmed on the
  target device/context before success is reported; failures after playback
  starts are reported as partial failures. Standalone shuffle mode changes do
  not start an inactive device. Uses [Spotify’s shuffle API](https://developer.spotify.com/documentation/web-api/reference/toggle-shuffle-for-users-playback).
- Web: search and open URLs.
- Chained commands: "open spotify, open whatsapp and also open youtube, in spotify play a song" — split and executed in order.
- **Routines**: reusable multi-action workflows, persisted.
- **SafetyGuard**: blocks sudo, destructive operations, protected paths, and installs before anything runs.

**The rest**
- **Setup pane (first run)**: a checklist that detects what's missing and fixes it in-app — microphone and Accessibility grants, the Whisper model plus a custom model-folder picker, Ollama (install via brew / start / pull `qwen2.5:1.5b-instruct` with download status), PostgreSQL (install, start, **create the jarvis database with an editable user + password**, configure itself, enable logging), and a Spotify API-app guide. Reopen it anytime from the rail.
- **Recording duration**: System → Dictation → *Maximum recording time* accepts 1–60 minutes (default 5). It applies to the next ⌘⇧D or ⌘⇧A recording; the floating panel shows elapsed audio time and the active limit. Capture stops and transcribes automatically at that limit, preserving the beginning and end. Long dictations bypass the optional small-model polish pass and retain the full rules-formatted transcript.
- **On-demand backend (default: Automatic)**: the Python helper that serves voice auth, Spotify and the learned intent router starts for verification, Spotify, or explicit connector/setup actions and idles out after 5 minutes. Learned routing uses it only when already running; otherwise rules/Qwen handle the command — `pgrep uvicorn` is empty on a fresh boot and torch loads only on the first voice request. Assistant → Behaviour → *Backend* offers Automatic / Always running / Off.
- **Insights**: local stats on dictation, commands, success rates, LLM usage.
- **Connections**: Spotify (OAuth via local backend) and PostgreSQL (schema-browsing status/credentials/test).
- **rail + panes shell**: Setup, Assistant, Voice, Routines, Connections, Insights, System, About.
- **Start at login**: Assistant → Behaviour — macOS opens Jarvis for you when you log in (Login Items via `SMAppService`; no helper app).
- **Memory guard**: if the app's footprint ever exceeds the limit (Assistant → Behaviour, default ~¼ of RAM), it writes the reason to `~/Library/Application Support/Jarvis/logs/memory.log` and terminates itself instead of dragging your Mac into swap.
- **Rust core (in progress)**: command understanding can route through the Rust pipeline (toggle in About), with shadow-parity logging. Safety, priority and instant information patterns share one Rust policy in both modes. Model HTTP requests use the same cancellable Swift client in both modes.

---

## Local file search and System Settings

Jarvis also searches local files through `NSMetadataQuery` (Spotlight’s index),
with a native results window. Try:

- “Open Bluetooth settings” (also Wi-Fi, sound, displays, keyboard, privacy,
  accessibility, microphone, storage, updates, and other supported panes).
- “Find the SLA stage 2 document” or “find the research folder.”
- “Find PDFs from last week in Downloads or Documents.”
- “Find presentations bigger than 20 MB inside D drive.”
- “Find the file that mentions elliptic curves.”
- With results visible: **⌘⇧A**, say **“open the second one”**, then **⌘⇧A**
  again. “Preview it”, “preview the third result”, and “reveal the first one”
  use the same list. These commands retain the normal voice-verification policy.

Results show numbered filenames, locations, sizes, and modification dates.
Select a row and press **Space** for Quick Look or **Return** to open it;
double-click also opens it. The list has a fixed order until the next search.
Closing it invalidates voice selection, and selections expire after 10 minutes.
Searches can be cancelled; requests stop gathering after eight seconds and
report partial results honestly. At most 100 numbered results are shown.

Dates mean **last modified**; “last week” uses the previous calendar week.
Type filters include PDF, legacy/current PowerPoint, Keynote, Word, spreadsheets,
images, audio, video, folders, and indexed mail/text notes. Add custom folders
or drives and their spoken aliases under **System → File search**. Standard
home folders and unambiguous home-folder/volume names resolve automatically;
unknown or ambiguous names require choosing a location instead of guessing.

Search works without the learned model or Ollama, in either routing mode.
It only sees metadata and content that macOS indexes and permits access to;
Spotlight exclusions, disconnected drives, unindexed content, and private
Mail/Apple Notes stores can prevent matches. It does not crawl those databases
or send document contents to an LLM. See [Apple’s indexing overview](https://support.apple.com/102321).

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
python prepare_data.py                      # include ALL current shards, validate, deduplicate, split
python post_train.py --harvest              # log → reward-scored training pairs
python post_train.py --train --epochs 3 --init-from out/post --output-dir out/native-search
python post_train.py --eval                 # score a checkpoint
./run_post_train.sh                         # MPS run with CPU fallback (logs to post_train.log)
python export_onnx.py --model out/native-search --dest out/native-search-onnx # stage int8 export for evaluation
python evaluate_native_search.py --candidate out/native-search-onnx
```

- The model **never grows** — same t5-small, same vocab. The loop sharpens it.
- Shards 063–065 cover browser targeting and localhost. Shards 066–069 add
  250 native search, Settings, and result-selection examples. Preparation
  includes all shards, excludes conflicting utterances, and keeps identical
  utterances out of both training and evaluation. Checkpoint/export metadata
  records source-shard SHA-256 hashes so later runs can establish coverage.
- For native commands the model classifies the command family; Swift extracts
  exact filenames, scopes, dates, sizes, and result numbers from the original
  utterance. The dataset keeps separate `resolved_args` oracles for end-to-end
  tests. This avoids delegating exact file choice and size arithmetic to a
  generative model.
- `training/eval_native_search.jsonl` is an independent evaluation set and is
  never included in training. Evaluate staged exports before replacing the
  model in `backend/models/intent-t5-small` and rebuilding the app.
- The “RL” script performs continued supervised training on reward-filtered
  execution pairs. New native search/selection labels must also match an
  authored correction; successful file opening alone is not proof of intent.
- Reward: +0.5 valid JSON plan of known intents, +0.4 matches the recorded gold
  plan, +0.1 arg-level exactness. `model_miss` → Qwen fallback cases are the
  training signal for the next round.
- Misses identify candidates for authored corrections. Failed execution is
  never automatically relabeled as a successful training example.
- Latest accepted int8 export: **16/16** native-command evaluation phrases
  correct, and **125/135** unchanged general-command evaluation phrases
  correct (previous export: **123/135**). Swift separately verifies all
  **266** authored native examples and their exact resolved fields. Model
  metadata records all 69 source shards and the training/evaluation provenance.

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
- **Whisper model** — status, active file path, auto-download, verification, and an in-app retry that resumes partial downloads. Optionally choose a model folder; the selection applies on the next launch.
- **Ollama** — Install (brew, else the download page), Start, and **Pull model** with download status.
- **PostgreSQL (optional)** — Install & start, then **Create** the `jarvis_db` database + `jarvis_user` role. A blank new-role password generates a secure password and saves it to the Keychain. If the server requires authentication, supply its existing administrator name/password in the separate administrator fields; these credentials are used only during setup. Existing Jarvis role passwords are preserved and verified before setup reports success.
- **Python helper (optional)** — Prepare installs Python 3.11 via Homebrew if needed and prepares the helper dependencies. Voice models remain lazy-loaded.
- **Spotify (optional)** — a two-step guide (create the API app with the right redirect, then paste keys in Connections).

Nothing on this checklist blocks dictation: mic + Whisper are the only requirements, and the Whisper download starts automatically at launch. PostgreSQL setup preserves existing role passwords; use the existing password or configure an existing database in Connections.

At 100% download, the model is still verified before it becomes ready. If setup fails, the Whisper detail shows the actual error and **Retry model setup** resumes the download without restarting. New installs store the model under `~/Library/Application Support/Jarvis/models`; an existing AgentTalk model or partial download is reused in place. The active path is shown in Setup.

Audio input uses the device's native format and converts it to mono 16 kHz for Whisper. Other apps can usually share the microphone; an unavailable/exclusive input, device change, or stopped audio stream produces a visible error with **Retry**. No-speech recordings also show an error instead of silently disappearing. On a fresh install, ⌘⇧A with verification enabled requires enrollment in **Voice**; dictation (⌘⇧D) does not require enrollment or Ollama.

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
no extra setup — the model downloads at launch when missing. Partial downloads survive restarts and are published only after size, header and SHA-256 verification against the [pinned upstream revision](https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin).

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

After frontend changes, refresh an existing bundle without reinstalling backend dependencies or importing settings:

```zsh
./scripts/package_jarvis_app.zsh --refresh-app --install
```

`--install` quits the running app, updates `/Applications/Jarvis.app`, verifies its binary ID/signature, and opens that copy. Omit it to refresh only `.build/Jarvis.app`. `swift build` alone updates the development executable, leaving both app bundles unchanged. About shows the source revision and binary ID so you can verify which build is running.

Saved connection credentials stay encrypted in macOS Keychain. The signed Jarvis app handles Keychain access; its Python helper uses a private, authenticated local connection and cached values. Spotify requests do not read PostgreSQL credentials, and saved Setup edits invalidate the cache. Existing entries may ask you to authorize **Jarvis** during the first migration; choose **Always Allow** for a build you trust. Locked Keychains or a changed signing identity can still require authorization. Refreshing an app updates the Swift and Python code without reinstalling backend dependencies.

Crash diagnostics are enabled automatically. **About → Diagnostics** opens `~/Library/Application Support/Jarvis/logs/diagnostics` or copies a summary with the running binary ID and latest crash signature. Each session keeps `session.json`, durable `events.jsonl`, and `runtime.log` (Swift/Objective-C/Rust process output). On relaunch, Jarvis detects an unclean previous exit and copies available macOS `.ips` reports into `crashes/`; delayed reports are collected on subsequent checks. A forced kill can leave an unclean session without an Apple report. Recent sessions and reports are retained locally; runtime output rotates at 8 MB. Logs can include dictated text and commands, so review them before sharing.

During development:

```zsh
./scripts/build_stt.sh --release     # after Rust stt-core changes
./scripts/build_rust_core.sh --release
swift build && swift run             # dev run; the window opens behind your terminal
```

Manual backend + app:

```zsh
python3 -m uvicorn voice_auth_service:app --app-dir backend --host 127.0.0.1 --port 8000 --workers 1
swift run
```

### Sharing the app with a friend (no Apple Developer account)

The packaged bundle is self-contained (app, Whisper STT core, intent model,
backend) and signed with your development certificate — it is **not**
notarized, which costs $99/year. That only affects the *first launch*: macOS
quarantines the zip and shows "unidentified developer". The friend does this
once:

```zsh
# you
ditto -c -k --sequesterRsrc --keepParent /Applications/Jarvis.app ~/Desktop/Jarvis.zip

# your friend (after moving Jarvis.app to /Applications)
xattr -dr com.apple.quarantine /Applications/Jarvis.app
```

(Or: right-click the app → **Open** → **Open** again.)

On their first launch, Jarvis opens on **Setup**, which handles the rest:
microphone + Accessibility grants, the Whisper model download (~1.5 GB), Ollama
(install / start / pull the model), PostgreSQL (install, start, create the
database with an editable user + password), and a Python-helper *Prepare* that
installs Python 3.11 when missing and builds the backend venv. Without Homebrew
the one-click installs fall back to the vendor download pages, and dictation
still works as soon as the mic and Whisper are ready.

Their data (settings, Keychain secrets, logs, models) lives in **their**
`~/Library/Application Support/Jarvis` — nothing personal is inside the bundle.

### Updating Jarvis (delete the old app, unzip the new one)

Updates are safe by design: **nothing that matters lives inside the app
bundle.** Replace the app and the friend's setup carries over:

| What | Where it lives | Survives an update |
|:---|:---|:---|
| Postgres database + credentials | The database itself; `connection_settings.json` + Keychain | Yes |
| Whisper model | `~/Library/Application Support/Jarvis/models`, an existing AgentTalk model, or the folder picked in Setup | Yes |
| Ollama + qwen model | `~/.ollama/models` | Yes |
| Voice enrollment | `Application Support/Jarvis/embeddings.npy` + prefs | Yes |
| Settings (toggles, backend mode, follow-up window, setup state) | `~/Library/Preferences/local.jarvis.macos.plist` | Yes (same bundle id) |
| Microphone + Accessibility grants | macOS TCC, keyed to the signing identity | Yes — **sign every build with the same certificate**; an ad-hoc or different-cert build breaks the grants |
| Spotify tokens / PG password | Keychain (`local.jarvis.credentials`) | Yes (same signing identity) |
| Learned intent model, STT core, app code | Inside the bundle | Replaced by the new build |

The steps:

```zsh
# you: build, sign, zip
./scripts/package_jarvis_app.zsh
ditto -c -k --sequesterRsrc --keepParent /Applications/Jarvis.app ~/Desktop/Jarvis.zip

# friend: quit first (quitting also stops the Python helper), then swap
#   ⌘Q in Jarvis → drag the new Jarvis.app over the old one in /Applications
#   right-click → Open once (quarantine applies to every fresh download)
```

Do **not** delete `~/Library/Application Support/Jarvis` — that is where the
friend's configuration, enrollment, logs and stats live. If the backend ever
reports a stale helper, quitting Jarvis also stops it; the new version starts
its own.

After an update the Setup pane still shows every optional item as configured
(Postgres connection prefilled, password left blank so an existing role is
never altered; "Create" is safe to re-run as a verification).

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

Requests require `X-Jarvis-Token`, read from the private
`~/Library/Application Support/Jarvis/backend_auth.token` file (or `JARVIS_DATA_DIR`).
The token rotates at each backend startup; app clients read it automatically.
Run one backend worker. OAuth browser callbacks use expiring, single-use `state`
instead of the header. `/spotify/token` reports presence/expiry, never token bytes.
This protects API access from other OS users and unauthenticated browser requests;
it does not isolate the app from processes that can read files as the same user.

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

### Continuous integration

[GitHub Actions](.github/workflows/tests.yml) builds both native bridges and runs
Swift, Rust, Python, and disposable PostgreSQL regression tests on macOS 26.
Live microphone, hardware-control, and Keychain integration checks remain opt-in.
