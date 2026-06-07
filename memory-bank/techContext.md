# Tech Context

## Stack
- Swift + SwiftUI (visionOS 26)
- Xcode 26.4 / visionOS 26.4 SDK
- Xcode project: `/Users/michael/Developer/glas.sh/glas.sh.xcodeproj`
- `SWIFT_VERSION = 5.0`, `CURRENT_PROJECT_VERSION = 2`, `MARKETING_VERSION = 1.0`, `XROS_DEPLOYMENT_TARGET = 26.0`
- SSH layer: Citadel + vendored swift-nio-ssh
- Terminal layer: SwiftTerm
- Security/runtime frameworks in active use:
  - `Security` (Keychain, Secure Enclave key APIs)
  - `LocalAuthentication` (connection-time user presence prompt for secure enclave-backed key use)
  - `os` (structured logging via `Logger`, subsystem `sh.glas`, categories: ssh, keychain, settings, servers, ai, audio, tailscale, recording, immersive, shareplay — all `nonisolated static let`)
  - `FoundationModels` (on-device AI, gated behind `#if canImport(FoundationModels)`)
  - `AVFoundation` (spatial audio bell via `AVAudioPlayer`, `.ambient` session)
  - `WidgetKit` (server health widgets, timeline reload on connect/save)

## SPM Dependency Pins (current as of 2026-05-16)
- swift-crypto 4.5.0
- swift-nio 2.99.0
- swift-log 1.12.0
- swift-collections 1.5.1
- swift-asn1 1.7.0
- swift-argument-parser 1.7.1
- swift-atomics 1.3.0
- swift-system 1.6.4
- BigInt 5.7.0
- SwiftTerm 1.13.0 (requires Xcode 26 "Metal Toolchain" component — install via `xcodebuild -downloadComponent MetalToolchain`)

Top-level package graph entry is `RealityKitContent` (`Packages/RealityKitContent`, swift-tools-version 6.2), which pulls in `Citadel` (local path) and `SwiftTerm`. `GlasSecretStore` (`/Users/michael/Developer/GlasSecretStore`, local path) is a separate direct SPM ref. Vendored `Citadel` (5.9) and `swift-nio-ssh` (5.10) keep their original tools-versions intentionally — bumping them surfaces Swift 6 strict-concurrency errors in static-var declarations and implicit closure captures.

## Build Targets
- `glas.sh` — main app (visionOS, `.windowStyle(.plain)`)
- `glas.shTests` — unit tests (25 tests)
- `glasWidgets` — widget extension (`com.apple.product-type.app-extension`, bundle ID `sh.glas.app.glasWidgets`)

## Privacy Manifests
- `glas.sh/PrivacyInfo.xcprivacy` (app), `glasWidgets/PrivacyInfo.xcprivacy` (widget) — declare `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`, `NSPrivacyTracking=false`, empty collected-data. Auto-bundled by `PBXFileSystemSynchronizedRootGroup` (no pbxproj edits needed).
- Required Reason API audit (2026-05-16): only `UserDefaults` is used. No file timestamps, disk space, or system boot time APIs.

## Key Architecture Patterns
- `PBXFileSystemSynchronizedRootGroup` — Xcode auto-includes all files in `glas.sh/` and `glasWidgets/` directories (except `Info.plist`, explicitly listed in `membershipExceptions`)
- All windows use `.restorationBehavior(.disabled)` — SSH sessions are ephemeral
- Main window is `Window` (singleton), not `WindowGroup` — cannot call `openWindow(id: "main")` when already open
- TerminalView keyboard focus maintained by 2-second periodic timer (visionOS RTI workaround)
- Shared data via App Group `group.sh.glas.shared` (servers, SSH keys, trusted host keys)
- Widget reads from shared App Group defaults, must match app's Codable encoding exactly
- `glassh://connect?serverID=<uuid>` deep link scheme for widget tap-to-connect

## Licensing
- MIT License (2026 Michael Sitarzewski).
