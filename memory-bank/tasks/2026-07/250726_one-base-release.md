# 250726_one-base-release

## Objective

Complete the One Base release by consolidating glas.sh into one native multiplatform application target, product identity, application entry point, and shared scheme without replacing the existing AppKit, UIKit, visionOS, terminal, connection, or GlassSecretStore architecture.

## Outcome

- ✅ One native `glas.sh` application target and shared scheme support iPhone, iPad, Vision Pro, and Apple Silicon Mac; Catalyst is disabled and all release deployment floors remain OS 26 or newer.
- ✅ One `@main` application composes platform-native scenes while retaining guarded Mac workspace/local-PTY sources.
- ✅ One `sh.glas.app` product identity uses SDK-specific plist, entitlements, icons, and extension filtering.
- ✅ Shared app group, Keychain group, iCloud KVS namespace, credentials, SSH keys, host trust, servers, themes, settings, and workgroups remain authoritative through existing stores and GlassSecretStore.
- ✅ The widget remains a separate supported extension; obsolete Mac app/test targets, products, proxies, configurations, and scheme are removed.
- ✅ No new production or test source file was introduced and no Swift source file was deleted.
- ✅ User approved implementation, QA dispositions, and release documentation on 2026-07-25.

## Files Modified

- `glas.sh.xcodeproj/project.pbxproj` — unified native app/test configuration, one identity, SDK-specific settings, widget filtering, and duplicate-target retirement.
- `glas.sh/glas_shApp.swift` — single multiplatform application authority and native scene composition.
- `glas.sh-mac/*.swift` — retained AppKit workspace, local PTY, state, commands, and secure-keyboard behavior behind complete macOS boundaries.
- `glas.sh/Constants.swift` — safe idempotent migration of readable non-secret values from the old development Mac defaults domain.
- `glas.sh/KeychainManager.swift`, `glas.sh/ServerManager.swift` — shared credential compatibility cleanup and exact UI-fixture lifecycle.
- `glas.sh/ConnectionManagerView.swift`, `glas.sh/TerminalWindowView.swift` — native search exposure and render-transaction-safe terminal ingest.
- `glas.shTests/glas_shTests.swift`, `glas.sh-macTests/MacWorkspaceTests.swift`, `glas.shUITests/ConnectionLibraryUITests.swift` — unified platform, identity, credential, workspace, lifecycle, and UI regression coverage.
- `glasWidgets/ServerHealthWidget.swift` and platform entitlements — unified identity and shared-group extension behavior.

## Patterns Applied

- `memory-bank/systemPatterns.md#One-Native-Multiplatform-Application-Target`
- `memory-bank/systemPatterns.md#Connection-Library-Projection-and-Native-Shell-Boundary`
- `memory-bank/systemPatterns.md#Terminal-Architecture`
- `memory-bank/systemPatterns.md#SSH-Secret-Handling-Pattern`

## Integration Points

- `glas.sh/glas_shApp.swift` owns every application scene and delegates platform behavior to existing native source boundaries.
- `glas.sh.xcodeproj/project.pbxproj` selects platform metadata/resources and hosts both shared test bundles from the unified app.
- `glas.sh/Constants.swift` preserves old non-secret development preferences without overwriting unified values or moving secret material through defaults.
- GlassSecretStore remains the credential and host-trust authority through the shared Keychain access group used by glas.sh and glassdb.

## Architectural Decisions

- The separate Mac target is superseded by one native multiplatform target; native AppKit implementation remains, Catalyst remains prohibited.
- Feature parity means shared capability and data authority with Apple-native platform presentation, not an identical view hierarchy.
- The widget remains separate because it is a separate executable; tests remain separate bundles but have one application host.
- Baseline commit `c9f7a406` remains the rollback point. The user accepted one reviewable working-tree diff rather than retroactively rewriting phase commits.

## QA Results

- iPhone iOS 27: 232/232 unit tests; final compact settings/network smoke 1/1; zero runtime warnings.
- iPadOS 27: 232/232 unit tests; full UI 2/2 after the native regular-width Search action defect was fixed; zero runtime warnings.
- visionOS 27: 229/229 unit tests; exact-current UI one pass plus one explicit simulator-input skip; generic Debug/Release builds pass.
- visionOS 26.4: 229/229 unit tests; modes/settings app smoke 1/1.
- macOS: exact-current clean Release archive and direct standalone launch; native thin arm64, minimum macOS 26.0, SDK 27.0, zero compiler/analyzer warnings. Immediately preceding unified-host unit suite: 251/251; serialized Mac UI: 2/2 with source-less pre-test XCTest-runner warnings.
- GlasSecretStore: 69/69 at revision `1ffaa96312b8e4b4d6b82eb82cc40c8f6df6317f`.
- RealityKitContent standalone build passed.
- Final diff, project/plist/entitlement, production incomplete-marker, duplicate-entry, orphan-reference, Release-symbol, source-removal, and tracked-diff Gitleaks scans passed.

## Validation Artifacts

- iPhone units: `/tmp/glas-onebase-iphone/Logs/Test/Test-glas.sh-2026.07.25_02-59-28--0500.xcresult`
- iPhone compact UI: `/tmp/glas-onebase-iphone/Logs/Test/Test-glas.sh-2026.07.25_03-10-55--0500.xcresult`
- iPad units: `/tmp/glas-onebase-ipad/Logs/Test/Test-glas.sh-2026.07.25_03-03-00--0500.xcresult`
- iPad UI: `/tmp/glas-onebase-ipad/Logs/Test/Test-glas.sh-2026.07.25_02-38-16--0500.xcresult`
- visionOS 27 units: `/tmp/one-base-final5-vision27-unit/Logs/Test/Test-glas.sh-2026.07.25_00-58-49--0500.xcresult`
- visionOS 27 UI: `/tmp/one-base-final12-vision27-ui-clean/Logs/Test/Test-glas.sh-2026.07.25_03-18-25--0500.xcresult`
- visionOS 26.4 units: `/tmp/one-base-final6-vision264-unit/Logs/Test/Test-glas.sh-2026.07.25_01-26-42--0500.xcresult`
- visionOS 26.4 UI smoke: `/tmp/one-base-final7-vision264-ui/Logs/Test/Test-glas.sh-2026.07.25_01-36-35--0500.xcresult`
- Mac archive: `/tmp/one-base-final2-current-mac-release-20260725.xcarchive`
- Mac archive result: `/tmp/one-base-final2-current-mac-archive-20260725.xcresult`
- Mac launch log: `/tmp/one-base-final2-current-mac-standalone-20260725.log`
- Mac effective entitlements: `/tmp/one-base-final2-current-mac-entitlements-20260725.txt`
- Mac unified-host units: `/tmp/one-base-import-boundary-mac-unit-20260725.xcresult`
- Mac serialized UI: `/tmp/one-base-cleanup-mac-ui-final-20260725.xcresult`

## Approved Evidence Boundaries

- Physical Vision Pro was unavailable for final device interaction and icon inspection.
- The visionOS mutating UI flow is explicitly skipped because Xcode 27 Simulator cannot synthesize scrolling inside the Add Server sheet; the app, populated form, and cleanup remained valid.
- The final Mac hosted XCTest process could not start because SIP-protected stale `testmanagerd` state invalidated its control connection. Exact-current compile/archive/launch pass; the last unified-host suite passed before the final render-boundary-only delta.
- Local strict signature verification reports `CSSMERR_TP_NOT_TRUSTED`; distribution signing/notarization was not claimed.
- Computer Use visual capture and online OSV advisory lookup were unavailable and are not claimed as passes.
- No commit, PR, or merge was created because version-control publication was not separately authorized.
