# Obsidian native UI

The approved dark HTML concept is now implemented in the macOS application. The shell, settings, routines, command composer, and recording panels remain SwiftUI/AppKit. Existing command controllers, microphone coordination, model weights, voice verification, and storage configuration are retained.

Navigation consists of Assistant, Voice, Routines, Activity, Appearance, and Settings. Settings opens General, with Setup and About as tabs. Ollama, the native helper, and PostgreSQL configuration are available from General. Removing the Connections destination does not remove native Spotify commands.

Appearance persists six accents, five orb styles, glass opacity, border contrast, and motion preferences independently of model/command settings. “Assistant orb” has a menu on its right; only the selected style is previewed. Recording panels never show an orb. Native visual-effect materials and a shared tint opacity apply to recording panels and dialogs, respecting Reduce Transparency.

Pages use the available window width instead of a centered 1,000-point column. Accent choices wrap on compact windows, General's columns stack when necessary, and the session inspector collapses below 1,000 points. The custom scrollbar that crossed the page has been removed in favor of the native scroll indicator. The main window supports widths down to 840 points.

## Exact orb renderer

The first native implementation approximated the orb styles in SceneKit. That implementation was rejected and replaced. `UI/Obsidian/OrbAssets/renderer.html` now contains the approved Three.js vertex shader, fragment shader, geometry, camera, materials, and lighting. The shader and scene definitions were compared byte for byte against the retained HTML reference. The selected orb is rendered in an isolated, transparent WKWebView; the rest of the application is native.

The orb runs offline with an embedded Three.js 0.160.1 payload and packaged MIT license. A content security policy blocks network access. Native configuration uses only validated enums and boolean flags, with no command text or credentials passed into the renderer. Identical configuration updates are suppressed, including repeated AppState microphone-level publications. Animation pauses with hidden/minimized windows and Reduce Motion; leaving the page destroys the rendering realm. A terminated WebKit process gets at most one automatic reload per view.

The local renderer can be verified without opening microphones or running commands:

```sh
source scripts/macos_toolchain.zsh
swift scripts/verify_orb_renderer.swift \
  .build/Jarvis.app/Contents/Resources/Orb/renderer.html \
  logs/obsidian-ui/packaged-orbs
```

This change adds WebKit rendering processes. The earlier installed/candidate memory benchmark does not describe this UI build; no new performance improvement is claimed.

## Verification and installation

- Swift: 420 tests, 14 skipped, zero failures. Appearance persistence, invalid-value recovery, and reset isolation are covered.
- Six existing packaging/API checks passed; strict deep code-signature verification passed.
- Packaged smoke: 12 intent requests parsed and 12 planning requests planned; no actions executed.
- All five orb scenes initialized in native WebKit, and renderer deactivation passed. PNG evidence and app screenshots are under ignored `logs/obsidian-ui/`.
- Native Appearance, General, and Assistant layouts were checked at wide and compact sizes, including approximately 1,920- and 900-point window widths. The installed orb menu exposes the five choices only when opened.
- All 13 bundled intent-model files are unchanged. No training or publication occurred.

Installed `/Applications/Jarvis.app`, source `915887b169e4+modified`, executable UUID `7141DAE1-A901-312C-8AF9-789325FED188`, built `2026-11-09T15:44:59Z`. Executable SHA-256: `970886506204b098b998b60a583a4de992d4738b0f73d0572a49393b2695c795`.

The previous installed app was moved to `~/.Trash/Jarvis-previous-20261109-211637.app`. Rejected HTML variants v1/v2/v3 were deleted; the current reference remains Git-ignored. No Git commit was made.

## Theme, typography, and composer polish

The Assistant orb is now above the centered command status. Its size respects
both window width and available height. Primary buttons, quiet actions, selected
segments, and Activity chart gradients use the live accent instead of cached
violet values. Enabled button foregrounds select a complementary high-contrast
color; the disabled send arrow remains visible against a neutral background.

Appearance → Interface text offers Extra Small, Small, Default, Large, and
Extra Large. The choice is persistent and applies immediately across the native
app UI. Default uses conventional sizing with at most 4% window-width growth,
replacing the initially over-large Comfortable setting. Compact recording HUDs
retain their independently measured layout. Tests cover all five presets,
persistence, bounded scaling, reset isolation, and all accent foreground contrasts.

The composer uses a native NSTextField that accepts the first mouse click,
preserves the field editor across binding refreshes, and uses a white caret.
The orb web view is not a keyboard focus target. An isolated AppKit harness using
the production command-field source verified typing, binding updates, caret
preservation across redraw, and Return submission with a no-op submit callback.
It did not run any Jarvis commands. Native Routines and Assistant screenshots
were inspected, and the installed text-size menu exposes all five options.

README.md is now a 73-line project overview. The detailed reference moved to
[user-guide.md](user-guide.md); local documentation links were checked.
