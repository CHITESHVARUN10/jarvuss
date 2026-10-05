# Jarvis System Pipeline Test Report

- Generated at: 2026-10-05T16:05:55Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info

## Summary

- Total: 10
- Passed: 10
- Failed: 0
- Success rate: 100.00%
- Average attempt duration: 211.9 ms
- Skipped (environment unavailable): 2

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 197 ms
    - Plan: Open 'TextEdit'
    - Steps: ✓ Opened TextEdit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 708 ms
    - Plan: Close 'TextEdit'
    - Steps: ✓ Closed TextEdit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 96 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 9:35:54 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 118 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 200 ms
    - Plan: Search YouTube for 'swift package manager'
    - Steps: ✓ Searching YouTube for 'swift package manager'

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 224 ms
    - Plan: Search Google for 'swift concurrency'
    - Steps: ✓ Searching Google for 'swift concurrency'

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-2B5CB9FE`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 187 ms
    - Plan: Create folder 'e2e-folder-2B5CB9FE'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-2B5CB9FE

### fs-create-file [filesystem]

- Command: `create file e2e-file-2B5CB9FE.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 136 ms
    - Plan: Create file 'e2e-file'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file

### automation-on [automation]

- Command: `focus mode 2B5CB9FE`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 126 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-05T16:05:55Z] [Typed] Received: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-05T16:05:55Z] [DDC] Matched display 1 → IOAVService (location: '') | [2026-10-05T16:05:55Z] [DDC] Read VCP 0x10: current=68 max=100 on display 1 | [2026-10-05T16:05:55Z] [DDC] Read VCP 0x12: current=57 max=100 on display 1 | [2026-10-05T16:05:55Z] [Queue] Enqueued (normal): 'focus mode 2B5CB9FE' [queue size: 1] | [2026-10-05T16:05:55Z] [Execution] started: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Triggered keyword: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Executing 1 actions for 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-05T16:05:55Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 2B5CB9FE`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 127 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-05T16:05:55Z] [Execution] started: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Triggered keyword: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Executing 1 actions for 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-05T16:05:55Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-05T16:05:55Z] [Typed] Received: 'focus mode off 2B5CB9FE' | [2026-10-05T16:05:55Z] [Queue] Enqueued (normal): 'focus mode off 2B5CB9FE' [queue size: 1] | [2026-10-05T16:05:55Z] [Execution] finished: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Execution] started: 'focus mode off 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Triggered keyword: 'focus mode 2B5CB9FE' | [2026-10-05T16:05:55Z] [Automation] Off variant matched for 'focus mode 2B5CB9FE'. | [2026-10-05T16:05:55Z] [Execution] finished: 'focus mode off 2B5CB9FE'

## Skipped Scenarios

- spotify-pause — Spotify is not running (playback control needs an active device)
- spotify-next — Spotify is not running (playback control needs an active device)
