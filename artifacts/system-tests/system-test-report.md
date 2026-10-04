# Jarvis System Pipeline Test Report

- Generated at: 2026-10-04T15:09:21Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 6
- Failed: 6
- Success rate: 50.00%
- Average attempt duration: 60.2 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 62 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 682 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 3 ms
    - Plan: AI query: 'what time is it'
    - Reason: Intent mismatch: expected info
  - Attempt 2: FAIL in 6 ms
    - Plan: AI query: 'what time is it'
    - Reason: Intent mismatch: expected info

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 5 ms
    - Plan: AI query: 'battery status'
    - Reason: Intent mismatch: expected info
  - Attempt 2: FAIL in 6 ms
    - Plan: AI query: 'battery status'
    - Reason: Intent mismatch: expected info

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 15 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 10 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 7 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 10 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 3 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 6 ms
    - Plan: Search YouTube for 'swift package manager'
    - Reason: Intent mismatch: expected browser

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 4 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser
  - Attempt 2: FAIL in 5 ms
    - Plan: Search Google for 'swift concurrency'
    - Reason: Intent mismatch: expected browser

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-6A853134`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 7 ms
    - Plan: Create folder 'e2e-folder-6a853134'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-6a853134

### fs-create-file [filesystem]

- Command: `create file e2e-file-6A853134.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 6 ms
    - Plan: Create file 'e2e-file-6a853134.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-6a853134.txt

### automation-on [automation]

- Command: `focus mode 6A853134`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 123 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-04T15:09:20Z] [Typed] Received: 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-10-04T15:09:20Z] [DDC] Matched display 3 → IOAVService (location: '') | [2026-10-04T15:09:20Z] [DDC] Read VCP 0x10: current=68 max=100 on display 3 | [2026-10-04T15:09:20Z] [DDC] Read VCP 0x12: current=57 max=100 on display 3 | [2026-10-04T15:09:20Z] [Queue] Enqueued (normal): 'focus mode 6A853134' [queue size: 1] | [2026-10-04T15:09:20Z] [Execution] started: 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] Triggered keyword: 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] Executing 1 actions for 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-04T15:09:20Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 6A853134`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 123 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-10-04T15:09:20Z] [Execution] started: 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] Triggered keyword: 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] Executing 1 actions for 'focus mode 6A853134' | [2026-10-04T15:09:20Z] [Automation] ▶ Open folder 'Downloads' | [2026-10-04T15:09:20Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-10-04T15:09:21Z] [Typed] Received: 'focus mode off 6A853134' | [2026-10-04T15:09:21Z] [Queue] Enqueued (normal): 'focus mode off 6A853134' [queue size: 1] | [2026-10-04T15:09:21Z] [Execution] finished: 'focus mode 6A853134' | [2026-10-04T15:09:21Z] [Execution] started: 'focus mode off 6A853134' | [2026-10-04T15:09:21Z] [Automation] Triggered keyword: 'focus mode 6A853134' | [2026-10-04T15:09:21Z] [Automation] Off variant matched for 'focus mode 6A853134'. | [2026-10-04T15:09:21Z] [Execution] finished: 'focus mode off 6A853134'
