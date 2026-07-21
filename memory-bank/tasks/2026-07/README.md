# 2026-07 Tasks

## Tasks Completed

### 2026-07-17: codex-completions implementation and automated-QA checkpoint
- Completed and user-approved the current code/automated-QA checkpoint for the `codex-completions` visionOS release candidate.
- Preserved true full terminal transparency and independent opacity/blur controls while hardening menu order, focus ownership, caret theme, ANSI colors, security, session lifecycle, recording, SFTP, forwarding, and generated-command policy.
- Verified 164/164 app tests on both visionOS 26.4 and visionOS 27.0 arm64 simulators, plus 75/75 GlasSecretStore tests across 13 suites.
- Built an arm64-only generic Release app with minimum visionOS 26.0 and SDK 27.0; installed and smoke-launched on both simulator runtimes.
- Completed independent security/static reviews and an isolated Gitleaks adjudication with zero actionable production credentials.
- Retained physical-device, matching-Xcode-26, external-service, conformance, cross-repository, Phases 06–09, and App Store distribution work as explicit open gates.
- See: [170726_codex-completions-release.md](./170726_codex-completions-release.md)

### 2026-07-19: native macOS parity and final implementation approval
- Added the native Apple Silicon/macOS 26+ application with local PTY and saved-host SSH terminals, multiwindow workspaces, tabs, splits, focused commands, secure keyboard entry, and native window materials.
- Preserved the premium Vision Pro terminal canvas: true full transparency plus independent tint, opacity, and blur, with ANSI glyph colors rendered above the glass composition.
- Added Apple Terminal theme import, iCloud theme/appearance synchronization, light/dark appearance behavior, Mac Dock icon packaging, and platform-consistent terminal chrome/footer controls.
- Upgraded the touched SSH dependency stack to Swift 6.3/current packages and repaired concurrency, lifecycle, parsing, and authentication-limit findings.
- Verified 20/20 macOS tests, 183/183 on each visionOS 26.4 and 27.0 simulator, 331/331 NIOSSH tests, all 39 runnable Citadel tests with five expected environment skips, and 75/75 GlasSecretStore tests.
- Produced a signed arm64 macOS Release with hardened runtime; final diff/stub/secret checks passed.
- See: [170726_codex-completions-release.md](./170726_codex-completions-release.md)

### 2026-07-20: terminal settings section recovery
- Restored the visible `Terminal`, `Overrides`, and `Port Forwarding` section control inside the Terminal Settings sheet.
- Reused the existing theme, per-session transparency/blur/tint, and forwarding views without introducing duplicate settings state.
- Verified 27/27 macOS tests, the complete serial visionOS suite, both Release builds, and clean diff/stub/secret scans.
- See: [200726_terminal-settings-section-recovery.md](./200726_terminal-settings-section-recovery.md)

### 2026-07-21: Connection Library release completion
- Completed one deterministic connection/workgroup projection and native Connection Library shells across visionOS, Apple Silicon macOS, iPadOS, and iOS.
- Preserved authoritative profile, credential, host-trust, session, workgroup, terminal appearance, and ANSI rendering systems; no parallel product core or persisted collection store was introduced.
- Removed replaced navigation branches and obsolete favorites/recents helper projections.
- Verified 211/211 iOS 27, 208/208 on both visionOS 26.4 and 27, and 32/32 macOS 27 tests; all current Release builds and touched package gates passed.
- Direct Mac/iPhone/iPad smokes, physical Vision Pro signed build/install, final marker/orphan scans, and Gitleaks passed. Approved Apple beta-tooling limitations are recorded in the release program.
- See: [210726_connection-library-release.md](./210726_connection-library-release.md)
