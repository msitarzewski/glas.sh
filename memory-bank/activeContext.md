# Active Context

## Current Focus
- Sprint 1 and Sprint 2 shipped and merged to main.
- Sprint 2 follow-up fixes merged (window restoration crashes, widget data, keyboard focus maintenance).
- Ready for Sprint 3 planning and implementation.

## Immediate Priorities
- Sprint 3 (Tier 3 — Command Center):
  - Tailscale discovery + SSH integration
  - Session recording + AI summary (leverages existing Foundation Models infrastructure)
  - Immersive focus environment
  - Notification overlays
  - SharePlay terminal sharing
- Follow-up hardening:
  - Remote port forwarding (-R) and dynamic/SOCKS (-D)
  - Multi-hop jump host chains
  - True Secure Enclave signing integration
  - SFTP download performance (currently slow for large files, 32KB chunk size)
  - glassdb follow-up: read servers/keys from shared App Group suite

## Sprint 2 Learnings (apply to future sprints)
- **Window restoration**: `.restorationBehavior(.automatic)` is incompatible with ephemeral in-memory sessions. SSH connections can't survive app quit. Layout presets (reconnect fresh) are the right pattern instead.
- **Window(id:) singleton**: `Window` (not `WindowGroup`) only allows one instance. Calling `openWindow(id:)` on an already-open `Window` crashes. Use `dismiss()` instead, or guard with visibility checks.
- **visionOS focus/keyboard**: The RTI (Remote Text Input) system silently drops first responder after idle. A periodic focus maintenance timer (2s) is required to keep `TerminalView` keyboard-active.
- **AVAudioSession**: Must set `.ambient` category to mix with other audio. Default category interrupts media playback.
- **Widget data encoding**: Widget extension must exactly match the main app's `Codable` field types and raw values. Mismatched enum raw values cause silent decode failures (empty data, not crashes).
- **Widget target in pbxproj**: Can be added entirely via pbxproj editing — `PBXFileSystemSynchronizedRootGroup` auto-includes files. Widget needs `NSExtension` / `com.apple.widgetkit-extension` in its own Info.plist.
- **Foundation Models API**: `LanguageModelSession(instructions:)` sets system prompt. `session.respond(to:generating:)` returns `Response<T>` — access generated value via `.content`.
- **visionOS blur**: No API exists for custom gaussian blur of passthrough behind a window. Only system `Material` types provide blur. Don't conflate material frost with blur.
- **Keepalive logic**: Count failures, not sends. `sendKeepAlive()` succeeding proves the transport is alive — only increment missed counter when it throws.
