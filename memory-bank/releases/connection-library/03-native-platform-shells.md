# Phase 03 — Native Platform Shells

## Objective

Present the same Connection Library capabilities with platform-native navigation on visionOS, macOS, iPadOS, and iOS.

## Status

`Complete`

## Completion evidence

- visionOS uses ornament-selected modes at `glas.sh/ConnectionManagerView.swift:277`; Collections shows a real child-scope column before results/details, while modes without children begin with results.
- macOS uses native three-column Library composition and retains selection, search, contextual actions, and explicit double-click connect behavior.
- iPad uses the same split-view hierarchy with an adaptive native row at `glas.sh/ConnectionManagerView.swift:2225`; the corrected leading-edge layout is recorded in `/tmp/glas-ipad-row-fix.png`. A geometry regression assertion was added and builds/parses, but was not executed under the documented Xcode runner limitation.
- iPhone uses compact stack navigation through `ConnectionCompactDestination` at `glas.sh/ConnectionManagerView.swift:17` without duplicating the domain projection.
- `glas.shUITests/ConnectionLibraryUITests.swift:35` defines cross-platform Library-mode, settings, connection lifecycle, collection, favorite, and route coverage; the target builds and parses on every supported shell.

## visionOS

- Ornament: Library, Favorites, Recent, Collections, Workgroups, optional Network, and Settings.
- Optional first window column: real children of the selected ornament mode, currently Collections.
- Results column: filtered connections or workgroup recipes; it is the first in-window column when a mode has no children.
- Detail column: selected item details and actions.
- Never repeat ornament choices as an identical first-column list.

## macOS

- Standard three-column NavigationSplitView behavior.
- Sidebar for modes/scopes, results column for connections, detail column for inspection and actions.
- Native keyboard navigation, search, commands, contextual menus, and double-click connection.

## iPadOS

- Adaptive split view retaining scope, result, and detail context when space permits.
- Collapse predictably without losing selection or creating a second navigation model.

## iOS

- Navigation stack: mode/scope -> results -> details.
- Compact actions remain reachable without reproducing desktop chrome.

## Tests

- Compact and regular size-class navigation.
- Selection restoration during column collapse/expansion.
- visionOS ornament and column hierarchy.
- Keyboard, pointer, accessibility label, focus, and Dynamic Type coverage appropriate to each platform.

## Exit gate

All four platforms share capability and projection behavior while using native presentation, and no platform duplicates the domain model.

**Result:** Passed by current Release builds, platform unit suites, and direct Mac/iPhone/iPad application smokes.
