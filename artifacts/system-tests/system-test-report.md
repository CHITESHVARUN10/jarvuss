# Jarvis System Pipeline Test Report

- Generated at: 2026-10-05T15:00:03Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 8
- Failed: 4
- Success rate: 66.67%
- Average attempt duration: 447.5 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 548 ms
    - Plan: Open 'TextEdit'
    - Steps: ✓ Opened TextEdit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 750 ms
    - Plan: Close 'TextEdit'
    - Steps: ✓ Closed TextEdit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 92 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 8:29:56 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 117 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 1152 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1082 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 1082 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1029 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 159 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 180 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 140 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 153 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-70A9DF28`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 119 ms
    - Plan: Create folder 'e2e-folder-70A9DF28'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-70A9DF28

### fs-create-file [filesystem]

- Command: `create file e2e-file-70A9DF28.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 176 ms
    - Plan: Create file 'e2e-file-70a9df28.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-70a9df28.txt

### automation-on [automation]

- Command: `focus mode 70A9DF28`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 121 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-05T15:00:03Z] [Typed] Received: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-05T15:00:03Z] [DDC] Matched display 1 → IOAVService (location: '') | [2026-10-05T15:00:03Z] [DDC] Read VCP 0x10: current=68 max=100 on display 1 | [2026-10-05T15:00:03Z] [DDC] Read VCP 0x12: current=57 max=100 on display 1 | [2026-10-05T15:00:03Z] [Queue] Enqueued (normal): 'focus mode 70A9DF28' [queue size: 1] | [2026-10-05T15:00:03Z] [Execution] started: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Triggered keyword: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Executing 1 actions for 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-05T15:00:03Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 70A9DF28`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 260 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-05T15:00:03Z] [Execution] started: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Triggered keyword: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Executing 1 actions for 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-05T15:00:03Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-05T15:00:03Z] [Typed] Received: 'focus mode off 70A9DF28' | [2026-10-05T15:00:03Z] [Queue] Enqueued (normal): 'focus mode off 70A9DF28' [queue size: 1] | [2026-10-05T15:00:03Z] [Execution] finished: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Execution] started: 'focus mode off 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Triggered keyword: 'focus mode 70A9DF28' | [2026-10-05T15:00:03Z] [Automation] Off variant matched for 'focus mode 70A9DF28'. | [2026-10-05T15:00:03Z] [Execution] finished: 'focus mode off 70A9DF28'
