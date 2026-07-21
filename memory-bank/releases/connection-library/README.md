# Connection Library Release Program

## Purpose

Build one scalable, native Connection Library for visionOS, macOS, iPadOS, and iOS without replacing the existing connection, session, workgroup, or appearance models.

This release changes how users browse, organize, inspect, and launch connections. It is a presentation and navigation architecture shift, not a domain rewrite.

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
| Favorites and recents | `glas.sh/ServerManager.swift:374` | Built-in Library scopes |
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

- visionOS: ornaments select top-level modes; the first in-window column shows scopes or children, the second shows results, and the third shows details. The ornament and first column must never duplicate the same hierarchy.
- macOS: native three-column library with sidebar, results, and details; double-click may connect while single-click selects.
- iPadOS: adaptive split view using the same mode, scope, result, and detail semantics.
- iOS: navigation stack that drills from mode/scope to results to details.
- Every Connections results column has a discoverable `+` action.

## Launch semantics

- `Connect` from the Library opens a new terminal window or workgroup and leaves the Library open.
- A workgroup opens its configured command-per-tab recipe through the existing session/workgroup path.
- `Command-T` and the terminal footer `+` add a tab inside the active terminal window.
- Local Terminal remains a first-class, one-action launch path.
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
| [01](./01-shared-library-projection.md) | Shared Library projection | Not started | 00 | Deterministic modes, scopes, counts, filtering, and selection pass unit tests |
| [02](./02-connection-hub-refactor.md) | Connection hub refactor | Not started | 01 | Existing hub uses the shared projection and no longer duplicates hosts or navigation state |
| [03](./03-native-platform-shells.md) | Native platform shells | Not started | 02 | visionOS, macOS, iPadOS, and iOS implement the approved hierarchy natively |
| [04](./04-terminal-routing-and-cleanup.md) | Terminal routing and cleanup | Not started | 02, 03 | Connect, workgroup, local, tab, and window routes use existing authorities; displaced code is removed |
| [05](./05-ios-ipados-enablement.md) | iPhone and iPad enablement | Not started | 01, 03, 04 | Existing primary app architecture builds and operates on iPhone/iPad 26+ without a parallel product core |
| [06](./06-validation-and-release.md) | Validation and release | Not started | 01–05 | Cross-platform function, unit, UI, security, regression, and orphan-code gates pass |

## Canonical release ledger

| ID | Requirement | Owner | Status |
|---|---|---|---|
| `LIB-001` | Project one deduplicated list from authoritative saved profiles | 01 | Not started |
| `LIB-002` | Derive All, Favorites, Recent, Collections, Workgroups, and optional Network scopes | 01 | Not started |
| `LIB-003` | Hide Network when credentials are not configured | 01 | Not started |
| `LIB-004` | Preserve selection across safe filter/projection updates | 01 | Not started |
| `HUB-001` | Replace duplicate macOS Favorites/Recent/All host sections | 02 | Not started |
| `HUB-002` | Provide a results-column `+` action on every platform | 02 | Not started |
| `HUB-003` | Preserve search, Quick Connect, trust, add, edit, delete, and favorite flows | 02 | Not started |
| `UX-001` | Use ornament modes without duplicating them in the visionOS window | 03 | Not started |
| `UX-002` | Provide native three-column macOS and adaptive iPadOS presentation | 03 | Not started |
| `UX-003` | Provide compact iPhone drill-down navigation | 03 | Not started |
| `ROUTE-001` | Library Connect opens a new terminal window and keeps the Library open | 04 | Not started |
| `ROUTE-002` | Workgroups launch existing command-per-tab recipes | 04 | Not started |
| `ROUTE-003` | Terminal `+` and Command-T add a tab to the active terminal window | 04 | Not started |
| `CLEAN-001` | Remove replaced branches, flags, scene routes, and abandoned view code | 04 | Not started |
| `IOS-001` | Extend the existing primary target to iPhone/iPad 26+ when SDK evidence permits | 05 | Not started |
| `QA-001` | Preserve all terminal appearance and ANSI rendering invariants | 06 | Not started |
| `QA-002` | Pass macOS, visionOS 26/27, iPhone, iPad, and package validation | 06 | Not started |
| `QA-003` | Finish with production TODO/stub/orphan and security scans | 06 | Not started |

## Release acceptance criteria

- Every saved host appears once in the active result set.
- Modes and scopes filter results without duplicate rows or duplicate navigation levels.
- visionOS hierarchy is ornament -> scope/children -> results -> details.
- Collections organize profiles; workgroups launch recipes.
- Network is absent when unconfigured and useful when configured.
- A `+` action is present in the Connections results column on every platform.
- Library Connect opens a new terminal window; terminal `+` opens a tab.
- Transparency, tint, blur, materials, themes, ANSI color, tabs, local terminals, and workgroups retain current behavior.
- The new implementation replaces displaced code instead of living beside it.
- Net connection-navigation complexity decreases.
- macOS 26+ arm64, visionOS 26 and 27, iPhone/iPad 26+, package tests, and release builds pass.

## Change-control rule

If unavailable APIs or target membership make a universal iOS/visionOS app target unsafe, implementation stops at that boundary and returns with concrete compiler/SDK evidence before creating a second target. No speculative parallel app architecture is authorized by this plan.
