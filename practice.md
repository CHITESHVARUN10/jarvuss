# Jarvis — Practice Guide

Everything Jarvis can do, and exactly how to say it. Work through the sections
in order once, then keep this open as a cheat sheet while you talk.

---

## 1. The three ways in

| How | Do this | Best for |
|:---|:---|:---|
| **⌘⇧D** — dictate | Press, talk, pause. Text lands at your cursor. | Writing in any app: email, notes, chat, code comments |
| **⌘⇧A** — action | Press, talk, release. Jarvis executes. | One-off commands: open apps, search, play music |
| **"Jarvis …"** — wake word | Say "Jarvis" and the command together, hands-free. | When your hands are busy — cooking, presenting |

"Jarvis" is optional for ⌘⇧D and ⌘⇧A — the keypress *is* the start. In wake-word
mode you don't press anything: **"Jarvis open chrome"** in one breath, or
"Jarvis" (pause) "open chrome".

---

## 2. First run (do this once)

1. **Microphone permission** — required for everything voice. Grant it when asked.
2. **Accessibility permission** — lets dictation paste into other apps. Without
   it, Jarvis copies the text instead and tells you. (System Settings → Privacy
   & Security → Accessibility. If pasting silently stops working after a
   rebuild, remove Jarvis from the list with − and re-add it once.)
3. **Ollama running** (`ollama serve`) — powers AI answers, command fallback,
   and the dictation polish pass. Commands still work without it; answers and
   polish degrade gracefully.
4. **Voice enrollment (optional but recommended)** — Voice pane → Enroll. Repeat
   the phrases. Once enrolled and *Voice mode* is on (Assistant → Behaviour),
   the wake word works, and you can gate every command on your voiceprint.
5. **Spotify (optional)** — Connections pane → connect Spotify. Needed only for
   "play …" commands.
6. **Start at login (optional)** — Assistant → Behaviour → Start at login, so
   Jarvis is already running when you log in.

**A note on verification:** with *Speaker verification* ON (Assistant → Privacy,
the default), commands from ⌘⇧A are checked against your voiceprint — so before
you've enrolled, they get rejected. Either enroll, or turn that toggle off
while you explore. Dictation (⌘⇧D) is never blocked.

---

## 3. Command cheat sheet

Say any of these after ⌘⇧A, after "Jarvis …", or type them in the box.

### Apps

| You say | What happens |
|:---|:---|
| "open chrome" | Opens Chrome (fuzzy matching fixes "crome", "get her desktop" → **GitHub Desktop**) |
| "open terminal", "open notes", "open vscode" | Opens the app |
| "close spotify" / "quit spotify" | Quits it |
| "open spotify, open whatsapp and also open youtube" | All three, in order |

### Web & search

| You say | What happens |
|:---|:---|
| "search youtube for lofi beats" | YouTube search |
| "search google for swift concurrency" | Google search in your default browser |
| "search for python tutorials" | Same as Google — the default engine |
| "search the web for espresso machines" | Google |
| "search for iphone 18 in brave" | Google search, opened in Brave |
| "open youtube" / "open netflix" / "open github" | Opens the site directly |
| "open youtube in chrome" | Opens the site in a specific browser |

Never spell out URLs — say the site name, or "search <engine> for <thing>".

### Music & media (Spotify)

| You say | What happens |
|:---|:---|
| "play" / "pause" | Play / pause |
| "next song" / "previous track" | Transport |
| "play blinding lights on spotify" | Plays that song |
| "play playlist focus" | Plays a playlist by name |
| "play liked songs" | Plays your liked songs |
| "play some jazz" | Starts playback (no invented title) |

Spotify must be running on this Mac with an active device — if you get
"No active Spotify device", open Spotify and start one song manually once.

### Volume, brightness, display

| You say | What happens |
|:---|:---|
| "set the volume to 30 percent" | Exact level |
| "volume up" / "volume down" / "louder" / "quieter" | ±10 |
| "mute" / "unmute" | Toggles |
| "set brightness to 60" | Exact level |
| "increase the brightness by 5 percent" | Relative step |
| "dim the screen" / "brighter" | Relative step |
| "set contrast to 50" | External displays only (DDC/CI) |

### System info & questions

| You say | What happens |
|:---|:---|
| "what time is it" / "what's the date" | Instant local answer + floating panel |
| "what day is it" / "what month is it" / "what year is it" | Instant local answer |
| "battery status" / "what's my battery" | Battery read |
| "wifi status" / "bluetooth devices" | Reads |
| "what's the volume level" / "what's the brightness level" | Hardware reads, never an AI guess |
| "why is the sky blue" | Local AI answer (spoken if *Spoken replies* is on) |
| "explain recursion" | Local AI answer |

Anything that isn't a command becomes a question — Jarvis answers instead of
guessing at an action.

### Files & folders

Talking is faster than Finder for "where is that file" questions.

| You say | What happens |
|:---|:---|
| "open downloads" / "open my documents folder" | Opens it (Downloads, Documents, Desktop, Pictures, Movies, Music) |
| "how many files are there in my downloads folder" | Counts |
| "how many folders are in my documents" | Counts folders |
| "list all the files in my downloads folder" | Lists them |
| "what is the latest ppt i have" | Finds the newest .pptx |
| "what is the oldest pdf i have" | Finds the oldest .pdf |
| "how much space do my pdfs take" | Total size |
| "open the most recent pdf in downloads" | Opens the newest match |
| "create file meeting-notes.txt" | Creates a file |
| "create folder projects" | Creates a folder |

(File creation is relative to Jarvis's working folder.)

### Chained commands

Chain actions in one breath — Jarvis splits on commas, "and", "then", "also":

> "open spotify, open whatsapp and also open youtube, in spotify play a song"

- Order is preserved; each clause becomes one action (up to a handful per
  utterance).
- "open chrome and search for swift concurrency" → app + search.
- If the learned router ever truncates a long chain, the rules take over —
  mention the action verbs and Jarvis keeps all of them.

### Routines

Routines pane → create a workflow with a **keyword** (and an optional
**off-keyword**) plus actions, e.g. keyword *"focus mode"* → open Downloads,
set brightness 40. Then just say:

> "focus mode" — runs it
> "focus mode off" — runs the off-variant

---

## 4. Dictation practice (⌘⇧D)

Read these aloud; pause briefly between lines.

> **um so, basically, we should, you know, move the the standup to ten am**
> **push the release friday, no wait monday**
> **first draft the email second book the room third send the invites**

Expected:

| You said | You get |
|:---|:---|
| um so, basically, we should, you know, move the the standup to ten am | So we should move the standup to 10am. |
| push the release friday, no wait monday | Push the release Monday. |
| first draft the email second book the room third send the invites | A numbered list: 1. Draft the email 2. Book the room 3. Send the invites |

The card offers **Copy**, **Original** (raw transcript), **Undo**, **Close** —
and closes itself after 10 seconds, always.

Dictation is plain text on purpose: it types what you said, cleaned — it does
not restyle, add headings, or answer anything you happen to say.

---

## 5. What Jarvis refuses (by design)

Screened before anything runs, both for typed/voice commands and each step:

- **Privilege escalation**: sudo, su, runas.
- **Destructive operations**: delete, remove, trash, format, wipe, erase, mkfs…
- **Protected paths**: /System, /Library, /private, /usr, /bin, /sbin, /etc, /var…
- **Installs** (brew/npm/pip/cargo/pod…): preview only, never executed.

So "delete everything in downloads" is refused — deliberately.

---

## 6. Troubleshooting

| Symptom | Fix |
|:---|:---|
| ⌘⇧A does nothing | Check speaker verification — un-enrolled profiles reject commands. Enroll, or turn *Speaker verification* off in Assistant → Privacy. |
| "I can't reach the local model" | Ollama isn't running. Start it (`ollama serve`) for answers and dictation polish — commands, files, apps, volume and Spotify all keep working without it. |
| Jarvis quit by itself | It hit the memory limit (Assistant → Behaviour). The reason is in `~/Library/Application Support/Jarvis/logs/memory.log`; raise the limit or set it to Off if you need more headroom. |
| Dictation copies but doesn't paste | Accessibility grant — re-add Jarvis under Privacy & Security → Accessibility (see README). |
| "No active Spotify device" | Open Spotify and start a song once; then voice control works. |
| Answers are silent | Turn on *Spoken replies* (Assistant → Behaviour). |
| Music commands respond but nothing plays | Connections → Spotify shows connected? Reconnect if expired. |
| A dictation line says "Polishing…" for a moment | The small model is resolving a correction/list — it falls back to instant rules after 1.5 s. |
| Wake word doesn't respond | Voice mode requires a completed enrollment (Voice pane). |

---

## 7. Where everything lives

| Pane | What's there |
|:---|:---|
| **Assistant** | Speaker verification, spoken replies, voice mode, follow-up window, start at login, memory limit, recent commands |
| **Voice** | Enrollment, retrain, clear, profile status |
| **System** | Brightness/contrast, safety status, dictation settings, last dictation |
| **Routines** | Custom keyword → action workflows |
| **Connections** | Spotify, PostgreSQL |
| **Insights** | Dictation/command stats, LLM usage |
| **About** | Version, Rust-pipeline toggle |
