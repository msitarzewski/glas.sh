# Connection Library Release Program

## Purpose

Build one scalable, native Connection Library for visionOS, macOS, iPadOS, and iOS without replacing the existing connection, session, workgroup, or appearance models.

This release changes how users browse, organize, inspect, and launch connections. It is a presentation and navigation architecture shift, not a domain rewrite.

## Release status

`Complete` — implementation and QA approved by the user on 2026-07-21.

The release delivers one shared transient projection, native visionOS/macOS/iPadOS/iOS shells, authoritative terminal/workgroup routing, iPhone/iPad target support, duplicate-navigation cleanup, and regression coverage. Xcode 27 beta UI-runner finalization and physical Vision Pro developer-disk-image launch capture remain documented tooling limitations; the approval explicitly accepts them without representing either as a passing automated check.

Publication: PR [#29](https://github.com/msitarzewski/glas.sh/pull/29).

## Product invariants

- visionOS remains the reference experience.
- The terminal canvas retains true 100% transparency plus independent tint, opacity, blur, and material controls.
- Window chrome, headers, footers, ornaments, and navigation retain native Apple glass treatment.
- ANSI text renders above the terminal background composition and must not be muted by opacity or blur.
- Tabs, multiwindow behavior, workgroups, themes, local terminals, saved SSH connections, and terminal lifecycle behavior remain intact.
- Apple Silicon and Apple operating systems version 26 or newer are the only supported release platforms.
- Platform parity means shared capability and data, with native presentation on each platform—not identical view trees.

## Preserved baseline

- PR [#28](https://github.com/msitarzewski/glas.sh/pull/28), `Add terminal workgroups and lifecycle polish`, was merged to `main` on 2026-07-20 before this release branch began.
- The preserved checkpoint passed macOS 27/27 tests, complete visionOS 26.4 and visionOS 27 suites, GlasSecretStore 76/76 tests, macOS arm64 Release, generic visionOS Release, `git diff --check`, and the production marker scan.
- Release work begins on `agent/connection-library` from merge commit `f3f00c3b`.

## Existing architecture to reuse

| Capability | Authoritative source | Release use |
|---|---|---|
| Saved profiles | `glas.sh/Models.swift:67`, `glas.sh/ServerManager.swift` | Connections and connection details |
| Collections | `glas.sh/Models.swift:81` (`ServerConfiguration.tags`) | Derived scopes; no second collection database |
| Favorites and recents | `glas.sh/Models.swift` (`ServerConfiguration.isFavorite`, `lastConnected`), `glas.sh/ConnectionLibrary.swift:85` | Built-in Library scopes |
| Workgroup recipes | `glas.sh/Models.swift:2551`, `glas.sh/SettingsManager.swift:175` | Workgroups scope and launch action |
| Live workgroups | `glas.sh/Models.swift:2543`, `glas.sh/SessionManager.swift:32` | Runtime terminal window/tab state |
| Connection launch | `glas.sh/SessionManager.swift` | The only launch authority |
| Optional network source | `glas.sh/TailscaleClient.swift` | Visible only when configured |
| Current hub | `glas.sh/ConnectionManagerView.swift:12` | Refactor and reduce; do not build a parallel hub |
| App scenes | `glas.sh/glas_shApp.swift:12` | Route platform-native library and terminal windows |

## Reuse and file policy

The implementation must extend the sources above. It must not introduce a second persisted connection model, collection store, workgroup store, session opener, or platform-specific copy of domain behavior.

One new production source file, `glas.sh/ConnectionLibrary.swift`, is conditionally approved for transient projection, scope, selection, and routing state. It is justified only because that state is not persisted domain data, settings, or session lifecycle, and adding it to the already monolithic `ConnectionManagerView.swift` would deepen the problem this release is intended to solve. If existing types can own the state cleanly during implementation, the file should not be created.

## Experience model

```text
ServerManager ------ profiles / favorites / recents / tags
SettingsManager ---- workgroup recipes
TailscaleClient ---- optional configured network source
SessionManager ----- terminal and workgroup launch
          |
          v
Connection Library projection
mode -> scope -> filtered connection -> selected detail
          |
          v
visionOS / macOS / iPadOS / iOS native shells
```

Top-level modes are:

- Library
- Favorites
- Recent
- Collections
- Workgroups
- Network, only when configured
- Settings, as navigation rather than connection content

Collections are normalized views over profile tags. A collection exists when at least one saved profile belongs to it. Workgroups remain launch recipes and do not become connection folders.

## Platform composition

- visionOS: ornaments select top-level modes. Modes with real children, currently Collections, show a child-scope column before results and details; modes without children begin with results. The ornament and first in-window column never duplicate the same hierarchy.
- macOS: native three-column library with sidebar, results, and details; double-click may connect while single-click selects.
- iPadOS: adaptive split view using the same mode, scope, result, and detail semantics.
- iOS: navigation stack that drills from mode/scope to results to details.
- Every Connections results column has a discoverable `+` action.

## Launch semantics

- `Connect` from the Library opens a new terminal window or workgroup and leaves the Library open.
- A workgroup opens its configured command-per-tab recipe through the existing session/workgroup path.
- `Command-T` and the terminal footer `+` add a tab inside the active terminal window.
- Local Terminal remains a first-class, one-action launch path on macOS. Unsupported local-terminal intents on visionOS/iOS fail visibly rather than pretending to open a local PTY.
- Mac row double-click may connect; other row selection only reveals details.

## Status vocabulary

| Status | Meaning |
|---|---|
| `Not started` | No implementation work has begun. |
| `In progress` | Work exists but the phase exit gate has not passed. |
| `Blocked` | Progress requires a documented decision or unavailable dependency. |
| `QA` | Implementation is complete and evidence is being gathered. |
| `Complete` | Acceptance criteria, tests, cleanup, and documentation have passed. |
| `Deferred` | The user approved movement to a named later release. |

## Program dashboard

| Phase | Milestone | Status | Depends on | Exit gate |
|---|---|---|---|---|
| [00](./00-baseline-and-governance.md) | Baseline and governance | Complete | None | Historical checkpoint merged; architecture, reuse rules, and release gates recorded |
| [01](./01-shared-library-projection.md) | Shared Library projection | Complete | 00 | Deterministic modes, scopes, counts, filtering, and selection pass unit tests |
| [02](./02-connection-hub-refactor.md) | Connection hub refactor | Complete | 01 | Existing hub uses the shared projection and no longer duplicates hosts or navigation state |
| [03](./03-native-platform-shells.md) | Native platform shells | Complete | 02 | visionOS, macOS, iPadOS, and iOS implement the approved hierarchy natively |
| [04](./04-terminal-routing-and-cleanup.md) | Terminal routing and cleanup | Complete | 02, 03 | Connect, workgroup, local, tab, and window routes use existing authorities; displaced code is removed |
| [05](./05-ios-ipados-enablement.md) | iPhone and iPad enablement | Complete | 01, 03, 04 | Existing primary app architecture builds and operates on iPhone/iPad 26+ without a parallel product core |
| [06](./06-validation-and-release.md) | Validation and release | Complete | 01–05 | Cross-platform function, unit, build, direct-app, security, regression, and orphan-code gates pass; accepted tooling limits are recorded |

## Canonical release ledger

| ID | Requirement | Owner | Status |
|---|---|---|---|
| `LIB-001` | Project one deduplicated list from authoritative saved profiles | 01 | Complete |
| `LIB-002` | Derive All, Favorites, Recent, Collections, Workgroups, and optional Network scopes | 01 | Complete |
| `LIB-003` | Hide Network when credentials are not configured | 01 | Complete |
| `LIB-004` | Preserve selection across safe filter/projection updates | 01 | Complete |
| `HUB-001` | Replace duplicate macOS Favorites/Recent/All host sections | 02 | Complete |
| `HUB-002` | Provide a results-column `+` action on every platform | 02 | Complete |
| `HUB-003` | Preserve search, Quick Connect, trust, add, edit, delete, and favorite flows | 02 | Complete |
| `UX-001` | Use ornament modes without duplicating them in the visionOS window | 03 | Complete |
| `UX-002` | Provide native three-column macOS and adaptive iPadOS presentation | 03 | Complete |
| `UX-003` | Provide compact iPhone drill-down navigation | 03 | Complete |
| `ROUTE-001` | Library Connect opens a new terminal window and keeps the Library open | 04 | Complete |
| `ROUTE-002` | Workgroups launch existing command-per-tab recipes | 04 | Complete |
| `ROUTE-003` | Terminal `+` and Command-T add a tab to the active terminal window | 04 | Complete |
| `CLEAN-001` | Remove replaced branches, flags, scene routes, and abandoned view code | 04 | Complete |
| `IOS-001` | Extend the existing primary target to iPhone/iPad 26+ when SDK evidence permits | 05 | Complete |
| `QA-001` | Preserve all terminal appearance and ANSI rendering invariants | 06 | Complete |
| `QA-002` | Pass macOS, visionOS 26/27, iPhone, iPad, and package validation | 06 | Complete with accepted tooling limits recorded in Phase 06 |
| `QA-003` | Finish with production TODO/stub/orphan and security scans | 06 | Complete |

## Release acceptance criteria

- Every saved host appears once in the active result set.
- Modes and scopes filter results without duplicate rows or duplicate navigation levels.
- visionOS hierarchy is ornament -> optional real child scopes -> results -> details; modes without children begin with results.
- Collections organize profiles; workgroups launch recipes.
- Network is absent when unconfigured and useful when configured.
- A `+` action is present in the Connections results column on every platform.
- Library Connect opens a new terminal window; terminal `+` opens a tab.
- Transparency, tint, blur, materials, themes, ANSI color, tabs, local terminals, and workgroups retain current behavior.
- The new implementation replaces displaced code instead of living beside it.
- Duplicate connection-navigation state and host projections are removed; raw native-shell presentation growth is measured and documented rather than represented as a smaller source file.
- Current suites pass on Apple Silicon macOS 27, visionOS 26.4 and 27, and iOS 27; generic Release builds pass with platform deployment floors at version 26.

## Change-control rule

If unavailable APIs or target membership make a universal iOS/visionOS app target unsafe, implementation stops at that boundary and returns with concrete compiler/SDK evidence before creating a second target. No speculative parallel app architecture is authorized by this plan.

## Completion evidence summary

- App suites: iOS 27 211/211; visionOS 26.4 208/208; visionOS 27 208/208; Apple Silicon macOS 27 32/32.
- Packages: GlasSecretStore 76 passed; swift-nio-ssh 331/331; Citadel executed 44 with 39 passed and five environment skips; RealityKitContent build passed.
- Release builds: exact-current-tree Apple Silicon macOS, generic iOS, and generic visionOS passed.
- Direct application smokes: macOS Library/local-terminal route, iPhone compact Library, and iPad three-column Library passed.
- Physical Vision Pro: signed build and installation passed; CoreDevice launch/render capture limitation is recorded in [Phase 06](./06-validation-and-release.md).
- Final diff, project/scheme validation, production marker, orphan symbol, and Gitleaks scans passed.
