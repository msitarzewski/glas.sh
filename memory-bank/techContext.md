# Tech Context

## Stack
- Swift + SwiftUI (visionOS 26)
- Xcode project: `/Users/michael/Developer/glas.sh/glas.sh.xcodeproj`
- SSH layer: Citadel + vendored swift-nio-ssh
- Terminal layer: SwiftTerm
- Security/runtime frameworks in active use:
  - `Security` (Keychain, Secure Enclave key APIs)
  - `LocalAuthentication` (connection-time user presence prompt for secure enclave-backed key use)
  - `os` (structured logging via `Logger`, subsystem `sh.glas`, categories: ssh, keychain, settings, servers, ai, audio)
  - `FoundationModels` (on-device AI, gated behind `#if canImport(FoundationModels)`)
  - `AVFoundation` (spatial audio bell via `AVAudioPlayer`, `.ambient` session)
  - `WidgetKit` (server health widgets, timeline reload on connect/save)

## Build Targets
- `glas.sh` — main app (visionOS, `.windowStyle(.plain)`)
- `glas.shTests` — unit tests (25 tests)
- `glasWidgets` — widget extension (`com.apple.product-type.app-extension`, bundle ID `sh.glas.app.glasWidgets`)

## Key Architecture Patterns
- `PBXFileSystemSynchronizedRootGroup` — Xcode auto-includes all files in `glas.sh/` and `glasWidgets/` directories
- All windows use `.restorationBehavior(.disabled)` — SSH sessions are ephemeral
- Main window is `Window` (singleton), not `WindowGroup` — cannot call `openWindow(id: "main")` when already open
- TerminalView keyboard focus maintained by 2-second periodic timer (visionOS RTI workaround)
- Shared data via App Group `group.sh.glas.shared` (servers, SSH keys, trusted host keys)
- Widget reads from shared App Group defaults, must match app's Codable encoding exactly
- `glassh://connect?serverID=<uuid>` deep link scheme for widget tap-to-connect

## Licensing
- MIT License (2026 Michael Sitarzewski).
