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
