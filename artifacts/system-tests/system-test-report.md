# Jarvis System Pipeline Test Report

- Generated at: 2026-10-06T13:18:18Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info

## Summary

- Total: 10
- Passed: 10
- Failed: 0
- Success rate: 100.00%
- Average attempt duration: 158.1 ms
- Skipped (environment unavailable): 2

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 59 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 923 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 5 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 6:48:18 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 55 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 76 ms
    - Plan: Search YouTube for 'swift package manager'
    - Steps: ✓ Searching YouTube for 'swift package manager'

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 77 ms
    - Plan: Search Google for 'swift concurrency'
    - Steps: ✓ Searching Google for 'swift concurrency'

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-D96A8186`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 3 ms
    - Plan: Create folder 'e2e-folder-d96a8186'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-d96a8186

### fs-create-file [filesystem]

- Command: `create file e2e-file-D96A8186.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 3 ms
    - Plan: Create file 'e2e-file-d96a8186.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-d96a8186.txt

### automation-on [automation]

- Command: `focus mode D96A8186`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 129 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-06T13:18:18Z] [Typed] Received: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-06T13:18:18Z] [DDC] Matched display 2 → IOAVService (location: '') | [2026-10-06T13:18:18Z] [DDC] Read VCP 0x10: current=50 max=100 on display 2 | [2026-10-06T13:18:18Z] [DDC] Read VCP 0x12: current=57 max=100 on display 2 | [2026-10-06T13:18:18Z] [Queue] Enqueued (normal): 'focus mode D96A8186' [queue size: 1] | [2026-10-06T13:18:18Z] [Execution] started: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] Triggered keyword: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] Executing 1 actions for 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-06T13:18:18Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off D96A8186`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 251 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-06T13:18:18Z] [Execution] started: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] Triggered keyword: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] Executing 1 actions for 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-06T13:18:18Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-06T13:18:18Z] [Typed] Received: 'focus mode off D96A8186' | [2026-10-06T13:18:18Z] [Queue] Enqueued (normal): 'focus mode off D96A8186' [queue size: 1] | [2026-10-06T13:18:18Z] [Execution] finished: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Execution] started: 'focus mode off D96A8186' | [2026-10-06T13:18:18Z] [Automation] Triggered keyword: 'focus mode D96A8186' | [2026-10-06T13:18:18Z] [Automation] Off variant matched for 'focus mode D96A8186'. | [2026-10-06T13:18:18Z] [Execution] finished: 'focus mode off D96A8186'

## Skipped Scenarios

- spotify-pause — Spotify is not running (playback control needs an active device)
- spotify-next — Spotify is not running (playback control needs an active device)
