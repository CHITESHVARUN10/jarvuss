# Jarvis System Pipeline Test Report

- Generated at: 2026-09-29T15:24:53Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 8
- Failed: 4
- Success rate: 66.67%
- Average attempt duration: 585.2 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 44 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 942 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 0 ms
    - Plan: AI query: 'what time is it'
    - Reason: Intent mismatch: expected info
  - Attempt 2: FAIL in 0 ms
    - Plan: AI query: 'what time is it'
    - Reason: Intent mismatch: expected info

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 0 ms
    - Plan: AI query: 'battery status'
    - Reason: Intent mismatch: expected info
  - Attempt 2: FAIL in 0 ms
    - Plan: AI query: 'battery status'
    - Reason: Intent mismatch: expected info

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 1191 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1060 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 1063 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 946 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"No active Spotify device"}
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1807 ms
    - Plan: Search YouTube for 'swift package manager' | Open URL: https://www.youtube.com/results?search_query=swift%20package%20manager
    - Steps: ✓ Searching YouTube for 'swift package manager' | ✓ Opened: https://www.youtube.com/results?search_query=swift%20package%20manager

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1808 ms
    - Plan: Search Google for 'swift concurrency' | Open URL: https://www.google.com/search?q=swift%20concurrency
    - Steps: ✓ Searching Google for 'swift concurrency' | ✓ Opened: https://www.google.com/search?q=swift%20concurrency

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-607AE43D`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 3 ms
    - Plan: Create folder 'e2e-folder-607ae43d'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-607ae43d

### fs-create-file [filesystem]

- Command: `create file e2e-file-607AE43D.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1 ms
    - Plan: Create file 'e2e-file-607ae43d.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-607ae43d.txt

### automation-on [automation]

- Command: `focus mode 607AE43D`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 246 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-29T15:24:53Z] [Typed] Received: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-09-29T15:24:53Z] [DDC] Matched display 2 → IOAVService (location: '') | [2026-09-29T15:24:53Z] [DDC] Read VCP 0x10: current=14 max=100 on display 2 | [2026-09-29T15:24:53Z] [DDC] Read VCP 0x12: current=57 max=100 on display 2 | [2026-09-29T15:24:53Z] [Queue] Enqueued (normal): 'focus mode 607AE43D' [queue size: 1] | [2026-09-29T15:24:53Z] [Execution] started: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Triggered keyword: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Executing 1 actions for 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-29T15:24:53Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 607AE43D`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 252 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-29T15:24:53Z] [Execution] started: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Triggered keyword: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Executing 1 actions for 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-29T15:24:53Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-09-29T15:24:53Z] [Typed] Received: 'focus mode off 607AE43D' | [2026-09-29T15:24:53Z] [Queue] Enqueued (normal): 'focus mode off 607AE43D' [queue size: 1] | [2026-09-29T15:24:53Z] [Execution] finished: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Execution] started: 'focus mode off 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Triggered keyword: 'focus mode 607AE43D' | [2026-09-29T15:24:53Z] [Automation] Off variant matched for 'focus mode 607AE43D'. | [2026-09-29T15:24:53Z] [Execution] finished: 'focus mode off 607AE43D'
