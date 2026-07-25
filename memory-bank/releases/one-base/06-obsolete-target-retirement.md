# Phase 06 — Obsolete Target Retirement

## Objective

Remove the old Mac application/test targets and scheme only after the unified application, tests, signing, resources, and migrations are proven.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phase 05 and passing focused validation from Phases 01–05.

## Primary files

- `glas.sh.xcodeproj/project.pbxproj`
- `glas.sh.xcodeproj/xcshareddata/xcschemes/glas.sh Mac.xcscheme`

The native Mac implementation is retained under the public `Platforms/macOS` boundary.

## Preconditions

- Unified app builds and launches on every supported destination.
- Unified unit and UI test targets pass.
- Bundle identity, entitlements, icons, resources, widget filtering, and data migration pass.
- The old targets have not been used to supply hidden resources or generated settings.
- A rollback commit exists immediately before target deletion.

## Work items

1. Remove the `glas.sh Mac` application target.
2. Remove the standalone `glas.sh-macTests` group after preserving its sources beneath `glas.shTests/macOS`.
3. Remove `glas.sh-macUITests`.
4. Remove their product references, target dependencies, container proxies, build phases, build configurations, configuration lists, and target attributes.
5. Remove obsolete framework build-file entries used only by deleted targets.
6. Remove the shared `glas.sh Mac.xcscheme`.
7. Preserve the `Platforms/macOS` source, plist, entitlement, icon, and resource files selected by the unified target.
8. Preserve widget and unified test targets.
9. Search for stale target names, bundle IDs, product references, test hosts, and scheme references.
10. Run Xcode project parsing after each logical removal group to localize any corruption.

## Project consistency tests

- `plutil -lint` for project-associated plists and entitlements.
- `xcodebuild -list` succeeds.
- Exactly one application target is listed.
- Exactly one application scheme is shared.
- One unit-test and one UI-test target remain.
- `PBXProject.targets`, `TargetAttributes`, Products, dependencies, and schemes contain no orphan references.
- Xcode opens without target-repair prompts.
- Destination picker contains Mac, iPhone, iPad, and Vision Pro under `glas.sh`.

## Rollback

Revert the single Phase 06 retirement commit. Do not manually reconstruct deleted project objects.

## Exit gate

The duplicate Mac targets and scheme are absent, all required source/resources remain, the project is internally consistent, and the unified scheme exposes every supported destination.

## Completion evidence

- The old Mac application, unit-test, and UI-test target objects and their products, dependencies, build configurations, target attributes, and proxies are absent.
- `glas.sh.xcodeproj/xcshareddata/xcschemes/glas.sh Mac.xcscheme` is removed; only the intended `glas.sh` app and `glasWidgets` extension schemes remain shared.
- The retained `Platforms/macOS` folder continues to supply native Mac source, plist, entitlement, and icon resources to the unified target.
- The project contains four native targets: app, unit tests, UI tests, and widget. No Swift source file was deleted.
- Project parsing, plist/entitlement linting, target/scheme/product scans, destination discovery, and all final builds pass without orphan references.
