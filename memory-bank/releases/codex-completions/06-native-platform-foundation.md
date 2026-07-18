# Phase 06 — Native Platform Foundation

## Objective

Create native Apple-platform shells around shared terminal, SSH, endpoint, and security code without turning glas.sh into a Catalyst port or compromising the premium Vision Pro experience.

## Included items

`PLAT-001...006` and the platform-enabling portions of `SEC-006...008`.

## Current status — In progress

Terminal/renderer and package dependency separation have begun: SwiftTerm is behind a narrow UIKit-private engine adapter, Citadel links directly to the app rather than through RealityKitContent, and the visionOS candidate is arm64-only with an OS 26 floor. Native macOS, iPadOS, and iOS shells and full platform-neutral target extraction remain open. This phase has not been deferred or declared complete; it remains part of the broader program until the user assigns a separate disposition.

## Sequencing constraint

This phase begins only after session ownership, security boundaries, terminal-engine separation, and visible Vision Pro behavior are stable. Multi-platform work must not become a reason to reduce transparency, spatial window quality, or Vision Pro-specific interaction.

Every product target in this phase requires Apple OS 26 or newer and Apple Silicon. Intel and Catalyst are explicitly unsupported.

## Existing architecture to reuse

- `Packages/RealityKitContent/Package.swift:8` already declares multiple Apple platforms.
- Runtime app code is organized into focused managers per `memory-bank/systemPatterns.md#File Organization`.
- GlasSecretStore is already a separate package for secret material and trust.
- Citadel and swift-nio-ssh provide the shared SSH transport.
- Phase 04 provides the terminal-engine boundary.

## Reuse analysis before new targets/packages

- Keep secrets/trust in GlasSecretStore.
- Keep SSH/session domain code independent of RealityKit and app scenes.
- Keep terminal engine adapters separate from spatial content.
- Reuse the existing package where its dependency graph fits; split targets inside it before creating a new package.
- If a new shared-core package becomes necessary, document why app target code, RealityKitContent targets, Citadel, and GlasSecretStore cannot own the boundary.

## Work packages

### 06.1 Dependency and target map

Define layers with one-way dependencies:

1. Endpoint/session domain models.
2. SSH transport and terminal session orchestration.
3. Secret/trust interfaces.
4. Terminal-engine contract and adapters.
5. Platform-neutral application services.
6. Native platform presentation.
7. visionOS-only spatial content.

Remove SwiftUI/RealityKit/WidgetKit dependencies from shared layers unless intrinsic.

### 06.2 visionOS reference shell

- Preserve independent terminal windows, spatial grouping, ornaments, widgets, and immersive focus where completed.
- Preserve 100% transparency and independent opacity/blur controls.
- Use adaptive geometry and platform-native toolbars.
- Treat visionOS device behavior as the reference quality bar, not a lowest-common-denominator shell.

### 06.3 Native macOS shell

- Native menus, commands, tabs, splits, window restoration appropriate to reconnectable workspaces, and secure keyboard entry.
- Local PTY support through a separate local-transport implementation.
- Data-protection Keychain configuration from Phase 02.
- Keyboard, mouse, clipboard, drag/drop, and accessibility behavior expected on macOS.

### 06.4 Native iPadOS shell

- Multiwindow workspaces and scene restoration based on reconnectable definitions rather than live sockets.
- Hardware-keyboard-first interaction, pointer support, adaptive sidebar, and Stage Manager behavior.
- Shared SSH and terminal layers with iPad-native navigation.

### 06.5 Native iOS shell

- Compact one-terminal focus, fast session switcher, command accessory controls, and safe paste/clipboard policy.
- iOS-enabled GlasSecretStore and endpoint/session layers.
- Avoid squeezing the iPad or visionOS interface into phone geometry.

### 06.6 Platform capability matrix

For every feature, define `supported`, `platform-adapted`, `unavailable`, or `deferred` for visionOS, macOS, iPadOS, and iOS. Do not expose a shared control where the platform implementation is absent.

## Acceptance criteria

- Shared layers compile without visionOS-only presentation dependencies.
- Native targets use shared transport/domain/security/engine code rather than copies.
- Each platform has an intentional native interaction model.
- visionOS transparency and spatial behavior pass regression tests after extraction.
- GlasSecretStore supports every target platform with correct Keychain semantics.
- No Catalyst target is used as the primary macOS strategy.

## Tests

- Package tests across all declared platforms.
- Dependency-boundary checks preventing spatial imports in shared targets.
- Shared session/credential/terminal behavior tests reused by each app target.
- Platform UI tests for native navigation and feature availability.
- visionOS regression suite including transparency, blur, windows, focus, and ornaments.

## Risks and mitigations

- Premature abstraction: extract from proven Phase 01–05 behavior and keep contracts narrow.
- Dependency explosion: prefer target splits and measure build impact.
- Lowest-common-denominator UI: share domain behavior, not presentation trees.
- Cross-platform scope overwhelming release hardening: phase work behind explicit per-platform gates.

## Exit evidence

- Approved dependency/target diagram.
- Builds and shared tests for each introduced target.
- Vision Pro regression evidence showing no loss of the product invariant.
