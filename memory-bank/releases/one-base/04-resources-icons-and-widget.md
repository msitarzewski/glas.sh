# Phase 04 — Resources, Icons, and Widget

## Objective

Produce correct platform resources from the unified application target while keeping the existing widget as a supported, platform-filtered extension.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phase 03.

## Primary files

- `glas.sh.xcodeproj/project.pbxproj`
- `glas.sh/Assets.xcassets`
- `Platforms/macOS/AppIcon.icon`
- `Platforms/macOS/Assets.xcassets`
- `glasWidgets/*`

Only one agent may edit `project.pbxproj` during this phase.

## Reuse strategy

- Reuse the current iOS/visionOS app icon and solid image stack.
- Reuse the existing Mac Icon Composer artwork.
- Do not regenerate, redraw, or substitute app art.
- Keep the existing widget target and source.

## Work items

1. Make the existing Mac Icon Composer resource available to the unified application target as `MacAppIcon`, following glassdb.
2. Keep the current iOS/visionOS `AppIcon` selection.
3. Use SDK-specific `ASSETCATALOG_COMPILER_APPICON_NAME` values.
4. Resolve duplicate `AppIcon` catalog names without losing either platform’s art.
5. Inspect the compiled resources before deleting the legacy Mac PNG app-icon catalog.
6. Keep `glasWidgets` as a separate app-extension target.
7. Apply platform filters to the widget target dependency and Embed App Extensions entry so unsupported Mac builds do not embed it.
8. Do not add a Mac widget in this release.
9. Preserve accent colors, privacy manifests, localized resources, and icon foreground/middle/background layers.

## Visual and bundle tests

- Inspect Mac Dock, Finder, About, and window-switcher icons at multiple sizes.
- Inspect iPhone, iPad, and Vision Pro application icons.
- Confirm no duplicate asset-catalog warnings.
- Inspect each application bundle for the expected resources.
- Confirm the widget exists and launches on supported platforms.
- Confirm the Mac product does not contain an unsupported widget extension.
- Validate widget app-group access after product-identity convergence.

## Rollback

Restore previous SDK icon settings and widget embedding. Do not delete source artwork during rollback.

## Exit gate

Every application destination presents the correct existing icon and resources, the widget remains functional where supported, and Mac builds contain no incompatible extension.

## Completion evidence

- Existing iOS/visionOS assets and Mac Icon Composer artwork are reused through SDK-specific app-icon settings; no artwork was regenerated.
- The fresh Mac archive contains the Dock icon and no unsupported widget extension.
- `glasWidgets` remains a distinct extension target with platform-filtered dependency/embedding and the shared app-group entitlement.
- Generic visionOS Release inspection confirms the app and widget are arm64, minimum OS 26.0, correctly identified, entitled, and bundled with expected resources.
- Asset catalogs, plist files, and entitlements parse cleanly with no duplicate catalog warning in the final builds.
