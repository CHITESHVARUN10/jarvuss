# Jarvis System Pipeline Test Report

- Generated at: 2026-09-11T13:36:26Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 10
- Failed: 2
- Success rate: 83.33%
- Average attempt duration: 337.8 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 43 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 717 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 7:06:21 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 31 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 12 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 3 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 1 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 3 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1736 ms
    - Plan: Search YouTube for 'swift package manager' | Open URL: https://www.youtube.com/results?search_query=swift%20package%20manager
    - Steps: ✓ Searching YouTube for 'swift package manager' | ✓ Opened: https://www.youtube.com/results?search_query=swift%20package%20manager

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1799 ms
    - Plan: Search Google for 'swift concurrency' | Open URL: https://www.google.com/search?q=swift%20concurrency
    - Steps: ✓ Searching Google for 'swift concurrency' | ✓ Opened: https://www.google.com/search?q=swift%20concurrency

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-3F85B849`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Create folder 'e2e-folder-3f85b849'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-3f85b849

### fs-create-file [filesystem]

- Command: `create file e2e-file-3F85B849.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Create file 'e2e-file-3f85b849.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-3f85b849.txt

### automation-on [automation]

- Command: `focus mode 3F85B849`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 130 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-11T13:36:26Z] [Typed] Received: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-09-11T13:36:26Z] [DDC] Matched display 3 → IOAVService (location: '') | [2026-09-11T13:36:26Z] [DDC] Read VCP 0x10: current=70 max=100 on display 3 | [2026-09-11T13:36:26Z] [Queue] Enqueued (normal): 'focus mode 3F85B849' [queue size: 1] | [2026-09-11T13:36:26Z] [Execution] started: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Triggered keyword: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Executing 1 actions for 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-11T13:36:26Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 3F85B849`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 254 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-11T13:36:26Z] [Execution] started: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Triggered keyword: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Executing 1 actions for 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-11T13:36:26Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-09-11T13:36:26Z] [Typed] Received: 'focus mode off 3F85B849' | [2026-09-11T13:36:26Z] [Queue] Enqueued (normal): 'focus mode off 3F85B849' [queue size: 1] | [2026-09-11T13:36:26Z] [Execution] finished: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Execution] started: 'focus mode off 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Triggered keyword: 'focus mode 3F85B849' | [2026-09-11T13:36:26Z] [Automation] Off variant matched for 'focus mode 3F85B849'. | [2026-09-11T13:36:26Z] [Execution] finished: 'focus mode off 3F85B849'
