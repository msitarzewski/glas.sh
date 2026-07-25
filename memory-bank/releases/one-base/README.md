# One Base Release Program

## Purpose

Unify glas.sh behind one native multiplatform application target, one application product identity, and one primary Xcode scheme, following the proven glassdb structure without replacing the existing platform-native terminal implementations.

This release is build-architecture consolidation. It must reduce duplicated target, scheme, test-host, entitlement, resource, and application-scene configuration while preserving native AppKit, UIKit, and visionOS behavior.

## Release status

`Complete` — implementation and QA approved 2026-07-25.

## Preserved baseline

- Branch: `agent/connection-library`.
- Commit: `c9f7a406`, `Complete native connection library and terminal polish`.
- The commit preserves the completed Connection Library, native terminal navigation, cursor scrub accessory, focus ownership, iCloud/shared-secret changes, and GitHub GlasSecretStore transition.
- `default.profraw` is a generated untracked coverage artifact and is outside the release baseline.
- The historical separate `glas.sh Mac` target is preserved by baseline commit `c9f7a406`; Phase 06 removed it from the current project after the unified target passed.
- Publication branch: `agent/one-base`.

## Product invariants

- visionOS remains the reference terminal experience.
- The terminal canvas retains true 100% transparency and independent tint, opacity, blur, and material controls.
- ANSI glyph color is composited above background effects.
- macOS remains a native AppKit/SwiftUI application, not Catalyst.
- Local PTY, native Mac tabs, splits, secure keyboard entry, commands, and multiwindow behavior remain intact.
- iPhone uses compact native navigation; iPad uses native adaptive windowing and tabs.
- Credentials and host trust continue through GlasSecretStore and the shared Keychain access group.
- Shared servers, SSH-key metadata, host trust, themes, workgroups, and iCloud settings must not be stranded by product-identity changes.
- The widget remains a separate extension target because an extension is a separate binary; it must not create a second application scheme.
- Supported release hardware remains Apple Silicon on Apple operating systems version 26 or newer.

## Reference implementation

glassdb proves the desired Xcode model:

- one native application target;
- `SDKROOT = auto`;
- iOS, macOS, and visionOS in `SUPPORTED_PLATFORMS`;
- `SUPPORTS_MACCATALYST = NO`;
- one `@main` application with platform-specific scene composition;
- SDK-conditional Info.plist, entitlement, and icon settings.

## Existing architecture to reuse

| Capability | Authoritative source | One Base use |
|---|---|---|
| Primary app target | `glas.sh.xcodeproj/project.pbxproj` target `glas.sh` | Extend to macOS; do not create another target |
| Platform scenes | `glas.sh/glas_shApp.swift`, `glas.sh-mac/glas_shMacApp.swift` | Consolidate into one `@main` app |
| Mac workspace | `glas.sh-mac/MacWorkspace*.swift` | Preserve behind `#if os(macOS)` |
| Local PTY | `glas.sh-mac/MacLocalTerminalPaneView.swift`, RealityKitContent | Preserve unchanged in behavior |
| Shared app core | `glas.sh/*.swift` | Continue compiling on every supported destination |
| Secrets and trust | GlasSecretStore, `glas.sh/KeychainManager.swift` | Preserve shared access-group authority |
| Shared defaults | `glas.sh/Constants.swift` (`SharedDefaults`) | Preserve data and audit old Mac preference domain |
| App resources | `glas.sh/Assets.xcassets`, `glas.sh-mac/AppIcon.icon` | Select by SDK without recreating artwork |
| Widget | `glasWidgets` target | Keep as one platform-filtered extension |
| Unit tests | `glas.shTests`, `glas.sh-macTests` | Consolidate under one test host |
| UI tests | shared `glas.shUITests` sources | Remove duplicate Mac UI-test target |
| Primary scheme | `glas.sh.xcscheme` | Become the only application scheme |

## Reuse and file policy

- No new production or test source file is planned.
- Extend the existing primary app, test, UI-test, widget, and scheme objects.
- Keep the `glas.sh-mac` folder as a platform implementation boundary; a folder is not a second app product.
- Do not rewrite Mac workspaces or terminal scenes during target consolidation.
- Remove old targets only after the new target passes every supported destination.
- A new source file requires a fresh reuse analysis and explicit approval.

## Target outcome

```text
glas.sh scheme
    |
    v
glas.sh application target (SDKROOT = auto, Catalyst = NO)
    |-- iPhone / iPad native scenes
    |-- visionOS native scenes and ornaments
    `-- macOS native AppKit/SwiftUI scenes and local PTY

glas.shTests    ---- one platform-adaptive unit-test target
glas.shUITests  ---- one platform-adaptive UI-test target
glasWidgets     ---- separate extension, embedded only where supported
```

## Agent coordination

- Each phase has one owner and one status; owners update evidence before handoff.
- `glas.sh.xcodeproj/project.pbxproj` is a serialized integration file. Only one agent may edit it at a time.
- Agents may inspect or test in parallel, but project-file patches land sequentially.
- Every phase begins from a passing previous-phase commit and ends with a focused commit or an explicit rollback.
- Do not delete the fallback targets or scheme before Phase 06.
- Record exact commands, destinations, test counts, warnings, and artifacts in the owning phase file.

## Status vocabulary

| Status | Meaning |
|---|---|
| `Planned` | Scope and exit gates exist; implementation has not begun. |
| `In progress` | An owner is actively implementing the phase. |
| `Blocked` | A documented decision or external dependency is required. |
| `QA` | Implementation is complete and evidence is being gathered. |
| `Complete` | Exit gate and evidence requirements passed. |
| `Rolled back` | Phase changes were removed and the previous passing commit restored. |
| `Deferred` | The user approved movement to a named later release. |

## Program dashboard

| Phase | Milestone | Status | Owner | Depends on | Exit gate |
|---|---|---|---|---|---|
| [00](./00-baseline-and-governance.md) | Baseline and governance | Complete | Codex | None | Baseline commit, reuse map, sequencing, and rollback rules recorded |
| [01](./01-primary-target-expansion.md) | Primary target expansion | Complete | Codex agent team | 00 | Existing primary target builds native macOS while fallback target remains |
| [02](./02-app-scene-consolidation.md) | App and scene consolidation | Complete | Codex agent team | 01 | One `@main` app composes native scenes for all platforms |
| [03](./03-product-identity-and-platform-config.md) | Product identity and platform configuration | Complete | Codex agent team | 02 | One bundle identity with correct SDK-specific plist, entitlements, and preserved data |
| [04](./04-resources-icons-and-widget.md) | Resources, icons, and widget | Complete | Codex agent team | 03 | Correct platform icons/resources and platform-filtered widget embedding |
| [05](./05-test-and-scheme-consolidation.md) | Tests and scheme | Complete | Codex agent team | 01–04 | One app scheme, one unit-test target, and one UI-test target cover every platform |
| [06](./06-obsolete-target-retirement.md) | Retire duplicate targets | Complete | Codex agent team | 05 | Old Mac app/test targets and scheme are absent with no orphan project objects |
| [07](./07-validation-and-release.md) | Validation and release | Complete | Codex agent team | 01–06 | Cross-platform build, function, unit, UI, signing, migration, and cleanup gates pass |

## Canonical release ledger

| ID | Requirement | Phase | Status |
|---|---|---|---|
| `BASE-001` | Preserve commit `c9f7a406` as the rollback baseline | 00 | Complete |
| `TGT-001` | One native application target supports iOS, iPadOS, macOS, and visionOS | 01 | Complete |
| `TGT-002` | Use automatic SDK selection with Catalyst disabled | 01 | Complete |
| `TGT-003` | Keep macOS Apple Silicon-only | 01 | Complete |
| `SCENE-001` | Exactly one `@main` application composes platform-native scenes | 02 | Complete |
| `SCENE-002` | Preserve Mac local PTY, workspaces, tabs, splits, and commands | 02 | Complete |
| `ID-001` | Use one application bundle identity across platforms | 03 | Complete |
| `ID-002` | Preserve shared secrets, trust, servers, settings, and workgroups | 03 | Complete |
| `CFG-001` | Select Info.plist and entitlements by SDK | 03 | Complete |
| `RES-001` | Reuse existing iOS/visionOS and Mac icon assets without collisions | 04 | Complete |
| `WID-001` | Keep the widget separate and embed it only on supported platforms | 04 | Complete |
| `TEST-001` | One unit-test target runs platform-appropriate tests | 05 | Complete |
| `TEST-002` | One UI-test target runs against the unified app | 05 | Complete |
| `SCH-001` | One shared `glas.sh` application scheme exposes every destination | 05 | Complete |
| `CLEAN-001` | Remove duplicate app/test targets, products, dependencies, and scheme | 06 | Complete |
| `QA-001` | Xcode destination picker shows Mac, iPhone, iPad, and Vision Pro | 07 | Complete |
| `QA-002` | Debug, Release, unit, UI, function, and signing matrices pass | 07 | Complete |
| `QA-003` | TODO/stub/orphan/secret/project-consistency scans pass | 07 | Complete |

## Completion evidence

- One native `glas.sh` app target now supports iPhone, iPad, visionOS, and native Apple Silicon macOS; Catalyst is disabled. The widget and two test bundles remain separate binaries.
- One `@main` application composes the existing platform-native scene graphs. Mac local PTY, workspaces, tabs, splits, secure keyboard entry, commands, and multiwindow behavior remain in the retained `glas.sh-mac` platform source boundary.
- The application identity is `sh.glas.app` on every app platform. SDK-specific plist, entitlements, and icons preserve the shared app group, Keychain group, iCloud KVS namespace, GlassSecretStore authority, and native Mac icon.
- The shared `glas.sh` scheme exposes My Mac, iPhone, iPad, and Vision Pro destinations. The obsolete Mac app/test targets and `glas.sh Mac` scheme are absent.
- Exact-current iPhone and iPad unit suites passed 232/232 each. iPad UI passed 2/2; final compact iPhone UI smoke passed 1/1.
- visionOS 27 and 26.4 unit suites passed 229/229 each. visionOS 27 UI completed with one pass and one explicit simulator-input skip; visionOS 26.4 app smoke passed.
- A fresh exact-current Mac Release archive and direct standalone launch passed with zero compiler/analyzer warnings. The immediately preceding unified-host Mac suite passed 251/251; final hosted XCTest was blocked by a protected stale `testmanagerd`, while exact-current archive, launch, and static product inspection passed.
- GlasSecretStore passed 69/69 from revision `1ffaa96312b8e4b4d6b82eb82cc40c8f6df6317f`. RealityKitContent built successfully.
- Final project/plist/entitlement parsing, diff, production incomplete-marker, orphan target/scheme/product, duplicate `@main`, release-symbol, and tracked-diff Gitleaks scans passed.

## Approved evidence boundaries

- No physical Vision Pro was available for the final exact-current pass. Both visionOS simulator runtimes, generic Debug/Release products, signing metadata, and application smokes were verified.
- Xcode 27 Vision Simulator cannot synthesize the scroll required to finish the mutating Add Server sheet flow. That test is explicitly skipped only on visionOS; the nonmutating UI smoke passes and the app remains live with form data and cleanup verified.
- The final Mac hosted XCTest service could not be reset because SIP protects its stale `testmanagerd` state. The last unified-host suite passed 251/251 before the final render-boundary-only change; exact-current compilation, archive, direct launch, and product inspection pass.
- Local strict signature validation reports only `CSSMERR_TP_NOT_TRUSTED`, reflecting the untrusted local development certificate chain rather than a malformed signature.
- Computer Use visual capture was unavailable because its Sky service did not start. `xcodebuild -showdestinations` supplied the destination inventory instead.
- OSV online dependency scanning was not run because it would transmit dependency metadata and no offline database was available. Package tests, pinned resolution, Gitleaks, and static security review passed.
- The plan called for a commit at every phase boundary, but implementation remained one reviewable release diff after baseline `c9f7a406`. The approved release accepts that governance variance; no phase history was fabricated.

## Publication

- Post-Connection-Library polish commit: `904ae0af`.
- One Base implementation and release documentation commit: `47b23f12`.
- Pull request: [#30 — Unify glas.sh with One Base](https://github.com/msitarzewski/glas.sh/pull/30).
- The pull request is the canonical merge-status record.

## Release acceptance criteria

- Xcode shows one `glas.sh` app scheme with Mac, iPhone, iPad, and Vision Pro destinations.
- The project contains one application target, plus the necessary widget and test targets.
- Mac is native and `SUPPORTS_MACCATALYST` remains disabled.
- One bundle identity is used across application platforms.
- Each platform launches its existing native experience without losing features.
- GlasSecretStore credentials, host trust, shared defaults, themes, settings, and workgroups remain available.
- The Mac Dock icon and iOS/visionOS icons are correct.
- The widget embeds only where supported.
- Unit and UI test inventories are equal to or larger than their pre-consolidation totals.
- No duplicate `@main`, target, scheme, Info.plist authority, or abandoned project object remains.
- Product transparency, ANSI color, terminal focus, keyboard, tab, local PTY, SSH, and workgroup invariants pass regression testing.

## Change-control rule

If the primary target cannot build one platform because of a concrete SDK, extension, signing, or source-membership limitation, stop at that phase and record the compiler or signing evidence. Do not recreate another app target, switch to Catalyst, duplicate source, or delete the fallback target without explicit user approval.
