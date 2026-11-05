# Speech corrections and diagnostics

Known app-name mishearings are normalized only in command target positions:
`open chant GPT` / `open changpt` → `open ChatGPT`, and `open brief` /
`open breif` / `open beave` → `open Brave Browser`. Browser destinations such
as `open chat gpt in breif` and `open a new tab in brief` are also supported.
The voice sanitizer records changed commands through its existing log hook;
the planner applies the same corrections for direct command inputs. Project
names, quoted names, search queries and ordinary dictated prose are preserved.
This is a finite alias list, not unrestricted fuzzy matching.

In Assistant → Behaviour, enable **Dictation diagnostics** to retain raw,
rules-formatted and final dictation text in the local
`~/Library/Application Support/Jarvis/logs/dictation_dev.jsonl`. It remains
opt-in. Future records also contain a session ID, insertion enabled/result
fields and timestamps. Empty transcripts and capture failures are recorded
when diagnostics is enabled. Audio and a human-correct reference transcript
are not stored by this feature.

The existing `dictation_insert.jsonl` and `dictation_polish.jsonl` operational
logs now include timestamps and session IDs for app-driven dictations. They
contain outcomes/counts, not full transcripts. All three writers share a
serial queue to prevent same-process append races. Existing historical lines
are preserved, including any malformed ones; offline readers should count and
skip invalid JSON rather than silently reporting a complete history.

Insertion success means the native insertion routine reported success; it
cannot certify the words were correct or the target application accepted
them. Likewise, polish `too_long`, `unavailable`, `timeout`, or `rejected`
means the rules-formatted fallback was used, not necessarily lost dictation.
Diagnostics alone are not gold training labels. Review raw/final text against
what was intended before creating correction examples. No automatic training
or promotion is triggered by these logs.

Spotify Connections and Setup distinguish installed native playback from
optional library lookup. Play/pause/next/previous/shuffle need the local Spotify
app and Automation permission, without Web API keys. Named songs, playlists
and Liked Songs still resolve identifiers through the optional Web API helper.
“App installed” does not claim Automation is already granted or playback was
verified. All actual playback writes remain native and require state readback.
