# Phase 06 — Validation and Release

## Objective

Prove the Connection Library architecture and all preserved terminal capabilities end to end before release completion.

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
- visionOS ornaments and physical Vision Pro window rendering.

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

All acceptance criteria pass on the supported platform matrix, physical Vision Pro verification is recorded, displaced code and stubs are absent, and the user approves release completion.
