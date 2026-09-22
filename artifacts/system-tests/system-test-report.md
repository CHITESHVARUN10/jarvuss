# Jarvis System Pipeline Test Report

- Generated at: 2026-09-22T03:21:29Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 10
- Failed: 2
- Success rate: 83.33%
- Average attempt duration: 370.4 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 47 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 965 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 8:51:24 AM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 28 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 13 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 5 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 3 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 2 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed: Could not connect to the server.
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1970 ms
    - Plan: Search YouTube for 'swift package manager' | Open URL: https://www.youtube.com/results?search_query=swift%20package%20manager
    - Steps: ✓ Searching YouTube for 'swift package manager' | ✓ Opened: https://www.youtube.com/results?search_query=swift%20package%20manager

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1776 ms
    - Plan: Search Google for 'swift concurrency' | Open URL: https://www.google.com/search?q=swift%20concurrency
    - Steps: ✓ Searching Google for 'swift concurrency' | ✓ Opened: https://www.google.com/search?q=swift%20concurrency

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-8268356F`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 2 ms
    - Plan: Create folder 'e2e-folder-8268356f'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis_code/e2e-folder-8268356f

### fs-create-file [filesystem]

- Command: `create file e2e-file-8268356F.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1 ms
    - Plan: Create file 'e2e-file-8268356f.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis_code/e2e-file-8268356f.txt

### automation-on [automation]

- Command: `focus mode 8268356F`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 246 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-22T03:21:28Z] [Typed] Received: 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [DDC] Discovered 1 DCPAVServiceProxy entries | [2026-09-22T03:21:28Z] [DDC] Matched display 1 → IOAVService (location: '') | [2026-09-22T03:21:28Z] [DDC] Read VCP 0x10: current=38 max=100 on display 1 | [2026-09-22T03:21:28Z] [Queue] Enqueued (normal): 'focus mode 8268356F' [queue size: 1] | [2026-09-22T03:21:28Z] [Execution] started: 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] Triggered keyword: 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] Executing 1 actions for 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-22T03:21:29Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off 8268356F`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 128 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-09-22T03:21:28Z] [Execution] started: 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] Triggered keyword: 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] Executing 1 actions for 'focus mode 8268356F' | [2026-09-22T03:21:28Z] [Automation] ▶ Open folder 'Downloads' | [2026-09-22T03:21:29Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-09-22T03:21:29Z] [Typed] Received: 'focus mode off 8268356F' | [2026-09-22T03:21:29Z] [Queue] Enqueued (normal): 'focus mode off 8268356F' [queue size: 1] | [2026-09-22T03:21:29Z] [Execution] finished: 'focus mode 8268356F' | [2026-09-22T03:21:29Z] [Execution] started: 'focus mode off 8268356F' | [2026-09-22T03:21:29Z] [Automation] Triggered keyword: 'focus mode 8268356F' | [2026-09-22T03:21:29Z] [Automation] Off variant matched for 'focus mode 8268356F'. | [2026-09-22T03:21:29Z] [Execution] finished: 'focus mode off 8268356F'
