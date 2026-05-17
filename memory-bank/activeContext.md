# Active Context

## Current Focus
- App Store submission prep for WWDC26 (early June 2026). All four "Command Center" sprints shipped and merged. Dependency refresh + privacy manifest landed 2026-05-16.
- Working branch: `sprint-details` — clean working tree apart from the dep refresh commit.

## What's Next
- Distribution provisioning profile + signing config in Xcode
- App Store Connect listing: name, screenshots (visionOS spec), description, privacy policy URL, age rating, category
- Archive → upload to App Store Connect
- TestFlight smoke test on device
- SSH Agent forwarding implementation (UI exists, auth path not wired — only remaining `TODO` in source at `Models.swift:1007`)
- SFTP drag-and-drop, terminal themes import/export — post-launch
- glassdb follow-up: read servers/keys from shared App Group suite — separate repo

## Build & Dependency State (as of 2026-05-16)
- Xcode 26.4 / visionOS 26.4 SDK
- swift-crypto 4.5.0, swift-nio 2.99.0, swift-log 1.12.0, swift-collections 1.5.1, swift-asn1 1.7.0, swift-argument-parser 1.7.1, SwiftTerm 1.13.0, swift-atomics 1.3.0, swift-system 1.6.4, BigInt 5.7.0
- Vendored Citadel + swift-nio-ssh stay at original tools versions (5.9 / 5.10) to preserve Swift 5 semantics — bumping their tools versions surfaces strict-concurrency errors in static-var declarations and implicit closure captures.
- Build: 0 errors, 5 warnings (4 unfixable Swift compiler nits about `nonisolated(unsafe)` on `@Observable` Task properties, 1 documented UIMenuController workaround)
- `CURRENT_PROJECT_VERSION = 2`, `MARKETING_VERSION = 1.0`

## Known Platform Limitations
- Bell audio not spatialized per-window (visionOS has no API for per-window short audio effects)
- No custom passthrough blur (only system Materials)
- SharePlay viewer is read-only (no remote input yet)
- Secure Enclave keys are device-bound (cannot transfer)
- SecureEnclave.isAvailable returns false in simulator
- Xcode 26 ships a separate "Metal Toolchain" component required for SwiftTerm 1.12.0+ (installed in this environment via `xcodebuild -downloadComponent MetalToolchain`)

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

## Dependency Refresh Learnings (2026-05-16)
- **swift-crypto `_CryptoExtras`** transitively exposes `CCryptoBoringSSL`. Citadel imports `CCryptoBoringSSL` directly in `AES.swift` and `RSA.swift`. Keep `_CryptoExtras` listed as a Citadel target dependency even though no Citadel source `import _CryptoExtras`.
- **SPM resolver conservatism**: when no explicit pin exists, the resolver picks the version compatible with the lowest tools-version package in the graph, even if `from:`/range constraints would allow newer. To force absolute latest, edit `Package.resolved` directly with `version` + `revision` SHA fields.
- **Bumping vendored packages' tools-version to 6.x activates Swift 6 strict concurrency** on their source — surfaces static-var and closure-capture errors. Don't bump tools-version on vendored copies unless you're prepared to fix those errors. Constraint widening alone is enough to enable dependency upgrades.
- **`PBXFileSystemSynchronizedRootGroup` auto-bundles `PrivacyInfo.xcprivacy`** — just drop it in the target folder, no pbxproj edits needed. Only `Info.plist` is excluded via `membershipExceptions`.
- **`nonisolated(unsafe)` on mutable `@Observable` properties**: Swift compiler suggests `nonisolated` but rejects it for mutable stored properties. The `(unsafe)` form is the only one that compiles and is required for `deinit` access. Accept the "has no effect" warning — it's a compiler bug.
