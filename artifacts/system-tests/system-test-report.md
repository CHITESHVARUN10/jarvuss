# Jarvis System Pipeline Test Report

- Generated at: 2026-04-10T13:23:33Z
- Retry policy: 1 retry on failure (max 2 attempts per scenario)
- Suites: app_discovery, automation, browser, filesystem, info, spotify

## Summary

- Total: 12
- Passed: 10
- Failed: 2
- Success rate: 83.33%
- Average attempt duration: 639.8 ms

## Scenarios

### app-open [app_discovery]

- Command: `open TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 45 ms
    - Plan: Open 'textedit'
    - Steps: ✓ Opened textedit.

### app-close [app_discovery]

- Command: `close TextEdit`
- Expected intent: `system`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 816 ms
    - Plan: Close 'textedit'
    - Steps: ✓ Closed textedit.

### info-time [info]

- Command: `what time is it`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Info: current time
    - Steps: ✓ Current time: 6:53:23 PM

### info-battery [info]

- Command: `battery status`
- Expected intent: `info`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 35 ms
    - Plan: Info: battery status
    - Steps: ✓ Battery status: Now drawing from 'AC Power'

### spotify-pause [spotify]

- Command: `pause`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 670 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify pause failed: network/request failure"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1622 ms
    - Plan: Media: pause
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify pause failed: 403 restriction/premium or device limitation"}
    - Reason: One or more action steps failed

### spotify-next [spotify]

- Command: `next song`
- Expected intent: `media`
- Outcome: FAIL
- Attempts used: 2
  - Attempt 1: FAIL in 688 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify next failed: network/request failure"}
    - Reason: One or more action steps failed
  - Attempt 2: FAIL in 1302 ms
    - Plan: Media: next track
    - Steps: ✗ Spotify backend failed (400): {"detail":"Spotify next failed: network/request failure"}
    - Reason: One or more action steps failed

### browser-youtube-search [browser]

- Command: `search youtube for swift package manager`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1702 ms
    - Plan: Search YouTube for 'swift package manager' | Open URL: https://www.youtube.com/results?search_query=swift%20package%20manager
    - Steps: ✓ Searching YouTube for 'swift package manager'. | ✓ Opened: https://www.youtube.com/results?search_query=swift%20package%20manager

### browser-search [browser]

- Command: `search google for swift concurrency`
- Expected intent: `browser`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1695 ms
    - Plan: Search Google for 'swift concurrency' | Open URL: https://www.google.com/search?q=swift%20concurrency
    - Steps: ✓ Searching Google for 'swift concurrency'. | ✓ Opened: https://www.google.com/search?q=swift%20concurrency

### fs-create-folder [filesystem]

- Command: `create folder e2e-folder-A8818C7F`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 1 ms
    - Plan: Create folder 'e2e-folder-a8818c7f'
    - Steps: ✓ Created folder: /Users/chiteshvarun/D-drive/jarvis/e2e-folder-a8818c7f

### fs-create-file [filesystem]

- Command: `create file e2e-file-A8818C7F.txt`
- Expected intent: `filesystem`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 0 ms
    - Plan: Create file 'e2e-file-a8818c7f.txt'
    - Steps: ✓ Created file: /Users/chiteshvarun/D-drive/jarvis/e2e-file-a8818c7f.txt

### automation-on [automation]

- Command: `focus mode A8818C7F`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 126 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-04-10T13:23:32Z] [Typed] Received: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Queue] Enqueued (normal): 'focus mode A8818C7F' [queue size: 1] | [2026-04-10T13:23:32Z] [Execution] started: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Triggered keyword: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Executing 1 actions for 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] ▶ Open folder 'Downloads' | [2026-04-10T13:23:32Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads

### automation-off [automation]

- Command: `focus mode off A8818C7F`
- Expected intent: `automation`
- Outcome: PASS
- Attempts used: 1
  - Attempt 1: PASS in 255 ms
    - Plan: Automation path via AppState.executeTypedCommand
    - Steps: [2026-04-10T13:23:32Z] [Execution] started: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Triggered keyword: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Executing 1 actions for 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] ▶ Open folder 'Downloads' | [2026-04-10T13:23:32Z] [Automation] ✓ Opened folder: /Users/chiteshvarun/Downloads | [2026-04-10T13:23:32Z] [Typed] Received: 'focus mode off A8818C7F' | [2026-04-10T13:23:32Z] [Queue] Enqueued (normal): 'focus mode off A8818C7F' [queue size: 1] | [2026-04-10T13:23:32Z] [Execution] finished: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Execution] started: 'focus mode off A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Triggered keyword: 'focus mode A8818C7F' | [2026-04-10T13:23:32Z] [Automation] Off variant matched for 'focus mode A8818C7F'. | [2026-04-10T13:23:32Z] [Execution] finished: 'focus mode off A8818C7F'
