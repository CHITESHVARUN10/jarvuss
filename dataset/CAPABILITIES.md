# Jarvis — Current Capabilities

Ground truth for the intent-model dataset. Every entry below maps 1:1 to a
`PlannedAction` case in `Sources/JarvisMacOS/Commands/ActionPlanner.swift`
and is executed by `ActionExecutor.swift` today.

## 1. Apps
- **open app** — `openApp(name)` via `open -a`; alias + fuzzy resolution
  (Spotify, Google Chrome, Safari, Brave Browser, WhatsApp, Photos, Mail,
  Messages, Calendar, Notes, Music, Maps, App Store, Visual Studio Code,
  Terminal, Finder, System Settings, GitHub Desktop…)
- **close app** — `closeApp(name)` via AppleScript quit
- Known websites open in the browser instead of an app: YouTube, Google,
  Netflix, GitHub, Twitter/X, Reddit, Instagram, LinkedIn, Gmail, Maps

## 2. Web
- **search** — `searchWeb(engine:query)` — engines: YouTube, Google.
  Phrasings: "search youtube for X", "search X on/in youtube",
  "search on the internet for X", "google X", "search X in brave/chrome"
  (browser name is stripped from the query; opens in default browser).
- **open URL** — `openURL(url)`

## 3. Display (DDC / built-in brightness)
- `setBrightness(0-100)`, `increaseBrightness(by:)`, `decreaseBrightness(by:)`
- `setContrast(0-100)`, `increaseContrast(by:)`, `decreaseContrast(by:)`
  (external monitors only)
- `setResolution(w×h@hz)`, `listResolutions`
- Reads: `info.brightness`, `info.contrast` ("what is the current brightness level")

## 4. Volume (`VolumeController` — yes, it works)
- `increase(by:)`, `decrease(by:)`, `setLevel(0-100)`, `mute`, `unmute`
- Read: `info.volume`

## 5. Media / Spotify (connected via OAuth)
- `play`, `pause` (also "stop"), `nextTrack`, `previousTrack`
- `playSong(title)`, `playPlaylist(name)`, `playLikedSongs`

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
- **Nothing is dropped silently.** If neither the model nor the rules parse an
  utterance, it escalates to Qwen, and Qwen's own failure mode is a spoken
  `ai.query` answer — the chain always terminates in a response.

### Routing order (as built)
1. wake-word strip → trailing noise/politeness strip (`CommandValidator`)
2. local hardware reads (brightness/volume, answered from DDC)
3. `SafetyGuard` (blocked / install preview)
4. learned intent model (`IntentModelRouter`) → ordered `PlannedAction` list
5. fast-path regex → strict priority rules (includes `files.query`)
6. Qwen planner fallback
7. `ai.query` — spoken answer, never silence

