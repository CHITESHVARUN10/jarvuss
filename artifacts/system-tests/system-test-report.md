# Jarvis System Pipeline Test Report

- Generated at: 2026-10-06T15:59:12Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info

## Summary

- Total: 10
- Passed: 10
- Failed: 0
- Success rate: 100.00%
- Average attempt duration: 258.4 ms
- Skipped (environment unavailable): 2

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 185 ms
    - Plan: Open 'TextEdit'
    - Steps: ✓ Opened TextEdit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1090 ms
    - Plan: Close 'TextEdit'
    - Steps: ✓ Closed TextEdit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 96 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 9:29:11 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 127 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 198 ms
    - Plan: Search YouTube for 'swift package manager'
    - Steps: ✓ Searching YouTube for 'swift package manager'

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 208 ms
    - Plan: Search Google for 'swift concurrency'
    - Steps: ✓ Searching Google for 'swift concurrency'

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-0322FA7D`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 214 ms
    - Plan: Create folder 'e2e-folder-0322FA7D'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-0322FA7D

### fs-create-file [filesystem]

- Command: `create file e2e-file-0322FA7D.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 213 ms
    - Plan: Create file 'e2e-file-0322fa7d.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-0322fa7d.txt

### automation-on [automation]

- Command: `focus mode 0322FA7D`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 128 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-06T15:59:12Z] [Typed] Received: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-06T15:59:12Z] [DDC] Matched display 2 → IOAVService (location: '') | [2026-10-06T15:59:12Z] [DDC] Read VCP 0x10: current=25 max=100 on display 2 | [2026-10-06T15:59:12Z] [DDC] Read VCP 0x12: current=57 max=100 on display 2 | [2026-10-06T15:59:12Z] [Queue] Enqueued (normal): 'focus mode 0322FA7D' [queue size: 1] | [2026-10-06T15:59:12Z] [Execution] started: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Triggered keyword: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Executing 1 actions for 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-06T15:59:12Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 0322FA7D`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 125 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-06T15:59:12Z] [Execution] started: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Triggered keyword: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Executing 1 actions for 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-06T15:59:12Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-06T15:59:12Z] [Typed] Received: 'focus mode off 0322FA7D' | [2026-10-06T15:59:12Z] [Queue] Enqueued (normal): 'focus mode off 0322FA7D' [queue size: 1] | [2026-10-06T15:59:12Z] [Execution] finished: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Execution] started: 'focus mode off 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Triggered keyword: 'focus mode 0322FA7D' | [2026-10-06T15:59:12Z] [Automation] Off variant matched for 'focus mode 0322FA7D'. | [2026-10-06T15:59:12Z] [Execution] finished: 'focus mode off 0322FA7D'

## Skipped Scenarios

- spotify-pause — Spotify is not running (playback control needs an active device)
- spotify-next — Spotify is not running (playback control needs an active device)
