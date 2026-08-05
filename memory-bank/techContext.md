# Tech Context

## Stack
- Swift 6 + SwiftUI in one native multiplatform application target for macOS, iOS, iPadOS, and visionOS
- Release floor: OS 26+ and Apple Silicon only
- Verified locally with Xcode 27.0 (27A5209h) and the OS 27 SDK family; matching Xcode 26.x archive and runtime proof remains a distribution gate
- Xcode project: `/Users/michael/Software/glass/glas.sh/glas.sh.xcodeproj`
- `SWIFT_VERSION = 6.0`, `CURRENT_PROJECT_VERSION = 2`, `MARKETING_VERSION = 1.0`, bundle ID `sh.glas.app`
- Deployment targets: macOS/iOS/iPadOS/visionOS 26.0; supported platforms are `macosx`, `iphoneos`, `iphonesimulator`, `xros`, and `xrsimulator`
- SSH layer: Citadel + vendored swift-nio-ssh
- Terminal layer: SwiftTerm
- Security/runtime frameworks in active use:
  - `Security` (Keychain, Secure Enclave key APIs)
  - `LocalAuthentication`/Security access control (user presence bound to Secure Enclave signing)
  - `os` (structured logging via `Logger`, subsystem `sh.glas`, categories: ssh, keychain, settings, servers, ai, audio, tailscale, recording, immersive — all `nonisolated static let`)
  - `FoundationModels` (on-device AI, gated behind `#if canImport(FoundationModels)`)
  - `AVFoundation` (spatial audio bell via `AVAudioPlayer`, `.ambient` session)
  - `WidgetKit` (recent-server widgets, timeline reload on connect/save)

## SPM Dependency Pins (resolved 2026-08-01)
- swift-crypto 4.5.1
- swift-nio 2.101.3
- swift-log 1.14.0
- swift-collections 1.6.0
- swift-asn1 1.7.1
- swift-argument-parser 1.8.2
- swift-atomics 1.3.1
- swift-system 1.7.4
- BigInt 6.0.0
- SwiftTerm 1.15.0
- GlasSecretStore revision `1ffaa96312b8e4b4d6b82eb82cc40c8f6df6317f`

`RealityKitContent` (`Packages/RealityKitContent`, swift-tools-version 6.2) owns the SwiftTerm renderer boundary. Citadel (`Packages/Citadel`) and vendored `swift-nio-ssh` remain local source dependencies; GlasSecretStore is resolved from the shared GitHub repository so glas.sh and glassdb can use the same credential authority. SwiftTerm 1.15.0 requires the Xcode Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) for the Metal-backed renderer.

## Build Targets
- `glas.sh` — the sole application target across Mac, iPhone, iPad, and Vision Pro
- `glas.shTests` — shared unit/security/flow tests across supported destinations
- `glas.shUITests` — shared UI-test source and target across supported destinations
- `glasWidgets` — widget extension (`com.apple.product-type.app-extension`, bundle ID `sh.glas.app.glasWidgets`)

The obsolete per-platform application targets and schemes were retired by the One Base release. The current shared Xcode schemes are `glas.sh` and `glasWidgets`; `RealityKitContent` remains a Swift package product, not an application scheme.

## Privacy Manifests
- `glas.sh/PrivacyInfo.xcprivacy` (app), `glasWidgets/PrivacyInfo.xcprivacy` (widget) — declare `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`, `NSPrivacyTracking=false`, empty collected-data. Auto-bundled by `PBXFileSystemSynchronizedRootGroup` (no pbxproj edits needed).
- Required Reason API audit (2026-05-16): only `UserDefaults` is used. No file timestamps, disk space, or system boot time APIs.

## Key Architecture Patterns
- `PBXFileSystemSynchronizedRootGroup` — Xcode auto-includes all files in `glas.sh/` and `glasWidgets/` directories (except `Info.plist`, explicitly listed in `membershipExceptions`)
- All windows use `.restorationBehavior(.disabled)` — SSH sessions are ephemeral
- App scenes are declared once and adapt by platform inside the shared target; platform conditionals belong at presentation and capability boundaries, not in separate products
- Terminal focus uses aggregate ownership state, explicit resign, and bounded key-window-aware retry; the former unconditional two-second timer is superseded
- Shared data via App Group `group.sh.glas.shared` (servers, SSH keys, trusted host keys)
- Widget reads from shared App Group defaults, must match app's Codable encoding exactly
- `glassh://connect?serverID=<uuid>` deep link scheme for widget tap-to-connect

## Evidence Boundary
- Exact-current adaptive-workspace checkpoint (2026-07-30): macOS 27 ran 274/274 tests with zero build warnings; visionOS 27, iPadOS 27, and iOS 27 simulator builds passed.
- One Base completion suites remain the most recent full cross-platform runtime matrix: iPhone/iPad 232/232, visionOS 26.4/27 229/229, and macOS 251/251 before the final render-only delta.
- Physical Vision Pro can SSH to the development Mac over Tailscale. Initial terminal sizing and the native session-sidebar dismissal path are open UX issues, not network or credential blockers.

## Licensing
- MIT License (2026 Michael Sitarzewski).
