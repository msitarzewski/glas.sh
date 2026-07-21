# Phase 02 — Connection Hub Refactor

## Objective

Refactor the existing connection hub around the shared Library projection while preserving all working connection-management behavior.

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

The existing hub is materially smaller, uses the shared projection, preserves existing management flows, and contains no duplicate navigation implementation.
