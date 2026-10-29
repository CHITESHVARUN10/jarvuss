# Jarvis — Current Capabilities

Capability reference for the current source, with examples you can try. Start
with the [Practice Guide](../practice.md) for setup, shortcuts, a full command
cheat sheet and troubleshooting. Rebuild the installed app after pulling source
changes. The action types live in `Sources/JarvisMacOS/Commands/PlannedAction.swift`;
`ActionExecutor.swift` executes them.

## Try these first

Type a command in Assistant, or press **⌘⇧A**, speak, then press **⌘⇧A** again.
Voice action verification requires enrollment when enabled. **⌘⇧D** instead
turns speech into text at the cursor; press it again to finish. For live wake-word
commands, enable listening first. **⌘⇧R** requests emergency display recovery.

| Capability | Example | Requirement / result |
|---|---|---|
| Apps | “open notes” | Opens the installed app |
| Websites | “open chatgpt in brave” | Opens the site in Brave |
| Web search | “search youtube for piano music” | Opens browser results |
| Local files | “find the SLA stage 2 document” | Shows numbered Spotlight results |
| Document text | “find the file that mentions elliptic curves” | Searches indexed contents |
| File filters | “find presentations bigger than 20 MB” | Filters results by kind and size |
| Scoped search | “find PDFs in downloads or documents” | Searches those folders |
| Result selection | “preview the second one” | Uses the current results session |
| Settings | “open Bluetooth settings” | Opens the macOS pane |
| Sound | “increase sound by twenty-five percent” | Adds 25 points on the selected output |
| Sound UI | System → Sound | Output name, reported volume, slider, mute/unmute and refresh |
| Spotify | “shuffle my liked songs” | Requires Spotify connection and an active playback device |
| Display | “set brightness to 60” | Hardware support determines availability |
| Info | “what time is it” | Local answer |
| Routines | Your saved keyword | Runs the workflow you created |
| AI questions | “explain recursion” | Requires local Ollama |

Use your own document and playlist names. Missing permissions, unindexed files,
unsupported devices and unavailable services are reported rather than assumed
successful. For a formatted view in VS Code on Mac, press **⌘⇧V**; **⌘K, then V**
opens preview beside the source.

## 1. Apps

- **open app** — `openApp(name)` via `open -a`; alias + fuzzy resolution
  (Spotify, Google Chrome, Safari, Brave Browser, WhatsApp, Photos, Mail,
  Messages, Calendar, Notes, Music, Maps, App Store, Visual Studio Code,
  Terminal, Finder, System Settings, GitHub Desktop…)
- **close app** — `closeApp(name)` via AppleScript quit
- Known websites open in the browser instead of an app: YouTube, Google,
  Netflix, GitHub, Twitter/X, Reddit, Instagram, LinkedIn, Gmail, Maps,
  ChatGPT, Vercel, Claude, Claude Code, Command Code.

## 2. Web

- **search** — `searchWeb(engine:query)` — engines: YouTube, Google.
  Phrasings: "search youtube for X", "search X on/in youtube",
  "search on the internet for X", "google X", "search X in brave/chrome"
  (browser name is stripped from the query; opens in default browser).
- **open URL** — `openURL(url)` (system default browser).
- **open URL in browser** — `openURLInBrowser(url:browser:)` via
  `open -a <browser> <url>`. The first training pass covers **Brave Browser
  and Google Chrome only**; the executor also accepts Safari, Firefox,
  Microsoft Edge, and Arc, but those are not in shards 063–065.
  Phrasings: "open chatgpt in brave", "open vercel using chrome".
- **local development** — "open react app" opens `http://localhost:5173`;
  "open localhost" opens `http://localhost:3000`; a spoken port overrides
  ("open react app on port 5174", "open localhost:8080"). Local dev opens in
  Brave Browser unless Chrome is named. Backed by `url.open_in`.

## 3. Display (DDC / built-in brightness)

- `setBrightness(0-100)`, `increaseBrightness(by:)`, `decreaseBrightness(by:)`
- `setContrast(0-100)`, `increaseContrast(by:)`, `decreaseContrast(by:)`
  (external monitors only)
- `setResolution(w×h@hz)`, `listResolutions`
- Reads: `info.brightness`, `info.contrast` ("what is the current brightness level")
- Safety floors: hardware brightness 10%, external contrast 20%, nonzero software dimming.
- “Restore my display” or ⌘⇧R requests 60% brightness, 50% external contrast and
  normal software brightness. Only exact recovery phrases bypass verification.
  BetterDisplay is optional; its notification integration is required to release
  dimming that it applies. Jarvis must be running.

## 4. System sound (`VolumeController`)

- `increase(by:)`, `decrease(by:)`, `setLevel(0-100)`, `mute`, `unmute`;
  query: `info.volume`.
- “volume up” / “volume down” default to 10 percentage points. Explicit amounts
  win: “increase volume by twenty five percent” adds 25; “increase volume to
  forty percent” sets an absolute 40. Requests outside 0–100 are rejected.
- Commands resolve the current default media output and live volume, preserve
  channel balance, check writable properties and confirm readback. Responses
  name the output and observed level. Routing and microphone settings are unchanged.
- System → Sound uses the same controller, including per-device fallback-mute
  bookmarks. It shows observed values, manual slider, mute/unmute, refresh and
  a link to macOS Sound settings. Output changes during a slider action are
  detected before applying that action to a different device.
- Hardware mute preserves gain. With no mute property, mute saves that device's
  volume in memory and sets zero; repeated mute keeps the original bookmark.
  After a restart, unmute without a bookmark asks for an explicit volume.
- Aggregate/multi-output devices and outputs without usable native controls
  report a limitation. Many HDMI, DisplayPort and fixed-level DAC outputs need
  hardware controls or separate software-audio processing. BetterDisplay and
  BlackHole are not dependencies of this native pipeline.
- `train-071-system-volume.jsonl` and the separate volume evaluation set are
  prepared for later training. Their presence does not mean new weights have
  been trained, evaluated or promoted.

## 5. Media / Spotify (connected via OAuth)

- `play`, `pause` (also "stop"), `nextTrack`, `previousTrack`
- `playSong(title)`, `playPlaylist(name)`, `playLikedSongs`
- Shuffle on/off for active playback, Liked Songs and named playlists:
  “shuffle it”, “turn shuffle off”, “shuffle my liked songs”,
  “play my Focus playlist on shuffle”, “play my Focus playlist in order”.
- Liked Songs shuffle samples across the library and queues up to 50 playable
  tracks. Named playlists retain full Spotify context and start at a random
  position. Mode is confirmed on the target playback device/context.
- Shuffle runs through native parsing. Earlier small shuffle training
  candidates failed regression gates and were not promoted.

## 6. Quick info (no LLM)

- `info.time`, `info.date` (+ day / month / year), `info.battery`,
  `info.wifi`, `info.bluetooth`

## 7. Files

- `createFile(name)`, `createFolder(name)`, `openFolder(name)`,
  `openLatestFile(inFolder:)` (downloads, documents, desktop, pictures,
  movies, music)
- **`files.query(op, folder, ext)`** — file exploration, answered locally from
  `FileManager` (never a shell string, so a transcript can never inject a
  command). Only Downloads, Documents, Desktop, Pictures, Movies, Music and
  Home are reachable; folder names resolve through a fixed whitelist.

  | op | example utterance | answer |
  |---|---|---|
  | `count` | "how many pdf files are in downloads" | count + most recent name |
  | `countFolders` | "how many folders are in downloads" | count + up to 6 names |
  | `list` | "list all the files in my documents folder" | up to 10 names, newest first |
  | `listFolders` | "what folders are in downloads" | sorted names |
  | `largest` | "what is the biggest file in downloads" | name + size + date |
  | `oldest` | "what is the oldest pdf i have" | name + size + date |
  | `newest` | "what is the latest pptx" | name + size + date |
  | `totalSize` | "how much space do my zip files take" | sum, human-readable |
  | `openNewest` | "open the recent pdf in downloads" | opens via NSWorkspace (Preview for PDFs/images) |
  | `openOldest` | "open the oldest pdf in downloads" | same |

  Extension filter is optional (`ext: ""` = any file). "ppt" maps to `pptx`,
  "image"/"photo" to `png`, "deck"/"slides" to `pptx`.

### Spotlight search and result actions

- `files.search` searches names or indexed document contents via `NSMetadataQuery`.
  Filters include kind, modification date, inclusive byte bounds, and one or
  several folder scopes. “find PDFs from last week”, “find presentations bigger
  than 20 MB”, and “find PDFs in downloads or documents” are examples.
- Standard home folders and unambiguous mounted/home-folder names resolve
  automatically. Save custom aliases in System → File search locations.
  Unknown or ambiguous scopes stop with an explanation.
- A native dialog displays numbered results. `files.result` supports open,
  Quick Look and reveal in Finder, by selected row or ordinal (1–100).
  “open the first one”, “preview the second one”, “just preview it”.
  The session expires after 10 minutes and clears on close. Executables and
  scripts cannot be opened through these document actions.
- Indexing and permissions determine results. Private Notes/Mail data and
  unindexed locations are not guaranteed to appear.

### macOS System Settings

`settings.open` accepts fixed pane identifiers: Bluetooth, Wi-Fi, network,
sound, displays, keyboard, mouse, trackpad, accessibility, privacy/security,
microphone, battery, notifications, storage, software update, Spotlight and
general. Try “open sound settings” or “go to microphone settings”.

Native search, Settings and result labels use `args: {}`. Swift resolves exact
fields from the source utterance. A model cannot invent a result number or
rewrite a query. Result actions require an existing results session.

## 8. Install (preview only — never executes)

- `installPreview(package:source:)` e.g. "install ffmpeg using homebrew"

## 9. AI fallback

- `aiQuery(text)` — genuinely complex / general-knowledge input only
  (Qwen 1.5B; simple commands must never reach it)

## Multi-step (compound commands)

- Compound commands carry **2-4 ordered intents**. Splitting happens on
  "and" / "then" / commas — a comma only starts a new clause when the next
  word is an action verb, so "search for iPhone 18 Pro, blue colour" stays one
  intent.
- Filler is stripped per clause: "also", "plus", "then", "please".
- "open youtube and search for X" collapses to ONE `web.search` (the search
  already opens YouTube with the query in the URL).
- The learned model is the primary compound parser: it emits the full ordered
  intent list in one shot. The rule splitter is the fallback.
- A browser named once carries across following web targets: "open chatgpt in
  brave and claude code" opens both in Brave. Each emitted `url.open_in`
  carries the effective browser explicitly.
- If the model does not return a complete chain, the planner falls back to
  rules/Qwen. Recognition and service failures can still prevent execution;
  inspect the reported per-step outcome rather than assuming every step ran.

### Routing order (as built)

1. Validate/clean the input; recognize exact native volume, file-search, Settings
   and result commands, with safety checks. These run in both pipeline modes.
2. Resolve local state queries and apply the full-input safety pre-check.
3. Native shuffle and remaining unambiguous fast paths run without model admission.
4. The learned router handles ambiguous/compound commands when available.
5. Swift/Rust rules and then Qwen provide fallback; general questions become
   `ai.query`. Execution checks safety again and reports per-step results.

## Other user-facing capabilities

- Setup separates required speech/permission setup from optional Ollama,
  PostgreSQL and Spotify setup. Typed native commands do not need microphone
  enrollment; verification is a separate gate for voice commands.
- Setup also offers independent intent-model downloads and update checks from
  the public Hugging Face repository. Releases are pinned and checksum-verified;
  failed downloads retain the installed model. The intent model is optional for
  dictation and native commands and is separate from Whisper and Ollama.
- Dictation supports auto-paste, copy/original/undo, 1–60-minute recording limits
  (default 5) and a 1–10-second result-card duration. Only the latest original
  and polished dictation pair is kept. Long transcripts skip optional LLM polish.
- Voice manages enrollment and verification; Routines manages saved workflows;
  Connections manages Spotify and PostgreSQL; Insights shows local usage;
  About exposes version, diagnostics and the Rust pipeline option.
- Crash diagnostics are recorded locally without needing to press Report in
  the macOS crash dialog. No diagnostic upload is required to collect them.
