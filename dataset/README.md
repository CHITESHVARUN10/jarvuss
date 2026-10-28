# Jarvis Intent Dataset (hand-written)

Utterance → structured-intent pairs for training a small, fast router model
that will replace `FastPathRouter` regex routing. Every line is hand-authored
from real usage patterns — **not** programmatically generated.

## Schema (one JSON object per line)

```json
{"text": "<verbatim user utterance>", "intents": [{"name": "<intent>", "args": {...}}]}
```

- `text` is kept verbatim — typos, ASR mishearings, trailing periods, filler
  words, wake words ("jarvis ..."), wrong case. The model must survive them.
- `intents` is an ordered list. Multi-step commands carry 2-3 entries in the
  order the user spoke them.

## Intent vocabulary (mirrors PlannedAction)

| intent | args |
|---|---|
| `app.open` / `app.close` | `name` (canonical app name) |
| `url.open` | `url` (system default browser) |
| `url.open_in` | `url`, `browser` (first training pass: Brave Browser, Google Chrome) |
| `web.search` | `engine` (YouTube\|Google), `query` |
| `display.brightness_set` | `level` 0–100 |
| `display.brightness_up` / `display.brightness_down` | `by` |
| `display.contrast_set` | `level` |
| `display.contrast_up` / `display.contrast_down` | `by` |
| `volume.set` | `level` |
| `volume.up` / `volume.down` | `by` |
| `volume.mute` / `volume.unmute` | — |
| `media.play` / `media.pause` / `media.next` / `media.previous` | — |
| `media.play_song` | `title` |
| `media.play_playlist` | `name` |
| `media.play_liked` | — |
| `media.shuffle` | none; Swift resolves collection, exact playlist name, and explicit on/off state from the utterance |
| `info.time` / `info.date` / `info.brightness` / `info.contrast` / `info.volume` / `info.battery` / `info.wifi` / `info.bluetooth` | — |
| `file.create` / `folder.create` | `name` |
| `folder.open` | `name` |
| `file.open_latest` | `folder` |
| `files.query` | `op` (count\|countFolders\|list\|listFolders\|largest\|oldest\|newest\|totalSize\|openNewest\|openOldest), `folder`, `ext` (`""` = any) |
| `files.search` | none; Swift resolves name/content, folders, types, dates, and byte bounds from the utterance |
| `files.result` | none; Swift resolves open/preview/reveal and the ordinal against the visible results |
| `settings.open` | none; Swift resolves the supported Settings pane from the utterance |
| `install.preview` | `package`, `source` |
| `ai.query` | `text` |

## Labeling rules (observed in the data)

1. Bare relative commands ("increase the brightness", "brightness up") default
   to `by: 10` — matches current executor behavior.
2. "decrease the brightness **to** 14" is absolute → `brightness_set 14`.
3. Out-of-range values stay as spoken (e.g. `level: 200`) — the executor clamps.
4. "open youtube and search for X" → single `web.search` (search opens YouTube).
5. "search X in brave/chrome" → `web.search` with the browser stripped from
   the query (matches `parseSearchQuery`).
6. App aliases/typos map to canonical names ("spotifi" → Spotify).
7. "stop [the music]" → `media.pause`.
8. Non-action / complex / general-knowledge input → `ai.query`.
9. Wake words are noise: "jarvis open spotify" = "open spotify".
10. A site opened without a browser uses `url.open` (system default). Any
    explicitly named browser uses `url.open_in` with the canonical browser
    name — never `app.open` followed by `url.open`, which would silently use
    the default browser.
11. The first training pass covers **Brave Browser and Google Chrome only**.
    Edge, Arc, Safari, and Firefox are deliberately excluded from the shards;
    the executor still understands them, but they are not model targets yet.
12. "open chatgpt in brave" and "open chat gpt in chrome" carry the browser
    target; aliases/typos (chat gpt, versel, cloud code, commandcode) still
    resolve to the canonical site URL.
13. Local development phrases use `url.open_in`:
    "open react app" → `http://localhost:5173`, "open localhost" →
    `http://localhost:3000`, and a spoken port overrides the default. Local
    dev opens in Brave Browser unless Chrome is named.
14. In compounds, a browser named once applies to the following site(s)
    ("open chatgpt in brave and claude code" → both Brave). Every intent in
    the label repeats the effective browser explicitly.

## Files

- `train.jsonl` — main training set (broad coverage, noisy)
- `valid.jsonl` — held-out phrasings for tuning
- `test.jsonl` — held-out phrasings + multi-step for final eval
- `train-061-files.jsonl` — file exploration (`files.query`), 1176 rows
- `train-062-compound.jsonl` — compound multi-intent commands (2-4 ordered
  intents), 704 rows
- `train-063-browser-sites.jsonl` — browser-targeted website opens
  (`url.open` / `url.open_in`), 99 rows
- `train-064-localhost.jsonl` — React/Vite/localhost/port opens, 219 rows
- `train-065-compound-browser.jsonl` — compound browser + local-dev + mixed
  actions, 137 rows
- `train-066-native-search.jsonl` — 100 authored name/content/type/date/size
  searches, including multiple folder scopes and custom drives
- `train-067-settings-panes.jsonl` — 40 authored System Settings pane requests
- `train-068-result-selection.jsonl` — 50 authored ordinal/open/preview/reveal
  replies; only meaningful against the current results session
- `train-069-native-navigation.jsonl` — 60 additional Settings-navigation
  phrasings, including “go to”, privacy/security conjunctions, and pane names
- `train-070-spotify-shuffle.jsonl` — 70 shuffle commands for current playback,
  Liked Songs (including “light songs” speech recognition), and named playlists;
  separate `resolved_args` record the intended collection/name/on-off state

`training/eval_spotify_shuffle.jsonl` holds 12 separate shuffle evaluation
phrases and is excluded from training. `media.shuffle` is a classifier-only
intent, like native file search: the model cannot rewrite a playlist name or
override the requested mode. Small updates can use `post_train.py` with
`--focus-intents media.shuffle`, an older-command rehearsal sample, and a
separate output directory. Export and evaluate with `evaluate_native_search.py
--shuffle` before replacing the accepted model.

The small shuffle candidates were trained and evaluated but were not promoted:
they did not meet the combined shuffle/general-command regression gate. The
previous accepted checkpoint remains in use. Shuffle commands are implemented
in the native router and do not depend on a learned-model update. Candidate
reports are under `training/out/spotify-shuffle*/evaluation.json` locally.

`training/eval_native_search.jsonl` holds 16 separate evaluation utterances.
Native intents classify the command family and use `args: {}`. They do not
ask a language model to rewrite a filename, calculate bytes, or invent a file
selection. `resolved_args` is a separate, human-authored end-to-end test oracle;
it is not supplied as a training target. The Swift mapper requires the source
utterance and a matching native parser result before accepting these intents.

The search oracle contains `query`, `mode` (`name`/`content`), `kind`, `scope`,
`date`, `min_bytes`, and `max_bytes`. Empty `query` means type/filter
search; empty `scope` means all indexed local locations, otherwise scopes are
joined by `|` (e.g. `downloads|documents|d drive`). Byte bounds are inclusive;
zero means no bound. `date` is `any`, `today`, `yesterday`, `this_week`,
`last_week`, `this_month`, `last_month`, `last_7_days`, or `last_30_days`, and
filters last modification time. Content search returns only indexed items;
it does not promise access to private Notes or Mail databases. Native search
and fixed settings links remain available when model inference is unavailable.
Result oracles have `action` (`open`/`preview`/`reveal`) and `index` (1–100,
or 0 for the selected row). Settings oracles have a fixed `pane` identifier.

`train-061` and `train-062` are rebuilt by `training/generate_datasets.py`.
`train-063`–`train-065` add browser targeting, local development URLs, and
their compound forms. Before 061, **every example in this dataset was
single-intent** — which is why compound speech ("open spotify, open whatsapp
and also open youtube and in spotify play a song") never produced a plan.

## Post-training / RL

`training/post_train.py` closes the loop on the router's own log
(`~/Library/Application Support/Jarvis/logs/intent_router.jsonl`):

```
python training/post_train.py --harvest            # log → training/data/rl_pairs.jsonl
python training/post_train.py --train --epochs 3   # continue-train from training/out/best
python training/post_train.py --eval               # reward-score the checkpoint
```

It continues from the existing checkpoint, so the model keeps the same
architecture and vocab — no size growth. Harvested pairs pass three quality
gates (schema-valid, no known-bad behaviour such as a sentence in a song-title
slot, arguments consistent with the utterance) because a `model_hit` only
means the router trusted the output, not that it was right.

## Future training notes (priority: FAST + ACCURATE)

- Closed intent vocabulary → seq2seq text-to-JSON; ~350 examples is a seed,
  grow to 1-2k before serious training.
- Target: p95 < 20 ms on Apple Silicon (small encoder or fine-tuned
  ~100-500M model quantized to int8), exact-match on intents + args.
- This replaces FastPathRouter only; `ai.query` routing stays as fallback.
