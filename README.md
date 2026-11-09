# Jarvis

A macOS assistant for dictation and voice commands. Open apps and projects,
find files, control music and system settings, and run routines from your voice
or keyboard. Speech and intent recognition run on your Mac.

## Features

- Dictate text at the cursor with local Whisper transcription and optional formatting.
- Control apps, browser tabs, files, projects, Spotify, volume, and displays.
- Combine commands into routines triggered by a phrase.
- Use Apple on-device speech for live listening, with a local Whisper fallback.
- Choose a dark theme, accent color, orb style, glass finish, and readable text size.
- Review command activity and correct misunderstood requests locally.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| **⌘⇧D** | Start or finish dictation |
| **⌘⇧A** | Start or finish a voice command |
| **⌘⇧R** | Restore display visibility |

Live listening starts only when you enable it. You can also type commands in Assistant.

## Getting started

Requires **macOS 26 or later**. Allow microphone access for recording,
Accessibility for text insertion and app control, and Automation when prompted.
Use **Settings → Setup** to prepare models and permissions. Configure project
folders and local services in **Settings → General**.

Spotify uses the native desktop app; no Spotify API key or OAuth setup is needed.
Ollama handles optional local language-model requests. PostgreSQL provides
configured activity storage. No Jarvis account is required.

## Build

Development requires Xcode with a matching macOS SDK, Rust, CMake, and
Python 3.11+ for model preparation and verification. Python is not required
to run the packaged app.

```zsh
./scripts/package_jarvis_app.zsh --install
```

This builds, signs, installs, and opens `/Applications/Jarvis.app`.
For a UI refresh using existing native speech components:

```zsh
./scripts/package_jarvis_app.zsh --refresh-app --install
```

## Documentation

- [User guide and setup details](docs/user-guide.md)
- [Example commands](practice.md)
- [Supported capabilities](dataset/CAPABILITIES.md)
- [Projects and workspace commands](docs/workspace-commands.md)
- [Routines](docs/routines.md)
- [Architecture](docs/architecture.md)
- [UI implementation](docs/obsidian-ui-20261109.md)

## Development checks

```zsh
source scripts/macos_toolchain.zsh
swift test --build-system native
```

The app also provides **Settings → About → Command testing** for repeatable
intent, planning, execution, and dictation checks. Execution mode performs real
actions; planning and intent modes do not.
