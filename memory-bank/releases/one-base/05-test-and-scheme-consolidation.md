# Phase 05 — Test and Scheme Consolidation

## Objective

Run every platform from one shared application scheme with one platform-adaptive unit-test target and one platform-adaptive UI-test target.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phases 01–04.

## Primary files

- `glas.sh.xcodeproj/project.pbxproj`
- `glas.sh.xcodeproj/xcshareddata/xcschemes/glas.sh.xcscheme`
- `glas.shTests/*`
- `glas.sh-macTests/MacWorkspaceTests.swift`
- `glas.shUITests/ConnectionLibraryUITests.swift`

Only one agent may edit `project.pbxproj` during this phase.

## Work items

1. Expand `glas.shTests` to support iOS, macOS, and visionOS with SDK-appropriate deployment settings and a unified test host.
2. Add the existing `glas.sh-macTests` source group to `glas.shTests`.
3. Wrap Mac-only test imports and suites in `#if os(macOS)`.
4. Audit shared tests for mobile/vision-only imports and guard only true platform boundaries.
5. Expand `glas.shUITests` to support every application destination.
6. Continue reusing the existing shared UI-test source, which already contains Mac-specific flows.
7. Point one `glas.sh.xcscheme` at:
   - the unified app target;
   - `glas.shTests`;
   - `glas.shUITests`.
8. Keep the old Mac test targets and Mac scheme present but unused until Phase 06.
9. Record pre- and post-consolidation test inventories; no test may disappear silently.

## Required test inventory

- Shared connection, auth, trust, settings, iCloud, theme, terminal engine, and routing tests.
- Mac workspace state, broker, restoration, local PTY, tab, split, and secure-keyboard tests.
- iPhone compact navigation and keyboard tests.
- iPad adaptive navigation and window tests.
- visionOS ornament, focus, terminal, and scene tests.
- Cross-platform Connection Library UI tests.
- Mac Local Terminal and multiwindow UI tests.

## Tests

- Build-for-testing on every supported destination.
- Unit suites on iPhone, iPad, both supported visionOS runtimes, and Apple Silicon Mac.
- UI smokes on iPhone, iPad, visionOS simulator/device where tooling permits, and Mac.
- Verify test bundle host paths and bundle identifiers.
- Compare exact discovered test names against the baseline inventory.

## Rollback

Restore the prior scheme and test-target settings. The duplicate Mac test targets remain available until Phase 06.

## Exit gate

One shared scheme runs one unit-test target and one UI-test target across the supported destination matrix with no lost tests.

## Completion evidence

- The shared `glas.sh` scheme targets the unified app, `glas.shTests`, and `glas.shUITests`; the Mac workspace tests compile inside the shared unit target under macOS guards.
- `xcodebuild -showdestinations` lists My Mac, iPhone/iPad simulators, Vision Pro simulators 26.4/26.5/27, and generic devices beneath the single scheme.
- Exact-current iPhone and iPad unit suites pass 232/232 each; iPad UI passes 2/2 and final iPhone compact smoke passes 1/1.
- visionOS 27 and 26.4 unit suites pass 229/229 each; visionOS 27 UI has one pass and one explicit simulator-input skip, and visionOS 26.4 app smoke passes.
- The immediately preceding unified-host Mac unit suite passed 251/251 and its serialized Mac UI suite passed 2/2. The UI runner emitted one source-less pre-test main-thread warning per test; no application frame was associated.
- Final hosted XCTest was unavailable because protected stale `testmanagerd` state could not be reset; exact-current archive, direct launch, and static product validation pass.
