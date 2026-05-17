# 2026-05 Tasks

## Tasks Completed

### 2026-05-16: Dependency refresh + App Store readiness pass
- Refreshed all 10 SPM dependencies to absolute latest:
  - **swift-crypto 3.15.1 → 4.5.0** (major bump, unblocked via Package.swift constraint widening in vendored Citadel + swift-nio-ssh)
  - swift-nio 2.94 → 2.99, swift-log 1.9 → 1.12, swift-collections 1.3 → 1.5.1, swift-asn1 1.5 → 1.7, swift-argument-parser 1.7.0 → 1.7.1, SwiftTerm 1.10.1 → 1.13.0 (required installing Xcode 26 Metal toolchain component)
  - swift-atomics, swift-system, BigInt already at latest
- Verified vendored audit fixes (2026-03-15) preserved — no source-level changes to vendored Citadel/nio-ssh
- Fixed 6 of 11 pre-existing Swift 6 concurrency warnings:
  - `Logger.swift` — all 10 static loggers marked `nonisolated`
  - `Models.swift` — `PromptingHostKeyValidator.cacheKey` marked `nonisolated`
  - `SwiftTermHostView.swift` — `dismissEditMenu()` marked `@MainActor`
- Added App Store-required privacy manifests:
  - `glas.sh/PrivacyInfo.xcprivacy` — app target
  - `glasWidgets/PrivacyInfo.xcprivacy` — widget target
  - Declares `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1), `NSPrivacyTracking=false`, no collected data
- Bumped `CURRENT_PROJECT_VERSION` 1 → 2 across all 6 build configs
- Final build: SUCCESS, 0 errors, 5 unique warnings (non-blocking)
- Files: `Packages/Citadel/Package.swift`, `Packages/swift-nio-ssh/Package.swift`, `glas.sh.xcodeproj/project.pbxproj`, `Package.resolved`, `glas.sh/Logger.swift`, `glas.sh/Models.swift`, `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`, new `glas.sh/PrivacyInfo.xcprivacy`, new `glasWidgets/PrivacyInfo.xcprivacy`
- See: [260516_dependency-refresh-and-app-store-prep.md](./260516_dependency-refresh-and-app-store-prep.md)
