# Routines

Create a routine in Routines, give it a trigger phrase, and add actions in the
order you want them to run. The play button and the spoken trigger run the same
saved steps.

Available actions include:

- **Website · Brave / Chrome / default browser**: enter an address such as
  `https://chatgpt.com`. A bare domain such as `example.com` also works.
- **New tab / New window**: enter Brave, Chrome, VS Code, Finder or Terminal.
- **Window / tab / project**: enter one workspace command, such as
  `open my portfolio project in VS Code`, `open my portfolio project in Finder`,
  or `open my portfolio project in Terminal`. Project lookup uses your configured
  project locations and aliases.
- **Open File**: enter an absolute path or a path beginning with `~/`. The file
  opens in its default app. Spaces and case in file names are preserved.
- **Play Song**: enter a title, optionally including the artist, such as
  `Blinding Lights by The Weeknd`. It uses the same Spotify controller as normal
  commands. Playlist, liked songs, pause, next and previous are also available.
- **Run command**: enter any command supported by the normal command planner,
  such as `set volume to twenty five percent`, a file search, or a command that
  combines several actions. This shares normal planning, safety validation and
  execution; it does not recursively invoke another saved routine.

Existing open/close app and open-folder actions remain available. Unsupported
legacy timer/stopwatch steps remain readable in saved routines, but cannot be
added as new actions or silently treated as successful. Fix incomplete or invalid
steps before saving; the editor explains what needs attention.

Steps run in sequence and use the same success/failure reporting as ordinary
commands. A routine with failed steps is reported as having failed steps, even
if other steps succeed. An off phrase acknowledges the routine as off; it does
not undo actions that have already completed.
