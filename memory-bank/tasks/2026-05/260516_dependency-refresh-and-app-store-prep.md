# 260516_dependency-refresh-and-app-store-prep

## Objective
Refresh all SPM dependencies to latest, fix Swift 6 concurrency warnings, add App Store-required privacy manifests, and bump the build number — preparing the app for App Store submission before WWDC26.

## Outcome
- ✅ Build: SUCCESS (Xcode 26.4, visionOS Simulator)
- ✅ Errors: 0
- ✅ Warnings: 5 unique (was 11) — remaining are non-blocking compiler nits
- ✅ Vendored audit fixes (2026-03-15) preserved intact
- ✅ Privacy manifests included in app + widget bundles

## Files Modified
- `Packages/Citadel/Package.swift` — swift-crypto constraint widened `from: "3.12.3"` → `"3.12.3"..<"5.0.0"` to allow major bump
- `Packages/swift-nio-ssh/Package.swift` — swift-crypto constraint widened `"1.0.0"..<"4.0.0"` → `"1.0.0"..<"5.0.0"`
- `glas.sh.xcodeproj/project.pbxproj` — `CURRENT_PROJECT_VERSION` 1 → 2 across all 6 build configs
- `glas.sh.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — refreshed all pins
- `glas.sh/Logger.swift` — added `nonisolated` to all 10 logger statics
- `glas.sh/Models.swift` — added `nonisolated` to `PromptingHostKeyValidator.cacheKey(host:port:)`
- `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift` — added `@MainActor` to `dismissEditMenu()` for UIMenuController workaround

## Files Created
- `glas.sh/PrivacyInfo.xcprivacy` — app target privacy manifest
- `glasWidgets/PrivacyInfo.xcprivacy` — widget target privacy manifest

## Dependency Updates
| Package | Before | After | Type |
|---|---|---|---|
| swift-crypto | 3.15.1 | **4.5.0** | Major bump (unblocked vendored Package.swift constraints) |
| swift-nio | 2.94.0 | 2.99.0 | Minor bump |
| swift-log | 1.9.1 | 1.12.0 | Minor bump |
| swift-collections | 1.3.0 | 1.5.1 | Minor bump |
| swift-asn1 | 1.5.1 | 1.7.0 | Minor bump |
| swift-argument-parser | 1.7.0 | 1.7.1 | Patch bump |
| swift-atomics | 1.3.0 | 1.3.0 | Already current |
| swift-system | 1.6.4 | 1.6.4 | Already current |
| BigInt | 5.7.0 | 5.7.0 | Already current |
| SwiftTerm | 1.10.1 | 1.13.0 | Required Metal toolchain install (Xcode 26 component) |

## Patterns Applied / Discovered
- **swift-crypto `_CryptoExtras` transitively exposes `CCryptoBoringSSL`** — Citadel's `RSA.swift` and `AES.swift` import `CCryptoBoringSSL` directly via C symbols (`CCryptoBoringSSL_RSA_new` etc.). `CCryptoBoringSSL` is not a public product of swift-crypto, but listing `_CryptoExtras` as a target dependency provides transitive access. Removing `_CryptoExtras` breaks Citadel — keep it even though Citadel doesn't `import _CryptoExtras` in source. (Discovered during 4.x bump attempt.)
- **SwiftPM resolver respects existing Package.resolved pins** even when constraints would allow newer versions. To force "absolute latest," edit Package.resolved entries directly with both `version` and `revision` SHA. Deleting Package.resolved alone is insufficient — the resolver is conservative on free choice and picks a version compatible with the lowest tools-version package in the graph.
- **swift-tools-version compatibility for dependencies**: A package with `swift-tools-version:N` can normally depend on packages requiring higher tools-version, but the SPM resolver applies conservative defaults when no explicit pin exists. Explicit pinning bypasses this.
- **Bumping vendored package tools-version activates Swift 6 strict concurrency** — swift-nio-ssh and Citadel both contain code (static vars on non-Sendable types, implicit closure captures) that fails Swift 6 strict mode. Keep tools-version at original (5.9 / 5.10) for vendored packages to preserve Swift 5 semantics; the constraint widening alone is enough to enable the dependency bump.
- **`PBXFileSystemSynchronizedRootGroup` auto-includes `PrivacyInfo.xcprivacy`** — placing the file in `glas.sh/` and `glasWidgets/` directories alongside `Info.plist` is sufficient; no pbxproj edits needed. `Info.plist` is explicitly excluded via `membershipExceptions` but other top-level files are auto-bundled.
- **Default actor isolation in Swift 6 / Xcode 26 makes all module-level statics MainActor by default** — `extension Logger { static let ssh = ... }` is now MainActor-isolated unless explicitly `nonisolated`. Access from a `withLock` closure (synchronously nonisolated) generates warnings.
- **`@Observable` macro + mutable stored properties + `nonisolated`**: Swift compiler suggests "consider using 'nonisolated'" for `nonisolated(unsafe)` on mutable stored properties, but its own language rules reject `nonisolated` on mutable stored properties. The `(unsafe)` form is the only one that compiles and provides the needed escape hatch for `deinit` access. Accept the warning — Swift compiler bug.

## Integration Points
- `Models.swift:1339` — `Logger.ssh.info(...)` access from inside a `runRemotePortForward` callback now compiles cleanly with `nonisolated` on the static.
- `Models.swift:254/260/266` — `cacheKey(host:port:)` calls inside `OSAllocatedUnfairLock.withLock` closures no longer warn.
- `SwiftTermHostView.swift:236` — `dismissEditMenu()` `@objc` selector marked `@MainActor` since `UITapGestureRecognizer` target callbacks run on the main thread.
- Privacy manifests declare only `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` — the app's sole Required Reason API usage. No file timestamp, disk space, or system boot time APIs are used (verified by grep).

## Architectural Decisions
- See `decisions.md` entry: "2026-05-16: swift-crypto 4.x adoption + PrivacyInfo.xcprivacy + App Store readiness"

## Remaining Warnings (Non-Blocking)
- 4× `Models.swift:312-319` — `nonisolated(unsafe) has no effect on property` — Swift suggests `nonisolated` which the language rejects. Compiler bug.
- 1× `SwiftTermHostView.swift:236:13` — `UIMenuController` deprecation — known visionOS workaround for SwiftTerm context menu stuck-state (documented in `systemPatterns.md`).

## What's Left for App Store Submission
1. Distribution provisioning profile + signing in Xcode
2. App Store Connect listing: name, screenshots (visionOS spec), description, privacy policy URL, age rating, category
3. Archive → Distribute App → App Store Connect upload
4. TestFlight smoke test on device

## Artifacts
- Build log: `/tmp/glas_build_final_v2.log` (ephemeral — not committed)
