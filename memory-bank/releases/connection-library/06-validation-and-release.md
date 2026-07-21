# Phase 06 — Validation and Release

## Objective

Prove the Connection Library architecture and all preserved terminal capabilities end to end before release completion.

## Status

`Complete` — user approved 2026-07-21 with the Apple beta-tooling limitations below explicitly accepted.

## Automated evidence

- iOS 27 app suite: 211/211 passed, zero skips and zero runtime warnings.
- visionOS 26.4 app suite: 208/208 passed, zero skips and zero runtime warnings.
- visionOS 27 app suite: 208/208 passed, zero skips and zero runtime warnings.
- Apple Silicon macOS 27 suite: 32/32 passed, zero skips and zero runtime warnings.
- GlasSecretStore: 76 passed across 13 suites.
- swift-nio-ssh: 331/331 passed.
- Citadel: 44 executed, with 39 passed and five expected environment-dependent skips.
- RealityKitContent build passed.
- Exact-current-tree Release builds passed for Apple Silicon macOS, generic iOS, and generic visionOS.

## Direct application smoke evidence

- macOS: the native Library launched, rendered, and remained open while Local Terminal opened in a separate terminal window.
- iPhone 17 Pro/iOS 27 simulator: compact Library remained foreground and responsive; Library, Favorites, Recent, Workgroups, Settings, and Add Server were present and Network was absent while unconfigured.
- iPad Pro 13-inch/iOS 27 simulator: the native three-column Library launched without a crash; the initially observed leading-row clipping was repaired and visually reverified.

## Apple tooling limitations accepted at approval

- The XCUITest target builds and parses, but Xcode 27 beta repeatedly loses the UI-test worker after application launch and blocks at `Blocking finish to clean up test session`. No automated UI pass is claimed. Direct application smokes and platform unit/routing coverage provide the functional evidence for this checkpoint.
- A signed physical Vision Pro Release build passed for `RealityDevice14,1`/arm64e on visionOS 27 and installed successfully as `sh.glas.app` 1.0 (2), minimum visionOS 26.0. CoreDevice then timed out while enabling developer-disk-image services for every launch attempt, and physical screenshot/display capture is unsupported. Physical build/install are proven; launch/render is not claimed.
- The user explicitly approved these two infrastructure limitations on 2026-07-21. A wearer-present launch remains useful additional evidence but is not represented as completed automation.

## Final quality evidence

- `git diff --check` passed.
- Project and shared schemes validate; the UI-test source parses.
- Production TODO/FIXME/HACK/stub/future/unimplemented/fatal marker scan is empty.
- Replaced navigation/orphan symbol scan is empty.
- Gitleaks found no secrets in the tracked diff, UI-test source, or app-icon assets.
- No production mock data or stub implementation was added.

## Functional matrix

- Browse All, Favorites, Recent, each Collection, Workgroups, and configured Network.
- Add, edit, delete, favorite, search, Quick Connect, retry, and host-trust flows.
- Launch saved SSH, local terminal, and workgroup recipes.
- Open multiple windows and multiple tabs; verify focus-aware Command-T and footer `+`.
- Confirm Network is absent when credentials are missing.
- Confirm Library remains open after launch.

## Automated matrix

- macOS 26+ arm64 unit/UI tests and Debug/Release builds.
- visionOS 26 and 27 unit/UI tests and Debug/Release builds.
- iPhone and iPad 26+ unit/UI tests and Debug/Release builds.
- GlasSecretStore and other touched package tests.
- Projection tests for deduplication, counts, filters, selection, and visibility.
- Routing tests for Connect, Workgroups, Local Terminal, plus, and Command-T.

## Product regression matrix

- True 100% terminal transparency.
- Independent tint, opacity, blur, and material controls.
- Light/dark mode chrome and terminal contrast.
- ANSI normal/bright color fidelity above background effects.
- Theme import and iCloud settings synchronization.
- Terminal padding, resize, scrollback, cursor, keyboard, and clean exit.
- visionOS ornaments; physical Vision Pro build/install are verified, while launch/window rendering are accepted as CoreDevice-blocked and are not claimed.

## Security and quality gates

- Existing authorization, Keychain, host trust, and legacy-algorithm policy remain authoritative.
- No credentials or unbounded diagnostics in logs.
- `git diff --check`, compiler warnings review, production TODO/FIXME/stub scan, orphan-source scan, and secret scan pass.
- No mock data or production stubs.
- Net navigation complexity decreases; replaced code is absent.

## Documentation gate

After user approval of implementation:

- update this dashboard and phase statuses;
- update `memory-bank/systemPatterns.md` with the shared projection/native shell boundary;
- record architectural decisions in `memory-bank/decisions.md`;
- add release/task evidence and current validation results;
- update `memory-bank/toc.md`, `activeContext.md`, and `progress.md`.

## Exit gate

The supported evidence matrix and explicitly accepted tooling boundaries are recorded, displaced code and stubs are absent, and the user approves release completion.

**Result:** Passed with the explicitly approved Xcode UI-runner and CoreDevice launch-capture limitations recorded above.
