# Phase 01 — Primary Target Expansion

## Objective

Teach the existing primary `glas.sh` application target to build a native Apple Silicon macOS product while retaining its existing iPhone, iPad, and visionOS destinations and keeping the old Mac target available as rollback.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phase 00.

## Primary files

- `glas.sh.xcodeproj/project.pbxproj`
- `Platforms/macOS/*.swift`
- `glas.sh/glas_shApp.swift`

Only one agent may edit `project.pbxproj` during this phase.

## Work items

1. Change the primary target to `SDKROOT = auto`.
2. Set `SUPPORTED_PLATFORMS` to iPhone device/simulator, macOS, and visionOS device/simulator.
3. Set `SUPPORTS_MACCATALYST = NO`.
4. Preserve iPhone/iPad and visionOS deployment floors and add the current macOS deployment floor.
5. Keep macOS `ARCHS = arm64` without narrowing mobile or vision destinations incorrectly.
6. Add the existing native Mac synchronized source group, now `Platforms/macOS`, to the primary target.
7. Wrap every Mac-only source file in a complete `#if os(macOS)` boundary before it can enter mobile builds.
8. Continue using the current conditional entry points temporarily:
   - `glas_shApp` on iOS/visionOS;
   - `GlasShMacApp` on macOS.
9. Preserve the old `glas.sh Mac` application target unchanged as a comparison and rollback build.
10. Do not change bundle identifiers, entitlements, icons, tests, or schemes yet beyond what is strictly necessary to compile the expanded target.

## Required behavior

- The primary target produces a native macOS application, not Catalyst.
- Existing iOS/visionOS builds do not see AppKit or Carbon symbols.
- Shared packages resolve once through the primary target.
- No Mac workspace or terminal behavior is rewritten.

## Tests

- Project parse and `xcodebuild -list`.
- Primary-target Debug builds:
  - generic iOS;
  - iPhone simulator;
  - iPad simulator;
  - generic visionOS;
  - visionOS simulator;
  - Apple Silicon macOS.
- Compare the primary-target Mac product with the fallback target for:
  - linked packages;
  - architectures;
  - executable name;
  - scene launch;
  - local PTY startup.
- Run focused compilation tests proving all Mac-only files are excluded on iOS/visionOS.

## Rollback

Revert the Phase 01 commit. The untouched `glas.sh Mac` target remains runnable.

## Exit gate

The existing primary target builds and launches a native Apple Silicon Mac app and still builds every current mobile/vision destination; the fallback Mac target still passes.

## Completion evidence

- `glas.sh.xcodeproj/project.pbxproj` now defines one native application target with automatic SDK selection, iOS/visionOS/macOS supported platforms, Catalyst disabled, and SDK-conditional settings.
- Mac builds resolve as native macOS arm64 with minimum macOS 26.0; mobile and vision destinations retain their native architectures and deployment floors.
- Existing `Platforms/macOS` sources compile through complete macOS guards; AppKit/Carbon symbols do not enter iOS or visionOS products.
- Exact-current iPhone/iPad/visionOS builds and the fresh Mac Release archive pass. The old Mac target remained available until Phase 06 retirement.
