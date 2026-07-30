# Phase 06 — Native Platform Foundation

## Objective

Create native Apple-platform shells around shared terminal, SSH, endpoint, and security code without turning glas.sh into a Catalyst port or compromising the premium Vision Pro experience.

## Included items

`PLAT-001...006` and the platform-enabling portions of `SEC-006...008`.

## Current status — QA

The native Apple Silicon/macOS 26+ shell is implemented and user-approved. It reuses the shared session, SSH, trust, settings, theme, and terminal layers while adding AppKit window policy, local PTY transport, platform-native multiwindow workspaces, tabs, splits, focused commands, secure keyboard entry, and native material chrome. The macOS suite passes 20/20 and the shared visionOS suite passes 183/183 on both 26.4 and 27.0 after the parity changes. Native iPadOS/iOS shells and final physical accessibility/performance evidence remain open, so the full phase stays in QA rather than Complete.

The approved model-owned adaptive workspace is implemented on
`codex/native-mac-terminal-chrome`. SwiftUI's `.sidebarAdaptable` tabs own
session navigation; the former AppKit tab-group mirror, KVO, delayed tab-bar
reconciliation, and Window-menu inspection are removed. Connections and
terminal scenes now share native unified compact titlebar treatment, one system
sidebar control, full-height sidebar material, compact toolbar icon sizing, and
stable separated global/terminal tool clusters. The terminal canvas retains its
independent opacity, tint, blur, and true-transparency behavior.

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
- Use a system-generated leading adaptive-tab ornament for root modes in a
  tabbed workgroup window.
- Selecting a workgroup `TabSection` reveals that window's native session
  sidebar; do not draw a second custom ornament or duplicate those modes inside
  the window.
- Keep one bottom status/tools ornament per terminal window. Independent
  spatial windows never share an ornament or a presentation owner.
- Retain the standalone connection-label ornament until standalone sessions
  migrate to the same workgroup shell.

### 06.3 Native macOS shell

- Native menus, commands, tabs, splits, window restoration appropriate to reconnectable workspaces, and secure keyboard entry.
- Local PTY support through a separate local-transport implementation.
- Data-protection Keychain configuration from Phase 02.
- Keyboard, mouse, clipboard, drag/drop, and accessibility behavior expected on macOS.
- Present session tabs through SwiftUI's native `.sidebarAdaptable` `TabView`
  inside each terminal window instead of mirroring AppKit window-tab state into
  a custom sidebar.
- Keep each tab's existing horizontal/vertical split topology inside that tab.
- Use the native unified compact titlebar for focused server/workgroup identity,
  `user@host:port`, status, and terminal tools. Keep the terminal canvas square,
  edge-to-edge, and independent of chrome material.
- Route Command-T, close tab, and Move Tab to New Window through the authoritative
  workspace model and value-based `WindowGroup` scenes.
- Remove tab-strip hiding, tab-group KVO, delayed visibility reconciliation,
  and localized Window-menu inspection when the adaptive shell replaces the
  current prototype.

### 06.4 Native iPadOS shell

- Multiwindow workspaces and scene restoration based on reconnectable definitions rather than live sockets.
- Hardware-keyboard-first interaction, pointer support, adaptive sidebar, and Stage Manager behavior.
- Shared SSH and terminal layers with iPad-native navigation.
- Use the same adaptive tab/workgroup model as macOS and visionOS. iPad presents
  it as the native top tab bar that can expand into a sidebar.
- Keep Stage Manager window controls unobstructed and clip horizontally scrolling
  terminal content so it does not render under an expanded sidebar.
- Keep the software-keyboard terminal accessory hidden until requested.

### 06.5 Native iOS shell

- Compact one-terminal focus, fast session switcher, command accessory controls, and safe paste/clipboard policy.
- iOS-enabled GlasSecretStore and endpoint/session layers.
- Avoid squeezing the iPad or visionOS interface into phone geometry.
- Preserve the compact OS 26 session switcher rather than forcing many live
  sessions into a bottom tab bar.
- Treat OS 27 sidebar placement and availability APIs as an optional,
  availability-gated enhancement until the final SDK is adopted.

### 06.6 Platform capability matrix

For every feature, define `supported`, `platform-adapted`, `unavailable`, or `deferred` for visionOS, macOS, iPadOS, and iOS. Do not expose a shared control where the platform implementation is absent.

## Acceptance criteria

- Shared layers compile without visionOS-only presentation dependencies.
- Native targets use shared transport/domain/security/engine code rather than copies.
- Each platform has an intentional native interaction model.
- visionOS transparency and spatial behavior pass regression tests after extraction.
- GlasSecretStore supports every target platform with correct Keychain semantics.
- No Catalyst target is used as the primary macOS strategy.
- Presentation uses stable session/workgroup identifiers; resizing, sidebar
  changes, tab reconstruction, and platform adaptation cannot terminate sessions.
- macOS has one native sidebar presentation with no duplicate horizontal tab
  strip or terminal footer.
- A visionOS ornament controls only its owning window; independent spatial
  windows retain independent chrome, appearance, and tools.
- Terminal glyphs and cursor remain fully opaque and vivid at every supported
  terminal-canvas opacity, tint, and blur setting.

## Tests

- Package tests across all declared platforms.
- Dependency-boundary checks preventing spatial imports in shared targets.
- Shared session/credential/terminal behavior tests reused by each app target.
- Platform UI tests for native navigation and feature availability.
- visionOS regression suite including transparency, blur, windows, focus, and ornaments.
- OS 26 and 27 adaptive-tab compilation and simulator coverage on Mac, iPad,
  iPhone, and Vision Pro.
- Mac sidebar, Command-T, split, detach, titlebar, multiple-window, and
  restoration UI coverage.
- visionOS system-ornament, native-session-sidebar, independent-window, and
  per-window bottom-ornament coverage.
- iPad Stage Manager, top-tab/sidebar, pointer, hardware-keyboard, and
  software-keyboard visibility coverage; compact iPhone session-switching
  coverage.

## Risks and mitigations

- Premature abstraction: extract from proven Phase 01–05 behavior and keep contracts narrow.
- Dependency explosion: prefer target splits and measure build impact.
- Lowest-common-denominator UI: share domain behavior, not presentation trees.
- Cross-platform scope overwhelming release hardening: phase work behind explicit per-platform gates.
- SwiftUI view lifetime closing live sessions: retain session/workgroup ownership
  in models and close only through explicit commands or scene authority.
- Invalid dynamic-tab selection: repair selection in the same model mutation
  that adds, removes, moves, or restores a session.
- AppKit tab mirroring becoming a second navigation system: replace it rather
  than nesting or synchronizing it with adaptive tabs.
- OS 27 beta-only placement APIs leaking into the OS 26 path: availability-gate
  them and keep `.sidebarAdaptable`, `Tab`, and `TabSection` as the shared floor.

## Exit evidence

- Approved dependency/target diagram.
- Builds and shared tests for each introduced target.
- Vision Pro regression evidence showing no loss of the product invariant.
- Native macOS arm64 build and model/UI regression coverage for one automatic
  sidebar control, stable terminal lifetime, explicit tab operations, and
  toolbar compression.
- User visual approval of the Connections and terminal native chrome,
  full-height sidebar, compact tool groups, title identity, local/SSH tab
  parity, and adaptive narrow-window behavior.
- Publication checkpoint: 274/274 native Mac unit tests pass with zero
  failures, skips, or runtime warnings; exact-current visionOS 27, iPadOS 27,
  and iOS 27 simulator builds pass; diff and production incomplete-marker scans
  are clean. The Mac UI host harness stalled between launches and was stopped,
  so its full-suite result is deliberately not represented as passing.
