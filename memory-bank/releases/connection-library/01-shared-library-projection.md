# Phase 01 — Shared Library Projection

## Objective

Create one deterministic, transient projection of existing saved connections, built-in scopes, tag collections, workgroup recipes, and optional network sources.

## Status

`Complete`

## Completion evidence

- `glas.sh/ConnectionLibrary.swift:60` projects saved profiles, built-in scopes, normalized tag collections, workgroup recipes, selection, and optional Network visibility without adding persisted state.
- `glas.sh/ConnectionManagerView.swift:62` builds the projection once per body evaluation from authoritative manager inputs.
- `glas.sh/ConnectionManagerView.swift:56` caches network credential presence outside SwiftUI's render path; Keychain reads are refreshed at lifecycle/configuration boundaries instead of per computed property access.
- `glas.sh/TailscaleClient.swift:344` distinguishes configured, absent, and unavailable credential state without exposing credential material.
- Projection regression tests at `glas.shTests/glas_shTests.swift:3065` cover deduplication, normalized and empty tags, multi-tag counts, every search field, deterministic timestamp tie-breaks, workgroup projection, Network visibility, and selection preservation/clearing after deletion.

## Reuse

- Profiles, tags, and identity: `glas.sh/Models.swift:67`.
- Favorites and recents: `glas.sh/Models.swift` (`ServerConfiguration.isFavorite`, `lastConnected`) projected by `glas.sh/ConnectionLibrary.swift:85`.
- Workgroup recipes: `glas.sh/SettingsManager.swift:175`.
- Runtime workgroups: `glas.sh/SessionManager.swift:32`.
- Tailscale credentials and discovery: `glas.sh/TailscaleClient.swift`.

## Work

1. Define Library modes and scopes without persistence.
2. Normalize tags into stable collection identities, names, counts, and membership.
3. Deduplicate profiles by authoritative identifier before filtering.
4. Derive Favorites and Recent using existing manager behavior.
5. Project `LayoutPreset` entries as workgroup launch recipes.
6. Include Network only when the configured authentication method has usable credentials.
7. Keep selection valid across search, filtering, edits, and deletion.
8. Expose one add-connection action independent of platform presentation.

## Tests

- Deduplication and stable ordering.
- All/Favorites/Recent membership.
- Collection normalization, counts, empty-tag behavior, and multi-tag membership.
- Workgroup recipe projection.
- Configured/unconfigured Network visibility.
- Selection preservation and clearing after deletion.
- Search across name, host, user, tags, and other already-supported fields.

## Exit gate

Projection tests pass without adding a second persisted store or session-opening path.

**Result:** Passed on iOS 27 (211/211 app tests), visionOS 26.4 (208/208), and visionOS 27 (208/208).
