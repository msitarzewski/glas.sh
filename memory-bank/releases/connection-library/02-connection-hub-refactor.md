# Phase 02 — Connection Hub Refactor

## Objective

Refactor the existing connection hub around the shared Library projection while preserving all working connection-management behavior.

## Status

`Complete`

## Completion evidence

- `glas.sh/ConnectionManagerView.swift:24` owns one mode/scope/selection model shared by every platform presentation.
- `glas.sh/ConnectionManagerView.swift:266` composes navigation, results, and detail regions from the shared projection rather than parallel Favorites/Recent/All branches.
- Add, edit, delete, favorite, search, Quick Connect, trust, retry, failure, Tailscale import, Local Terminal, and workgroup actions remain attached to their existing authorities.
- The obsolete `ConnectionSection`, `selectedSection`, `activeTagFilters`, `macFilteredServers`, `sortedSections`, `macShowsTailscale`, `ServerManager.favoriteServers`, and `ServerManager.recentServers` paths were removed; final symbol scans find no remaining references.
- The source file is larger because it now hosts native four-platform shell composition and accessibility hooks. The semantic navigation model is smaller: one projection, one selection model, and no duplicate platform-specific domain state.

## Current integration point

`glas.sh/ConnectionManagerView.swift:12` currently owns platform branches, search, filters, actions, workgroups, details, and Tailscale. macOS also renders separate Favorites, Recent, and All Connections host sections around `glas.sh/ConnectionManagerView.swift:330`, while row interaction and connection behavior are mixed into the same surface.

## Work

1. Replace local, duplicated filtering state with the Phase 01 projection.
2. Decompose the existing view into mode/scope, results, and details regions using private reusable subviews before considering additional files.
3. Put `+` in the Connections results column on every platform.
4. Make single selection show details; retain macOS double-click as an optional fast-connect gesture.
5. Preserve add, edit, delete, favorite, search, Quick Connect, host-trust, retry, and failure presentation.
6. Keep Local Terminal immediately discoverable.
7. Remove duplicate Favorites/Recent/All host rendering as soon as the new scopes replace it.

## Tests

- One row per saved host in each active result set.
- Selection does not connect implicitly except the explicit macOS double-click path.
- Add/edit/delete/favorite mutations update the projection.
- Quick Connect and trust workflows retain existing authorization behavior.
- Results-column `+` invokes the shared add action.

## Exit gate

The existing hub is semantically consolidated around the shared projection, preserves existing management flows, contains no duplicate domain/navigation implementation, and records the raw presentation growth required by four native shells.

**Result:** Passed on the semantic/state boundary. `ConnectionManagerView.swift` grew from 2,008 baseline lines to 2,588 current lines and platform conditionals grew from 10 to 34 for native shell presentation; replaced navigation state and duplicate host projections were removed.
