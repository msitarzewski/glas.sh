# Phase 00 — Baseline and Governance

## Objective

Preserve the approved Connection Library and terminal-polish state, establish the glassdb-derived target architecture, and define safe sequencing before project changes begin.

## Status

`Complete`

## Owner

Codex agent team

## Completed evidence

- `agent/connection-library` commit `c9f7a406` preserves all tracked release work.
- Generated `default.profraw` was excluded.
- The current project has separate `glas.sh` and `glas.sh Mac` application targets and separate Mac test targets.
- glassdb has one application target with `SDKROOT = auto`, iOS/macOS/visionOS support, Catalyst disabled, one product identity, and one platform-adaptive app entry point.
- Existing release-program structure was reused from `memory-bank/releases/connection-library`.

## Reuse analysis

- Extend the existing primary `glas.sh` application target.
- Reuse every Mac workspace, PTY, command, and window source now located in `Platforms/macOS` (historically `glas.sh-mac` at the release baseline).
- Reuse the existing shared app core and package products.
- Reuse platform Info.plists, entitlements, and icons with SDK-conditional build settings.
- Reuse shared unit/UI-test sources and existing test targets as the consolidation destination.
- Do not create a new production or test source file.

## Governance

- Keep the old Mac application and test targets until the unified path passes.
- Serialize edits to `glas.sh.xcodeproj/project.pbxproj`.
- Make each phase independently buildable.
- Do not mix terminal feature redesign with target consolidation.
- Do not change credential formats, Keychain namespaces, host-trust semantics, terminal protocols, or persisted workgroup schemas.
- Preserve a clean rollback commit at every phase boundary.
- A failing phase returns to its entry commit before an alternative is attempted.

## Baseline evidence required before Phase 01

- Record `git status`, branch, and baseline commit.
- Record the current Xcode target and scheme lists.
- Record current per-platform unit/UI test inventories and build destinations.
- Record current bundle identifiers, entitlements, Info.plists, icons, and embedded extensions.
- Confirm local PTY, saved SSH launch, Vision Pro terminal rendering, and shared-secret retrieval are working at baseline.

## Exit gate

The baseline is committed; architecture, reuse rules, coordination rules, acceptance criteria, and rollback strategy are indexed in the One Base release.

## Final evidence

- Baseline commit `c9f7a406` remains the rollback authority and no history was rewritten.
- Existing primary app, Mac platform sources, shared managers, GlassSecretStore integration, resources, widget, tests, and schemes were extended; no new production or test source file was created.
- The user approved one final release diff in place of the planned phase-boundary commits. It is published through PR [#30](https://github.com/msitarzewski/glas.sh/pull/30); no synthetic phase history was created.
