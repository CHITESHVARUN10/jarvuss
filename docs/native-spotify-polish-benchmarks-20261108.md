# Native Spotify, faithful dictation, and release verification

Source: uncommitted changes on 9c74339. Candidate UUID `F553D6DD-AA43-3DFD-AA61-AE922B7C6F62`,
built 2026-11-08T14:05:43Z. Previous installed UUID
`E371984B-B2F0-3948-A40A-393FD4EEEBEF`. No Git commit or model training/publication.

## Behavior changes

Removed Spotify Web API/OAuth and key-entry flows from all app screens, Swift
transport, the native helper and the Python development reference. Removed
Spotify credential access from the signed credential broker. Retired Spotify
settings are ignored and dropped on future settings saves; old Keychain entries
are not accessed or deleted. Database credentials and voice services remain.
No Spotify API endpoints or unauthenticated callback exceptions remain.

Native lookup opens Spotify's local search and reads its Accessibility tree.
It accepts exact song/playlist links from Spotify's public or observed internal
UI host, normalizing casing, accents and apostrophe typography. Typed track and
playlist URIs can bypass UI lookup. Liked Songs uses only the specifically
labelled Play/Pause Liked Songs control; repeat requests do not press Pause.
Playback and shuffle use native scripting with player-state readback. Song
requests check the track identifier. Playlists use a native context URI and
playing-state readback; the scripting interface does not separately expose
playlist identity. UI lookup needs Accessibility, playback needs Automation;
the named Liked Songs controls currently assume English Spotify labels.
Unavailable/exact-match failures are reported, with no unrelated fallback.

A live test exposed a separate planner error: “play Today's Top Hits playlist”
was rewritten to “Newest Hits”. Explicit playlist names now take a deterministic
Rust path before model admission; compound commands remain on the full planner.

The polish pass now validates ordered words after its existing sanitizer.
Punctuation, casing, explicit spoken punctuation, and app-directed list lead-ins
can change; invented/replaced/reordered/dropped content is rejected and the
rules transcript is returned. This deliberately prefers an unchanged sentence
to an unverified rewrite, including some unresolved self-corrections. A stubbed
model test demonstrates a same-length rewrite that passed the old drift gate
but now returns the original text. This guards the model's edits, not upstream
speech-recognition mistakes.

## Latest release measurements

| Metric | Previously installed | Updated release |
| --- | ---: | ---: |
| Bundle regular-file bytes (decimal MB) | 280.57 | 280.39 |
| Uncached intent median (ms) | 98 | 90 |
| Native decoder median (ms) | 97.0 | 90.0 |
| Plan median (integer ms) | 0 | 0 |
| Idle app RSS median (decimal MB) | 122.68 | 116.18 |
| Loaded app RSS median (decimal MB) | 843.86 | 710.10 |
| Loaded RSS range across launches (MB) | 829.54–1922.66 | 683.52–733.79 |

Three launches per build; 12 synthetic scenarios, five rounds each in Intent
and Plan mode: 180 intent and 180 planning requests/build. Cache disabled for
both builds. The old benchmark script reported cached repeats as ~0 ms; the
script now explicitly controls cache state and uses launch-scoped environment
variables rather than changing global launchctl settings. Earlier cached runs
of both builds were near zero. These are app/harness timings, not speech-to-action
latency. Zero milliseconds means below the app's integer timer resolution.
The final three candidate launches ran after functional tests completed.

All **360 corresponding plans match** across the builds (0 changes;
12 unique scenarios, not 360 unique commands). All 13 bundled intent model
files are byte-identical. This supports pipeline retention on this corpus,
not a claim of improved learned-model accuracy or universal generalization.
The six real Spotify execution checks are separate from these no-action benches.

Bundle reduction versus the latest installed build is
0.06%. The larger cumulative reduction is
78.4% versus the archived Python-era bundle
(1300.37 MB), combining Python removal, release packaging and subsequent
changes. That historical size was not remeasured today. These are regular-file
lengths, not filesystem allocation or download size.

Timing and RSS differences are observations on this Mac. Background system
load, launch order and model/allocator residency affect them; one old launch had
a notably larger RSS. No new inference algorithm changed and no reliable
whole-app memory or universal Rust speed advantage is claimed from this run.
The intent benchmark excludes Spotify UI lookup and the optional polisher.

## Verification

- Swift: **403 executed, 13 skipped, zero failures**.
- Rust: 114 library + two helper + one integration passed; one ignored.
- Native helper packaging gates: six isolated API tests passed, including
  removed Spotify routes returning 404 with auth and no callback auth bypass.
- Python development reference: 38 executed, one skipped, zero failures.
  The count fell because tests of the deleted Spotify API were retired;
  shared authentication, database, voice, model-update and training-harvest
  coverage remains, and route-removal checks replace obsolete OAuth tests.
- Real signed app: named song twice, Today's Top Hits playlist, Liked Songs
  shuffle twice, pause — **6/6 passed**. Spotify left paused.
- Signed bundle and native libraries verified by packaging; final strict
  deep signature verification passed before installation.
- `git diff --check` clean.

Raw measurements: `logs/runtime-installed-uncached-20261108*.json`,
`logs/runtime-final-20261108-*.json`, `logs/native-spotify-live-final-20261108.json`,
`logs/model-parity-cleanup-20261108.json`. Aggregate JSON is beside this report.

Speech replacement research: [live-speech-model-research-20261108.md](live-speech-model-research-20261108.md).
No replacement speech model was downloaded or activated.

## Installation completed

Replaced `/Applications/Jarvis.app` with the verified candidate and launched it
normally. Installed executable UUID is `F553D6DD-AA43-3DFD-AA61-AE922B7C6F62`.
The previous app is in `~/.Trash/Jarvis-before-native-spotify-20261108-215049.app`.
The copy was staged and signature-checked before replacing the old app; final
strict deep verification and running-process path checks passed. User settings,
voice enrollment and model files were retained. No commit was made.
