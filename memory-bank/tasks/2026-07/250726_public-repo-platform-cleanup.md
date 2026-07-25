# 250726_public-repo-platform-cleanup

## Objective

Make the public repository structure communicate the completed One Base architecture without requiring contributors to inspect the Xcode project graph.

## Outcome

- ✅ Replaced the misleading `glas.sh-mac` directory name with the explicit `Platforms/macOS` implementation boundary.
- ✅ Moved Mac-only workspace tests beneath the unified `glas.shTests/macOS` test tree.
- ✅ Renamed the former Mac app-entry filename to `MacTerminalWindowPolicy.swift`, matching its actual AppKit helper responsibility.
- ✅ Renamed the Mac entitlement file to `macOS.entitlements`.
- ✅ Preserved one application target, one application `@main`, one shared application scheme, one unit-test target, and one UI-test target.
- ✅ Verified every moved source/resource against its original Git blob with zero content mismatches.
- ✅ Tests: 251 passed, 0 failed, 0 skipped on native Apple Silicon macOS.
- ✅ Builds: iPhone 17 Pro and Vision Pro 27 simulator products succeeded.
- ✅ App smoke: both simulator products installed and launched as `sh.glas.app`.
- ✅ Project parsing, diff whitespace, live legacy-path, and source-content checks passed.

## Files Modified

- `glas.sh.xcodeproj/project.pbxproj` — points the unified target at `Platforms/macOS`, selects Mac resources/plist/entitlements from the new path, and relies on the unified test root for Mac tests.
- `Platforms/macOS/*` — moved existing AppKit workspace, local PTY, window policy, Mac resources, plist, and entitlements without behavioral modification.
- `glas.shTests/macOS/MacWorkspaceTests.swift` — moved existing Mac tests beneath the unified test target.
- `memory-bank/activeContext.md`, `memory-bank/systemPatterns.md`, `memory-bank/decisions.md` — record the public source-boundary convention.
- `memory-bank/releases/one-base/*` — update the completed release’s authoritative current source references.

## Patterns Applied

- `memory-bank/systemPatterns.md#One-Native-Multiplatform-Application-Target`
- Platform-specific implementation belongs beneath `Platforms/<platform>` while shared product authority remains in the primary application target.
- Platform-specific tests remain beneath the unified test target’s source tree.

## Integration Points

- `glas.sh/glas_shApp.swift` remains the sole application entry and composes the Mac workspace scenes.
- `glas.sh.xcodeproj/project.pbxproj` keeps `Platforms/macOS` in the existing `glas.sh` target rather than creating another product.
- Mac SDK builds select `Platforms/macOS/Info.plist`, `Platforms/macOS/macOS.entitlements`, and the Mac asset catalog.

## Architectural Decision

The former folder name was technically compatible with One Base but publicly implied a second product. Explicit platform organization now mirrors the actual target graph while preserving native platform boundaries and all existing behavior.

## Artifacts

- Branch: `codex/public-repo-platform-cleanup`
- Mac XCTest result: `/tmp/glas-platform-cleanup-macos/Logs/Test/Test-glas.sh-2026.07.25_11-51-24--0500.xcresult`
