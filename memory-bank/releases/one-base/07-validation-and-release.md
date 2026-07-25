# Phase 07 — Validation and Release

## Objective

Prove that One Base reduces build architecture without changing product behavior, data availability, security, terminal fidelity, or native platform experience.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phases 01–06.

## Build matrix

- Generic iOS Debug and Release.
- iPhone 27 simulator Debug, unit, and UI.
- iPadOS 27 simulator Debug, unit, and UI.
- Generic visionOS Debug and Release.
- visionOS 26.x simulator unit and app smoke.
- visionOS 27 simulator unit and app smoke.
- Signed physical Vision Pro build/install/launch when tooling permits.
- Apple Silicon macOS 27 Debug, Release, unit, UI, archive, and direct launch.
- RealityKitContent, Citadel, swift-nio-ssh, and GlasSecretStore package gates when touched or resolution changes.

## Functional matrix

- Connection Library modes, scopes, search, add/edit/delete, favorites, recents, collections, workgroups, and optional Network.
- Local Terminal on Mac.
- Saved SSH with password, imported key, hardware-protected key, and supported compatibility algorithms.
- Host-trust prompt, persistence, replacement, and rejection.
- Multiple windows, native tabs, splits, Command-T, footer/toolbar new-tab actions, and clean shell exit.
- iPhone compact session switcher and keyboard dismissal/cursor scrub.
- iPad adaptive tabs and windowing.
- Vision Pro ornaments, focus ownership, terminal rendering, and physical keyboard behavior.
- Terminal themes, ANSI normal/bright colors, cursor, selection, padding, resize, scrollback, opacity, tint, blur, and true zero-opacity/zero-blur endpoint.
- SFTP, port forwarding, recordings, snippets, AI actions, HTML Preview debug route, settings, and workgroup command recipes.
- iCloud theme/settings sync and shared GlasSecretStore credential visibility.
- Widget operation on supported destinations and absence from Mac.

## Migration and identity matrix

- Existing `sh.glas.mac` development preferences are either migrated safely or have a user-approved disposition supported by evidence.
- Shared defaults remain readable and writable.
- Keychain accounts and access groups remain unchanged.
- No secret source is deleted during migration.
- Bundle identifiers, URL schemes, KVS identifiers, application groups, Keychain groups, deployment targets, and architectures match the release plan.

## Product and signing inspection

- Inspect built Info.plists.
- Inspect effective signed entitlements.
- Verify arm64 Mac executable.
- Verify no Catalyst runtime or Catalyst build setting.
- Inspect application and widget bundle contents.
- Verify icons on each platform.
- Produce one Xcode destination-menu screenshot showing Mac, iPhone, iPad, and Vision Pro under `glas.sh`.

## Quality gates

- `git diff --check`.
- Compiler warnings reviewed and assigned dispositions.
- Unit/UI test failures: zero, except explicitly user-approved external tooling limitations.
- Production TODO/FIXME/HACK/stub/future/unimplemented/fatal marker scan.
- Orphan source, target, scheme, product, bundle-ID, and scene-route scan.
- Gitleaks on the complete tracked diff.
- No mock data or production stubs.
- No duplicated `@main`, application target, application scheme, or test-host authority.
- Compare source and test inventories with baseline; every removal has an explicit replacement or obsolete justification.

## Documentation gate

After user approval of implementation:

- update this dashboard and every phase status/evidence;
- update `memory-bank/systemPatterns.md` with the one-target/native-platform boundary;
- supersede the separate-Mac-target decision in `memory-bank/decisions.md`;
- update `memory-bank/activeContext.md`, `progress.md`, and `toc.md`;
- create the approved completion task record;
- link the commit, PR, merge, archives, result bundles, and screenshots.

## Exit gate

One native app target and one app scheme build, run, test, sign, and archive across Mac, iPhone, iPad, and Vision Pro; preserved product behavior and data pass; obsolete architecture and incomplete code are absent; and the user approves release completion.

## Final QA evidence

- iPhone iOS 27: 232/232 unit tests and final compact settings/network UI smoke 1/1, with zero runtime warnings.
- iPadOS 27: 232/232 unit tests and full UI 2/2, with zero runtime warnings.
- visionOS 27: 229/229 unit tests; UI completed with one functional pass and one explicit simulator-input skip; generic Debug and Release builds pass.
- visionOS 26.4: 229/229 unit tests and modes/settings application smoke 1/1.
- macOS: fresh exact-current Release archive and standalone launch pass with zero compiler/analyzer warnings; binary is native arm64, minimum macOS 26.0, SDK 27. The immediately preceding unified-host suite passed 251/251.
- GlasSecretStore 69/69 and RealityKitContent standalone build pass.
- Built product inspection confirms `sh.glas.app`, `sh.glas.app.glasWidgets`, correct shared entitlements, no Catalyst, correct extension filtering, correct resources, and no Release debug-cleanup symbols.
- Final `git diff --check`, project/plist/entitlement parsing, incomplete-marker, duplicate-entry, orphan-reference, source-removal, and tracked-diff Gitleaks scans pass.

## Approved dispositions

- Physical Vision Pro was unavailable for the final pass; simulator 26.4/27, generic products, and bundle/signing inspection are the accepted evidence boundary.
- The skipped visionOS mutation test is limited to Xcode 27 Simulator scroll synthesis in the Add Server sheet. The test documents the skip at its call site and verifies the app/form/cleanup state before skipping.
- The final Mac hosted test service remained blocked by SIP-protected stale `testmanagerd`. This does not replace the passing 251-test unified-host result; exact-current archive, launch, and static product checks cover the final render-boundary-only delta.
- Strict local signing verification reports only `CSSMERR_TP_NOT_TRUSTED`; signature structure and effective entitlements are valid.
- Computer Use visual capture was unavailable because Sky service startup failed; destination inventory is preserved from `xcodebuild -showdestinations`.
- No online OSV query was made because dependency metadata would leave the workstation and no offline database was present.

## Documentation completion

- The dashboard and all phase evidence are current.
- `memory-bank/systemPatterns.md`, `decisions.md`, `activeContext.md`, `progress.md`, and `toc.md` record the unified-target architecture and completion.
- Completion task record: `memory-bank/tasks/2026-07/250726_one-base-release.md`.
- Publication commits: `904ae0af` and `47b23f12`.
- Pull request and canonical merge-status record: [#30 — Unify glas.sh with One Base](https://github.com/msitarzewski/glas.sh/pull/30).
- No destination screenshot or externally hosted archive was created; local artifact paths and the accepted Computer Use limitation remain recorded above.
