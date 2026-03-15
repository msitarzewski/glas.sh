# 2026-03 Tasks

## Tasks Completed

### 2026-03-01: AddSSHKeyView closure pattern refactor
- Planned task for AddSSHKeyView closure capture pattern
- See: [260301_add-ssh-key-view-closure-pattern.md](./260301_add-ssh-key-view-closure-pattern.md)

### 2026-03-15: visionOS 26 UX compliance audit & focus latency fix
- Implemented full visionOS 26 Liquid Glass compliance across all views (21 issues)
- Migrated terminal status bar to `.ornament()`, replaced custom modal with `.sheet()`
- Replaced `.ultraThinMaterial` with `.glassBackgroundEffect()` / `.regularMaterial` on chrome
- Expanded all interactive targets to 60pt minimum (buttons, color tags, tag chips)
- Added VoiceOver accessibility labels to all interactive elements across all views
- Added `.restorationBehavior(.disabled)` to terminal/html-preview windows
- Added `.defaultLaunchBehavior(.presented)` to Connections window
- Removed ~130 lines of dead code (ServerCard, ConnectionTicker)
- Removed disabled stub buttons and `print()` statements from HTMLPreviewWindow
- Simplified WindowRecoveryManager to use SwiftUI `OpenWindowAction`
- Fixed input focus latency: added `@FocusState` to all form views, reduced terminal focus retry from 4×120ms to 3×50ms, removed redundant delayed focus calls
- Files: TerminalWindowView, glas_shApp, ConnectionManagerView, ServerFormViews, SettingsView, HTMLPreviewWindow, WindowRecoveryManager, PortForwardingManagerView, SwiftTermHostView
- See: [260315_visionos26-ux-compliance.md](./260315_visionos26-ux-compliance.md)

### 2026-03-15: Terminal layout restructure & context menu fix
- Moved connection string (server name + user@host:port) to a top glass ornament label outside the window
- Simplified bottom ornament to: status indicator + server list button + gear tools menu
- Removed TERM type display from status bar
- Restored all tools (Search, Clear, HTML Preview, Duplicate, Reconnect, Settings) under gear icon
- Used standard `.buttonStyle(.borderless)` for ornament buttons (system-managed sizing)
- Fixed stuck visionOS context menu: added UITapGestureRecognizer to dismiss deprecated UIMenuController on tap
- Files: TerminalWindowView.swift, SwiftTermHostView.swift

### 2026-03-15: Shared App Group defaults migration
- Migrated servers, sshKeys, trustedHostKeys from `UserDefaults.standard` to shared App Group suite (`group.sh.glas.shared`)
- Added App Group entitlement to glas.sh, `SharedDefaults` enum with migration logic
- All 20+ UI settings remain on `.standard`
- See: [260315_shared-defaults-migration.md](./260315_shared-defaults-migration.md)

### 2026-03-15: SSH channel writability fix (terminal input freeze)
- Fixed critical bug: `parentChannelWritabilityChanged` existed on SSHChildChannel but was never called
- Added `channelWritabilityChanged` handler to NIOSSHHandler + propagation through SSHChannelMultiplexer
- Terminal input no longer freezes after transient network backpressure
- See: [260315_ssh-channel-writability-fix.md](./260315_ssh-channel-writability-fix.md)

### 2026-03-15: Comprehensive audit fix — unwired code & dead code cleanup
- Fixed 7 package-level wiring bugs (NIOSSH + Citadel): channelInactive forwarding, remoteAddress0 copy-paste, GlueHandler close propagation, channelHandlers discarded, inboundChannelHandler ignored, ExecOutputHandler.onExit, SFTP initialized promise
- Wired 6 inert app-layer features: confirmBeforeClosing dialog, closeAllSessions on background, terminal bell (visual + audio), forwardAgent/compression marked Coming Soon, snippet execution picker, port forwarding Coming Soon banner
- Removed 7 dead code items across 4 files (SystemInfo, sendKeyPress, feedTerminalText, TerminalLineView, FooterGlassIconButton, Logger.app, isTag)
- See: [260315_comprehensive-audit-fix.md](./260315_comprehensive-audit-fix.md)
