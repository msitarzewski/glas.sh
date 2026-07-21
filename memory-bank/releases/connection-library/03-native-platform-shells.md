# Phase 03 — Native Platform Shells

## Objective

Present the same Connection Library capabilities with platform-native navigation on visionOS, macOS, iPadOS, and iOS.

## visionOS

- Ornament: Library, Favorites, Recent, Collections, Workgroups, optional Network, and Settings.
- First window column: scopes or children of the selected ornament mode.
- Second window column: filtered connections or workgroup recipes.
- Third window column: selected item details and actions.
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
