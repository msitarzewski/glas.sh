# 170726_codex-completions-release

## Objective

Implement and verify the current `codex-completions` release candidate against the external assessment, Functional Hardening backlog, and product requirement that glas.sh remain a premium Vision Pro terminal with genuine full transparency and independent opacity and blur controls.

## Outcome

- ✅ User approval: code and automated-QA checkpoint approved on 2026-07-17.
- ✅ Final user approval: native macOS/visionOS parity candidate approved on 2026-07-19 after iterative physical and visual review.
- ✅ App tests: 183/183 passed on visionOS 26.4 arm64 Simulator and 183/183 passed on visionOS 27.0 arm64 Simulator.
- ✅ macOS tests: 20/20 passed on Apple Silicon macOS.
- ✅ SSH packages: NIOSSH 331/331 passed; Citadel executed 44 tests with 39 passed and five expected live-environment skips.
- ✅ GlasSecretStore: 75/75 passed across 13 suites.
- ✅ Build: generic visionOS Release and signed native macOS Release succeeded.
- ✅ Binary: Apple Silicon only; visionOS minimum 26.0/SDK 27.0; macOS Release is arm64 with hardened runtime and runtime 27.0.
- ✅ Smoke: installed and launched as `sh.glas.app` on both simulator runtimes.
- ✅ Physical/visual: Vision Pro terminal rendering, ANSI color, full-transparency behavior, independent opacity/blur behavior, and macOS native chrome were reviewed during the implementation loop.
- ✅ Quality: `git diff --check` and the production TODO/FIXME/stub scan passed.
- ✅ Security: independent post-fix audits found no current release blocker in glas.sh or GlasSecretStore.
- ✅ Secret review: final isolated Gitleaks scans of the 9.04 MB tracked diff and every untracked source area found zero leaks.
- ⏳ Distribution: complete physical Vision Pro security/input/accessibility/performance evidence, matching Xcode 26, archive, TestFlight, screenshots/listing, and final go/no-go remain open.

## Files Modified

The approved work spans the existing app, packages, tests, assets, and release documentation. Primary integration areas:

- `glas.sh/SessionManager.swift`, `glas.sh/ServerManager.swift`, `glas.sh/glas_shApp.swift`, `glas.sh/ConnectionManagerView.swift` — authoritative session/server state, shared preparation, external confirmation, reconnect/layout cleanup.
- `glas.sh/KeychainManager.swift`, `glas.sh/SettingsManager.swift`, `Packages/GlasSecretStore/` — forward-only credential migration, host trust, atomic destination creation, transactional artifact-aware key deletion and recovery.
- `glas.sh/SessionRecorder.swift`, `glas.sh/SFTPBrowserView.swift`, `glas.sh/TailscaleClient.swift`, `glas.sh/AIAssistant.swift` — protected/bounded recording, safe resumable transfers, redacted diagnostics, deterministic command review.
- `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`, `TerminalEmulator.swift`, `glas.sh/TerminalWindowView.swift` — terminal boundary, focus ownership, paste/OSC/link policy, menu ordering, ANSI palette, caret theme, runtime behavior.
- `glas.sh/SettingsView.swift`, `glas.sh/WindowRecoveryManager.swift` — independent opacity/blur controls, transparent endpoint, migration and per-session resolution.
- `glas.shTests/glas_shTests.swift`, `Packages/GlasSecretStore/Tests/` — security, migration, connection-flow, terminal, appearance, lifecycle, and partial-artifact regressions.
- `glas.sh/Assets.xcassets/AppIcon.solidimagestack/` — glassdb-provided release icon integrated into the existing layered icon asset.
- `glas.sh-mac/`, `glas.sh-macTests/`, `glas.sh.xcodeproj/project.pbxproj` — native macOS application target, AppKit window policy, local PTY, SSH/local tabs and splits, focused commands, theme import/sync, and macOS regression coverage.
- `Packages/Citadel/`, `Packages/swift-nio-ssh/` — Swift 6.3 dependency modernization, Sendable/concurrency repairs, bounded protocol deferral and authentication attempts, reconnect cleanup, and SFTP error preservation.
- `memory-bank/releases/codex-completions/` and Memory Bank core files — approved evidence/status update without inventing completion for open phases.

## Patterns Applied

- Reused the existing manager/service boundaries rather than creating parallel connection, forwarding, recording, terminal, or credential paths.
- Kept migration forward-only and add-if-absent so shared legacy sources and concurrent destination writes are preserved.
- Used durable secret-free journals and verified readback/absence for destructive credential and recording operations.
- Kept incomplete Release surfaces hidden or removed instead of exposing inert controls.
- Preserved terminal appearance dimensions independently: opacity paints the theme; blur composites system frost; both zero remains fully transparent.
- Replaced unconditional focus reclamation with explicit ownership, bounded retry, and post-focus caret-theme replay.

## Integration Points

- Session entry paths converge through the shared preparation/opening policy before registration.
- Secret deletion commits metadata first, deletes every key artifact, verifies absence, and records actionable recovery when exact restoration cannot be proven.
- SwiftTerm receives the configured foreground/background, selection, caret, and 16-color ANSI palette; focus replay fixes late-created caret state.
- The terminal tools menu preserves declaration order so Search appears first and Settings remains adjacent to the gear trigger.
- Appearance persistence and session overrides resolve opacity and blur independently through `TerminalGlassAppearance`.
- Native macOS registers its focused workspace command set exactly once at app scope; every window contributes focused actions without duplicating application menus.

## Architectural Decisions

- `memory-bank/decisions.md#2026-07-17-codex-completions-release-scope-and-vision-pro-invariant`
- `memory-bank/decisions.md#2026-07-17-explicit-terminal-focus-ownership-supersedes-periodic-focus-stealing`
- `memory-bank/decisions.md#2026-07-17-forward-only-credential-migration-and-artifact-aware-key-deletion`

## Security and Scan Artifacts

- Gitleaks directory: `/private/tmp/codex-completions-gitleaks/20260717T230527Z-65126204-c18a-4acb-9430-acb4a17fdbea`
- Manifest SHA-256: `91847206a34d2f1ba70f8bacad02c90c8301bc63f5b277f12f60ccf880098d69`
- Raw findings: source 6,639; history 21.
- Classification: ignored generated dependency artifacts, vendored fixtures/examples, synthetic OpenSSH-envelope tests, and documentation phrase false positives.
- Verdict: zero actionable production credentials; no production paths affected. Reports are redacted, checksum-verified, read-only, and tree-invariant.

## Remaining Gates

- Matching Xcode 26.x plus visionOS 26.x full current-tree build/test.
- Physical Vision Pro transparency/blur, Secure Enclave/Optic ID, focus, keyboard, IME/dictation, accessibility, performance, and live network workflows.
- Terminal conformance/performance corpus and representative remote TUI sessions.
- Current sibling glassdb suite and cross-repository acceptance.
- Completion or explicit user-approved disposition of Phases 06–09.
- Signing/provisioning, archive/export, App Store record/listing/privacy/screenshots, TestFlight, merge/tag, fresh-main build, and final go/no-go.

## Artifacts

- Release tracker: `memory-bank/releases/codex-completions/README.md`
- visionOS 27 result bundle: `/tmp/glas-final7-vision27-20260717T1737.xcresult`
- visionOS 26.4 result bundle: `/tmp/glas-final7-vision264-20260717T1742.xcresult`
- Release product: `/tmp/glas-final-release-20260717/Build/Products/Release-xros/glas.sh.app`
- Final macOS Release product: `/tmp/glas-menu-mac-release/Build/Products/Release/glas.sh.app`
