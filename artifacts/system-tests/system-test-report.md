# Jarvis System Pipeline Test Report

- Generated at: 2026-10-01T13:39:52Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 8
- Failed: 4
- Success rate: 66.67%
- Average attempt duration: 431.4 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 186 ms
    - Plan: Open 'TextEdit'
    - Steps: ✓ Opened TextEdit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 715 ms
    - Plan: Close 'TextEdit'
    - Steps: ✓ Closed TextEdit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 95 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 7:09:45 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 110 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 724 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify pause failed: network/request failure"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1989 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify pause failed: 403 restriction/premium or device limitation"}
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 889 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify next failed: network/request failure"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 843 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify next failed: network/request failure"}
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 144 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 147 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 117 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 157 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-69890C17`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 110 ms
    - Plan: Create folder 'e2e-folder-69890C17'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-69890C17

### fs-create-file [filesystem]

- Command: `create file e2e-file-69890C17.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 175 ms
    - Plan: Create file 'e2e-file-69890c17.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-69890c17.txt

### automation-on [automation]

- Command: `focus mode 69890C17`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 250 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-01T13:39:52Z] [Typed] Received: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-01T13:39:52Z] [DDC] Matched display 1 → IOAVService (location: '') | [2026-10-01T13:39:52Z] [DDC] Read VCP 0x10: current=68 max=100 on display 1 | [2026-10-01T13:39:52Z] [DDC] Read VCP 0x12: current=57 max=100 on display 1 | [2026-10-01T13:39:52Z] [Queue] Enqueued (normal): 'focus mode 69890C17' [queue size: 1] | [2026-10-01T13:39:52Z] [Execution] started: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] Triggered keyword: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] Executing 1 actions for 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-01T13:39:52Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 69890C17`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 252 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-01T13:39:52Z] [Execution] started: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] Triggered keyword: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] Executing 1 actions for 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-01T13:39:52Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-01T13:39:52Z] [Typed] Received: 'focus mode off 69890C17' | [2026-10-01T13:39:52Z] [Queue] Enqueued (normal): 'focus mode off 69890C17' [queue size: 1] | [2026-10-01T13:39:52Z] [Execution] finished: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Execution] started: 'focus mode off 69890C17' | [2026-10-01T13:39:52Z] [Automation] Triggered keyword: 'focus mode 69890C17' | [2026-10-01T13:39:52Z] [Automation] Off variant matched for 'focus mode 69890C17'. | [2026-10-01T13:39:52Z] [Execution] finished: 'focus mode off 69890C17'
