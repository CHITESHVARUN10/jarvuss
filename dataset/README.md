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
| `url.open` | `url` |
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
| `info.time` / `info.date` / `info.brightness` / `info.contrast` / `info.volume` / `info.battery` / `info.wifi` / `info.bluetooth` | — |
| `file.create` / `folder.create` | `name` |
| `folder.open` | `name` |
| `file.open_latest` | `folder` |
| `files.query` | `op` (count\|countFolders\|list\|listFolders\|largest\|oldest\|newest\|totalSize\|openNewest\|openOldest), `folder`, `ext` (`""` = any) |
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

## Files

- `train.jsonl` — main training set (broad coverage, noisy)
- `valid.jsonl` — held-out phrasings for tuning
- `test.jsonl` — held-out phrasings + multi-step for final eval
- `train-061-files.jsonl` — file exploration (`files.query`), 1176 rows
- `train-062-compound.jsonl` — compound multi-intent commands (2-4 ordered
  intents), 704 rows

The two generated shards are rebuilt by `training/generate_datasets.py`.
Before them, **every example in this dataset was single-intent** — which is
why compound speech ("open spotify, open whatsapp and also open youtube and
in spotify play a song") never produced a plan.

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
