# Phase 05 — iPhone and iPad Enablement

## Objective

Enable the existing product architecture on iPhone and iPad 26+ without creating a separate application core or weakening visionOS.

## Status

`Complete`

## Completion evidence

- The existing primary target now supports iPhone/iPad and visionOS from the shared `glas_shApp` entry point; no second product core or connection store was created.
- `IOSAppRouter` adapts scene presentation only; `SessionManager`, `ServerManager`, `SettingsManager`, host trust, Keychain, themes, terminal engine, and workgroups remain shared.
- The project includes the required iOS app icon asset and shared iOS UI-test target.
- Current generic iOS Release build passes.
- iPhone 17 Pro/iOS 27 direct smoke remained stable for six minutes with native compact navigation and Network correctly absent while unconfigured.
- iPad Pro 13-inch/iOS 27 direct smoke passed with the native three-column Library; the discovered leading-edge row clipping was repaired and visually reverified.
- These Release builds prove an iOS 26 deployment floor; current runtime execution evidence is iOS 27 because no iOS 26 simulator runtime is installed.

## Existing readiness

- `Packages/RealityKitContent/Package.swift:8` already declares visionOS 26, macOS 26, and iOS 26.
- `Packages/GlasSecretStore/Package.swift:7` already declares visionOS 26, macOS 26, and iOS 26.
- The primary app target now declares iPhone/iPad and visionOS support with iOS/visionOS 26 deployment floors in `glas.sh.xcodeproj/project.pbxproj`.
- `glas.sh/glas_shApp.swift:12` is the existing primary app entry and is the preferred shared entry point.

## Work

1. Compile-audit app sources for platform-specific APIs, entitlements, assets, scenes, commands, and window assumptions.
2. Prefer extending the existing primary target/device families and using conditional platform presentation.
3. Reuse the shared Library projection and SessionManager behavior.
4. Add only native iPhone/iPad scene and navigation adaptation required by Phase 03.
5. Validate Keychain, imported keys, host trust, local terminal availability, external keyboard input, files/SFTP, and background lifecycle.
6. Stop and return with exact SDK/compiler evidence before proposing a second target if the universal-target approach is unsafe.

## Tests

- iPhone and iPad 26+ build and launch.
- Compact and regular navigation flows.
- Saved connection, password/key authentication, host trust, and reconnect.
- External keyboard, clipboard, link policy, and terminal resize behavior.
- iCloud settings/theme compatibility with macOS and visionOS.

## Exit gate

iPhone and iPad use the existing product core and shared Library semantics, with any unavoidable target exception explicitly approved and documented.

**Result:** Passed. No parallel iOS application architecture was required.
