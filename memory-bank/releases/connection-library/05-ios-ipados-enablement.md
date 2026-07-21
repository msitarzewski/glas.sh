# Phase 05 — iPhone and iPad Enablement

## Objective

Enable the existing product architecture on iPhone and iPad 26+ without creating a separate application core or weakening visionOS.

## Existing readiness

- `Packages/RealityKitContent/Package.swift:8` already declares visionOS 26, macOS 26, and iOS 26.
- `Packages/GlasSecretStore/Package.swift:7` already declares visionOS 26, macOS 26, and iOS 26.
- The primary app target remains xros-only at `glas.sh.xcodeproj/project.pbxproj:517` and must be evaluated against installed SDK constraints.
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
