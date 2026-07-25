# Phase 02 — App and Scene Consolidation

## Objective

Replace the two platform-conditional application entry points with one `@main` glas.sh application that composes the existing native scene graphs per platform.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phase 01.

## Primary files

- `glas.sh/glas_shApp.swift`
- `glas.sh-mac/glas_shMacApp.swift`
- Existing `glas.sh-mac/MacWorkspace*.swift` and `MacLocalTerminalPaneView.swift`

## Work items

1. Remove the outer iOS/visionOS-only restriction around the existing `glas_shApp` entry point.
2. Add a macOS scene branch to `glas_shApp.body`, reusing the current scenes from `GlasShMacApp`:
   - Connections;
   - Terminal workspace WindowGroup;
   - SFTP;
   - Port Forwarding;
   - Settings;
   - debug HTML Preview;
   - `MacWorkspaceCommands`.
3. Preserve the current iOS compact root and visionOS scene graph without structural rewrites.
4. Preserve shared `SessionManager` and `SettingsManager` ownership at app scope.
5. Remove only the duplicate `@main GlasShMacApp` declaration after the unified app entry compiles.
6. Keep the remaining AppKit window-reader/helper code in `glas_shMacApp.swift` under its macOS guard.
7. Verify application commands are registered exactly once per platform.
8. Verify scene identifiers remain stable so existing `openWindow` routes continue to resolve.
9. Do not rename or redesign workspaces, ornaments, tabs, or terminal controls.

## Functional matrix

- macOS Connections opens at launch.
- macOS Local Terminal and saved SSH open native workspace windows.
- macOS Settings uses the native Settings scene.
- iPhone launches the compact Connection Library.
- iPad launches its adaptive Connection Library.
- visionOS launches Connections and opens terminal workgroup windows with ornaments.
- SFTP, port forwarding, HTML Preview debug scenes, and settings open through their existing IDs.

## Tests

- Compiler proves exactly one `@main` for each destination.
- Scene-routing unit tests for every window identifier.
- Mac workspace command tests prove commands are not duplicated.
- Direct launch and secondary-window smoke on all platforms.
- Search source and products for duplicate application entry points.

## Rollback

Restore the two conditional entry points. Phase 01’s unified target and the old Mac target remain available.

## Exit gate

One `@main` application owns all supported destinations, each platform retains its native scene graph, and no route or command is duplicated or lost.

## Completion evidence

- `glas.sh/glas_shApp.swift` is the single application `@main` authority and branches to the existing native platform scenes.
- The duplicate Mac app entry was removed while the retained helper/window code in `glas.sh-mac/glas_shMacApp.swift` remains macOS-guarded.
- Static scans find one application `@main`; the widget extension is the only other intended `@main`.
- Mac commands are registered once, terminal ingest is deferred past the current view transaction, and iPhone/iPad/visionOS navigation remains platform-native.
- Direct Mac launch and iPhone/iPad/visionOS UI smokes prove primary and secondary application routes remain viable.
