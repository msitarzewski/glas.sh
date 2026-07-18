# Tech Context

## Stack
- Swift + SwiftUI (visionOS 26)
- Release floor: OS 26+ and Apple Silicon only; visionOS is the current app target
- Verified locally with Xcode 27.0 (27A5209h) / visionOS 27 SDK on visionOS 26.4 and 27.0 arm64 simulators; matching Xcode 26.x proof remains required
- Xcode project: `/Users/michael/Software/glass/glas.sh/glas.sh.xcodeproj`
- `SWIFT_VERSION = 5.0`, `CURRENT_PROJECT_VERSION = 2`, `MARKETING_VERSION = 1.0`, `XROS_DEPLOYMENT_TARGET = 26.0`
- SSH layer: Citadel + vendored swift-nio-ssh
- Terminal layer: SwiftTerm
- Security/runtime frameworks in active use:
  - `Security` (Keychain, Secure Enclave key APIs)
  - `LocalAuthentication`/Security access control (user presence bound to Secure Enclave signing)
  - `os` (structured logging via `Logger`, subsystem `sh.glas`, categories: ssh, keychain, settings, servers, ai, audio, tailscale, recording, immersive — all `nonisolated static let`)
  - `FoundationModels` (on-device AI, gated behind `#if canImport(FoundationModels)`)
  - `AVFoundation` (spatial audio bell via `AVAudioPlayer`, `.ambient` session)
  - `WidgetKit` (recent-server widgets, timeline reload on connect/save)

## SPM Dependency Pins (verified 2026-07-17)
- swift-crypto 4.5.1
- swift-nio 2.101.3
- swift-log 1.14.0
- swift-collections 1.6.0
- swift-asn1 1.7.1
- swift-argument-parser 1.7.1
- swift-atomics 1.3.1
- swift-system 1.7.4
- BigInt 5.7.0
- SwiftTerm 1.13.0 (requires Xcode 26 "Metal Toolchain" component — install via `xcodebuild -downloadComponent MetalToolchain`)

`RealityKitContent` (`Packages/RealityKitContent`, swift-tools-version 6.2) owns the SwiftTerm renderer boundary. Citadel (`Packages/Citadel`) and the in-repository `GlasSecretStore` (`Packages/GlasSecretStore`) are separate direct app dependencies. Vendored `Citadel` (5.9) and `swift-nio-ssh` (5.10) keep their original tools-versions intentionally — bumping them surfaces Swift 6 strict-concurrency errors in static-var declarations and implicit closure captures.

## Build Targets
- `glas.sh` — main app (visionOS, `.windowStyle(.plain)`)
- `glas.shTests` — unit/security/flow tests (164/164 passed on both final simulator lanes)
- `glasWidgets` — widget extension (`com.apple.product-type.app-extension`, bundle ID `sh.glas.app.glasWidgets`)
- `Packages/GlasSecretStore` — secret/trust package (75/75 tests passed across 13 suites)

## Privacy Manifests
- `glas.sh/PrivacyInfo.xcprivacy` (app), `glasWidgets/PrivacyInfo.xcprivacy` (widget) — declare `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`, `NSPrivacyTracking=false`, empty collected-data. Auto-bundled by `PBXFileSystemSynchronizedRootGroup` (no pbxproj edits needed).
- Required Reason API audit (2026-05-16): only `UserDefaults` is used. No file timestamps, disk space, or system boot time APIs.

## Key Architecture Patterns
- `PBXFileSystemSynchronizedRootGroup` — Xcode auto-includes all files in `glas.sh/` and `glasWidgets/` directories (except `Info.plist`, explicitly listed in `membershipExceptions`)
- All windows use `.restorationBehavior(.disabled)` — SSH sessions are ephemeral
- Main window is `Window` (singleton), not `WindowGroup` — cannot call `openWindow(id: "main")` when already open
- Terminal focus uses aggregate ownership state, explicit resign, and bounded key-window-aware retry; the former unconditional two-second timer is superseded
- Shared data via App Group `group.sh.glas.shared` (servers, SSH keys, trusted host keys)
- Widget reads from shared App Group defaults, must match app's Codable encoding exactly
- `glassh://connect?serverID=<uuid>` deep link scheme for widget tap-to-connect

## Licensing
- MIT License (2026 Michael Sitarzewski).
