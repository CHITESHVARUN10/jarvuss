# Jarvis — Practice Guide

A practical guide to the capabilities in the current source code. Rebuild your
installed app after pulling changes. Start with the examples below, then keep
this open as a command reference. Device controls depend on the selected
hardware; Spotify needs a connection, and AI answers need Ollama.

---

## 1. The three ways in

| How | Do this | Best for |
|:---|:---|:---|
| **⌘⇧D** — dictate | Press once, speak, press again to finish. Text lands at your cursor. | Writing in any app: email, notes, chat, code comments |
| **⌘⇧A** — action | Press once, speak, press again to finish. Jarvis executes. | One-off commands: open apps, search, play music |
| **"Jarvis …"** — wake word | Say "Jarvis" and the command together, hands-free. | When your hands are busy — cooking, presenting |

"Jarvis" is optional for ⌘⇧D and ⌘⇧A — the keypress *is* the start. In wake-word
mode you don't press anything: **"Jarvis open chrome"** in one breath, or
"Jarvis" (pause) "open chrome". Start live listening with the orb first;
Jarvis does not listen automatically at launch. Enrollment is needed only when
verification is enabled for that mode.

For a first command, type **“what time is it”** in Assistant. Then try
**“open notes”**. For dictation, put the cursor in a text editor, press **⌘⇧D**,
say **“Hello, this is a dictation test”**, and press **⌘⇧D** again. That produces
text; it does not run the words as a command.

---

## 2. First run (do this once)

1. **Speech model** — complete the Whisper download in Setup. It is required
   for speech recognition; typed commands do not need it.
2. **Microphone permission** — required for everything voice. Grant it when asked.
3. **Accessibility permission** — lets dictation paste into other apps. Without
   it, Jarvis copies the text instead and tells you. (System Settings → Privacy
   & Security → Accessibility. If pasting silently stops working after a
   rebuild, remove Jarvis from the list with − and re-add it once.)
4. **Ollama running (optional for native commands)** (`ollama serve`) — powers AI answers, command fallback,
   and the dictation polish pass. Commands still work without it; answers and
   polish degrade gracefully.
5. **Voice enrollment (when verification is enabled)** — Voice pane → Enroll. Repeat
   the displayed phrases to build a profile. Enrollment creates the profile;
   verification compares a later recording against it. Live listening and
   verification have separate controls; live mode can use the wake word
   without enrollment when verification for that mode is off.
6. **Spotify (optional)** — Connections pane → connect Spotify. Needed only for
   "play …" commands.
7. **Start at login (optional)** — Assistant → Behaviour → Start at login, so
   Jarvis is already running when you log in.
8. **Intent command model (optional)** — Setup → Intent command model. If no
   model is installed or bundled, Jarvis downloads the public runtime release
   automatically (approximately 206 MB). The refresh icon checks for newer
   versions; **Update intent model** installs one after verification. This is
   separate from Whisper and Ollama, needs no Hugging Face account, and keeps
   the working model if an update fails. Native commands and dictation remain
   available without it.

**A note on verification:** with *Verify action commands* ON (Assistant
preferences → Privacy, the default), commands from ⌘⇧A are checked against your
voiceprint — so before you've enrolled, they get rejected. Either enroll, or turn that toggle off
while you explore. Dictation (⌘⇧D) does not require speaker enrollment.
PostgreSQL is optional for database/logging features, not a prerequisite for
native commands, volume controls, or dictation.

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
| "open chatgpt in brave" | Opens ChatGPT in Brave |
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
| "shuffle my liked songs" | Starts a randomized Liked Songs queue |
| "play my Focus playlist on shuffle" | Starts the named playlist at a random position with shuffle on |
| "play a song from my light songs shuffle it" | Handles “light songs” as a speech-recognition variant of Liked Songs |
| "shuffle it" / "turn shuffle off" | Sets shuffle on/off for the active playback device |
| "play my Focus playlist in order" | Starts that collection with shuffle off |
| "play some jazz" | Starts playback (no invented title) |

Use one of your own playlist names instead of “Focus”. Liked Songs shuffle
samples across the library and queues up to 50 playable tracks; it does not
load the entire library. Playlist shuffle keeps Spotify's full playlist context.

Spotify must be running on this Mac with an active device — if you get
"No active Spotify device", open Spotify and start one song manually once.

### Volume, brightness, display

| You say | What happens |
|:---|:---|
| "set the volume to 30 percent" | Sets the selected macOS output to 30% |
| "increase sound by twenty-five percent" | Adds 25 percentage points to its current level |
| "volume down by 15" | Subtracts 15 percentage points |
| "increase volume to forty percent" | Sets an absolute 40%, rather than adding 40 |
| "volume up" / "volume down" / "louder" / "quieter" | ±10 |
| "mute" / "unmute" | Explicitly mutes/restores the selected output |
| "set brightness to 60" | Exact level |
| "increase the brightness by 5 percent" | Relative step |
| "dim the screen" / "brighter" | Relative step |
| "set contrast to 50" | External displays only (DDC/CI) |

Open **System → Sound** for the selected output name, current volume, slider,
mute/unmute and refresh. Values refresh while the System page is active; use
**Sound settings** to choose a different output in macOS. The same controller
handles manual and spoken changes. Volume is bounded to 0–100%.

Built-in speakers, headphones and other outputs work when they expose native
controls. Aggregate/multi-output devices and many fixed-level HDMI, DisplayPort
or DAC outputs are unsupported by this native volume pipeline. Jarvis reports
that limitation and does not switch routing or require BetterDisplay/BlackHole.
Mute uses the hardware control when available; otherwise it remembers the
previous level for that device until Jarvis quits. If no saved level exists,
choose a level explicitly rather than expecting unmute to invent one.

Display brightness has a 10% floor and external contrast has a 20% floor.
To recover an unreadable display, press **⌘⇧R** while Jarvis is running, or
press **⌘⇧A**, say **“Restore my display”**, and press **⌘⇧A** again. Recovery
requests 60% brightness, 50% external contrast and normal software brightness.
Hardware support varies. BetterDisplay is optional; its notification integration
must be enabled for Jarvis to release its dimming.

### System info & questions

| You say | What happens |
|:---|:---|
| "what time is it" / "what's the date" | Instant local answer + floating panel |
| "what day is it" / "what month is it" / "what year is it" | Instant local answer |
| "battery status" / "what's my battery" | Battery read |
| "wifi status" / "bluetooth devices" | Reads |
| "what is the current volume level" / "what's the brightness level" | Reads the reported hardware state |
| "why is the sky blue" | Local AI answer (spoken if *Spoken replies* is on) |
| "explain recursion" | Local AI answer |

General questions use the local model. Incomplete, unclear or unrecognized
commands can be rejected; check the result rather than assuming they ran.

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

### Find by name, document contents, type, date or size

These commands use the same local Spotlight index as macOS search and open a
numbered results window. You can also refine query, kind, date and scope there.
Name/type searches also check files directly in the chosen folders. Those files
appear ahead of nested matches, so a large SDK checkout cannot crowd them out.
At most 100 results are shown. Office lock files are omitted.

| You say | What happens |
|:---|:---|
| "find the SLA stage 2 document" | Searches indexed file names |
| "find the file that mentions elliptic curves" | Searches indexed document contents |
| "find PDFs from last week" | Filters PDF files by last modification date |
| "find presentations bigger than 20 MB" | Filters presentation files by size |
| "find presentations in downloads or documents" | Limits the search to either folder |
| "find PDFs in d drive" | Uses an unambiguous mounted/home-folder name or a saved location alias |
| "open the first one" | Opens result 1 from the current results window |
| "preview the second one" | Opens Quick Look for result 2 |
| "reveal the first one" | Reveals that result in Finder |
| "just preview it" | Previews the selected result |

After a search, press **⌘⇧A** again to say a selection command. You can also
click a result and use Return to open, Space to preview, or the dialog buttons.
Successful Open closes the results window; Preview keeps it available.
Only the current results session can resolve “first” or “second”; it expires
after 10 minutes and clears when closed. Executable/script files are not opened
through these document actions.

Add custom folder aliases in **System → File search locations**. For example,
save your project folder as “work” and say “find PDFs in work”. Unknown or
ambiguous scopes do not silently search your entire Mac. Indexing, filesystem
permissions and document importers affect what appears. Private Notes/Mail
content and unindexed files may not be available.

### macOS Settings panes

Try **“open Bluetooth settings”**, **“open sound settings”**, **“open display
settings”**, **“go to microphone settings”**, or **“open privacy and security
settings”**. Other supported panes include Wi-Fi, network, keyboard, mouse,
trackpad, accessibility, battery, notifications, storage, software update,
Spotlight and general. These open macOS System Settings, not Jarvis preferences.

### Chained commands

Chain actions in one breath — Jarvis splits on commas, "and", "then", "also":

> "open spotify, open whatsapp and also open youtube, in spotify play a song"

- Order is preserved; each clause becomes one action (up to a handful per
  utterance).
- "open chrome and search for swift concurrency" → app + search.
- If the learned router ever truncates a long chain, the rules take over —
  mention the action verbs and Jarvis keeps all of them.

### Routines

Routines pane → create a workflow with a **keyword** and actions, e.g.
keyword *"focus mode"* → open Downloads, set brightness 40. If you want an off
variant, also configure the **off-keyword** *"focus mode off"* and its actions.
Then say:

> "focus mode" — runs it
> "focus mode off" — runs the off-variant

---

## 4. Dictation practice (⌘⇧D)

Put your cursor in a text field. Press **⌘⇧D** once, read an example aloud,
then press **⌘⇧D** again to finish. Pauses alone do not finish a shortcut
recording. Read these aloud; pause briefly between lines.

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

Lists work when you ask for them or count items: say "…as bullet points" for
`- ` items, or dictate "point one … point two …" / "first … second … third …"
for a numbered list. Spoken lead-ins such as "first point is" are dropped; the
items themselves stay your exact words. (Paragraph breaks are not supported
yet.)

Dictation is plain text on purpose: it types what you said, cleaned — it does
not restyle, add headings, or answer anything you happen to say.

---

**System → Dictation → Maximum recording time** accepts 1–60 minutes (default
5). The next dictation or command recording uses that limit and transcribes
when the limit is reached. Long dictations retain their full transcript and
skip the small-model polish pass. The result card offers Copy, Original and,
when text was pasted, Undo. System keeps only the latest dictation pair.

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
| Jarvis quit by itself | Check About → diagnostics and `~/Library/Application Support/Jarvis/logs/memory.log`. The configured memory guard can stop the app; a crash can have another cause. |
| Dictation copies but doesn't paste | Accessibility grant — re-add Jarvis under Privacy & Security → Accessibility (see README). |
| "No active Spotify device" | Open Spotify and start a song once; then voice control works. |
| Answers are silent | Turn on *Spoken replies* (Assistant → Behaviour). |
| Music commands respond but nothing plays | Connections → Spotify shows connected? Reconnect if expired. |
| A dictation line says "Polishing…" for a moment | The small model is resolving a correction/list — it falls back to instant rules after 1.5 s. |
| Wake word doesn't respond | Start live listening with the orb and enable Voice mode. If verification is on for live mode, enroll in Voice first. |
| Volume is unavailable | Check the selected output in System → Sound; choose a single device with native controls. Fixed-level outputs need their own controls or a separate audio controller. |
| A search returns nothing | Check scope, filesystem access, Spotlight indexing and filters. A private app database may not be indexed. |
| Jarvis crashes | About → diagnostics opens local logs. Crash details are collected automatically; you do not need to press Report in the macOS crash dialog. |

---

## 7. Where everything lives

| Pane | What's there |
|:---|:---|
| **Assistant** | Speaker verification, spoken replies, voice mode, follow-up window, start at login, memory limit, recent commands |
| **Voice** | Enrollment, retrain, clear, profile status |
| **System** | Display brightness/contrast/profile, Sound controls, search locations, display rescue, command safeguards, dictation settings and last dictation |
| **Routines** | Custom keyword → action workflows |
| **Connections** | Spotify, PostgreSQL |
| **Insights** | Dictation/command stats, LLM usage |
| **About** | Version, Rust-pipeline toggle, diagnostics and log folder |
| **Setup** | Required permissions/model downloads and optional service setup |


## 8. Read this as a formatted document

In VS Code on macOS, open this file and press **⌘⇧V** for Markdown preview.
For source and preview side by side, press **⌘K**, release, then **V**.
This renders headings, tables and links in a GitHub-style document view;
exact fonts and theme colors can differ. See [VS Code's Markdown guide](https://code.visualstudio.com/docs/languages/markdown).

For action identifiers and dataset labeling details, see
[Current capabilities](dataset/CAPABILITIES.md).
