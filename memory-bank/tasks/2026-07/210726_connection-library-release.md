# 210726_connection-library-release

## Objective

Complete the Connection Library release: one deterministic projection over existing saved profiles, tags, favorites, recents, workgroup recipes, and optional Network data, presented natively on visionOS, macOS, iPadOS, and iOS without creating a parallel product core.

## Outcome

- ✅ Shared transient projection with normalized collections, deterministic ordering, filtering, counts, and selection repair.
- ✅ Native visionOS ornament hierarchy, macOS/iPadOS three-column shells, and compact iPhone drill-down.
- ✅ Authoritative saved SSH, local terminal, workgroup, tab, settings, and SFTP routing.
- ✅ iPhone/iPad support through the existing primary target and shared managers.
- ✅ Replaced duplicate navigation state and obsolete favorites/recents helper projections removed.
- ✅ Tests: iOS 27 211/211, visionOS 26.4 208/208, visionOS 27 208/208, Apple Silicon macOS 27 32/32.
- ✅ Packages: GlasSecretStore 76 passed, swift-nio-ssh 331/331, Citadel executed 44 with 39 passed and five environment skips, RealityKitContent build passed.
- ✅ Exact-current-tree Release builds passed for Apple Silicon macOS, generic iOS, and generic visionOS.
- ✅ Direct application smokes passed on Mac, iPhone, and iPad; physical Vision Pro signed build and installation passed.
- ✅ Final diff, project/scheme, production marker, orphan-symbol, and Gitleaks scans passed.

## Files Modified

- `glas.sh/ConnectionLibrary.swift` — shared transient Library modes, scopes, collection/workgroup projection, filtering, ordering, counts, and selection repair.
- `glas.sh/ConnectionManagerView.swift` — shared hub state plus native platform shells, detail/actions, adaptive rows, and cached Network visibility.
- `glas.sh/glas_shApp.swift` — shared iOS/visionOS entry and scene-local compact router.
- `glas.sh/TerminalWindowView.swift`, `glas.sh/VisionTerminalWorkgroupView.swift` — authoritative terminal/workgroup routing integration.
- `glas.sh-mac/MacWorkspaceController.swift`, `glas.sh-mac/MacWorkspaceState.swift` — Mac workspace route integration and restoration behavior.
- `glas.sh/TailscaleClient.swift`, `glas.sh/SettingsView.swift`, `glas.sh/ServerFormViews.swift` — explicit Network credential state and preserved configuration/import flows.
- `glas.sh.xcodeproj/project.pbxproj` and shared schemes — iPhone/iPad and cross-platform UI-test target support.
- `glas.shTests/glas_shTests.swift`, `glas.sh-macTests/MacWorkspaceTests.swift`, `glas.shUITests/ConnectionLibraryUITests.swift` — projection, routing, platform, and end-to-end regression coverage.

## Patterns Applied

- `memory-bank/systemPatterns.md#Connection-Library-Projection-and-Native-Shell-Boundary`
- `memory-bank/systemPatterns.md#Terminal-Architecture`
- Existing single-authority manager pattern: `ServerManager` owns profiles, `SettingsManager` owns recipes, and `SessionManager` owns connection/session opening.

## Integration Points

- `ConnectionManagerView` creates one `ConnectionLibraryProjection` per body evaluation from authoritative manager inputs.
- Platform shells consume the same projection and selection semantics; only navigation composition varies.
- Connect/local/workgroup actions cross the existing scene boundary after `SessionManager` creates or prepares their sessions.
- Tailscale credential presence is cached outside SwiftUI render evaluation and refreshed at lifecycle/configuration boundaries.

## Architectural Decisions

- Collections remain normalized tag projections, not a second persisted collection database.
- Workgroups remain recipes/runtime session groups, not connection folders.
- Platform parity means shared capabilities and domain state with native presentation.
- A raw line-count increase in the shared hub is accepted for explicit native shell composition; duplicated domain/navigation state was removed.
- Xcode 27 beta UI-runner finalization and CoreDevice developer-disk-image launch capture are recorded as approved tooling limitations, not passing automated checks.

## Validation Artifacts

- `/tmp/glas-connection-library-final-iphone-tests.xcresult`
- `/tmp/glas-connection-library-final-vision-tests.xcresult`
- `/tmp/glas-connection-library-final-vision264-tests.xcresult`
- `/tmp/glas-connection-library-final-mac-tests.xcresult`
- `/tmp/glas-ipad-row-fix.png`
- `memory-bank/releases/connection-library/06-validation-and-release.md`
