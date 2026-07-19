# Phase 10: Release Validation and Distribution

## Objective

Turn the completed phases into a release candidate with reproducible QA, honest product claims, physical-device validation, and explicit distribution gates.

## Included Items

- `QA-001` through `QA-005` from the release ledger.
- Final closure of every prior phase's acceptance criteria and evidence requirements.
- Existing App Store and TestFlight gates from `memory-bank/release-checklist.md`.

## Current status — Blocked (implementation approved; distribution open)

The code, automated suites, release build, static/security review, and simulator smoke checkpoint are approved. Distribution is still blocked by the explicit open exit criteria below.

## Current Baseline

- Xcode 27.0 (27A5209h) builds successfully with the installed Metal Toolchain.
- The full app test action passes 183/183 on both visionOS 26.4 and visionOS 27.0 arm64 simulators; native macOS passes 20/20.
- NIOSSH passes 331/331; Citadel executes 44 tests with 39 passed and five expected environment-dependent skips.
- GlasSecretStore passes 75/75 tests across 13 suites.
- The generic visionOS Release build passes; the app executable is arm64 with minimum visionOS 26.0 and SDK 27.0. The signed macOS Release is thin arm64 with hardened runtime and runtime 27.0.
- `git diff --check` and the production TODO/FIXME/stub scan pass.
- Independent post-fix audits found no current release blocker in glas.sh or GlasSecretStore. The sibling glassdb migration repair still needs its own current suite and cross-repository acceptance.
- The final UUID-isolated Gitleaks scan found zero actionable production credentials. Artifacts are fully redacted, checksum-verified, read-only, and tree-invariant; raw findings are classified non-production generated dependencies, vendored fixtures, synthetic test envelopes, or documentation phrases.
- Gitleaks evidence: `/private/tmp/codex-completions-gitleaks/20260717T230527Z-65126204-c18a-4acb-9430-acb4a17fdbea`; manifest SHA-256 `91847206a34d2f1ba70f8bacad02c90c8301bc63f5b277f12f60ccf880098d69`; source 6,639; history 21; actionable production credentials 0. A subsequent staged-diff scan also reported zero leaks.
- Both installed simulator apps smoke-launched using `sh.glas.app`; the macOS Release launched as `sh.glas.mac`. Physical Vision Pro rendering, ANSI color, transparency extremes, independent opacity/blur behavior, and macOS chrome were reviewed during the implementation loop. Matching-Xcode-26, complete physical security/input/accessibility/performance evidence, archive/TestFlight, and App Store gates remain open.

## Evidence captured 2026-07-17

- Functional: session entry paths, host-trust prompts, recording lifecycle, SFTP no-clobber transfers, forwarding cancellation, terminal appearance, AI confirmation, and release-hidden feature paths were traced through their live integration points.
- Unit/integration: 164/164 Swift Testing cases passed on each of the visionOS 26.4 and visionOS 27.0 simulators; GlasSecretStore passed 75/75 across 13 suites.
- Penetration: deep-link injection, Keychain namespace collision, host-key rotation, generated-command bypass, OSC link/clipboard policy, SFTP traversal/collision, SOCKS fragmentation/protocol validation, listener lifecycle, bounded storage, and recording deletion were re-audited after fixes.
- Build: the final unsigned generic Release build and both full simulator test actions passed.
- Binary: `file` reports an arm64 Mach-O app; `vtool` reports platform `VISIONOS`, minimum OS `26.0`, SDK `27.0`.

## Work Packages

### 10.1 Test-suite completion (`QA-001`)

- Replace placeholder coverage with unit, integration, migration, security, and terminal-conformance tests.
- Cover session authorization, host-key rotation, secret-store namespaces, recording privacy, SFTP path safety, appearance migration, workspace recovery, sync conflicts, and feature-gated UI.
- Make failures deterministic and preserve artifacts needed for diagnosis.

### 10.2 Compatibility matrix (`QA-002`)

- Validate the supported Xcode/SDK/runtime combinations, including a matching Xcode 26.4 plus visionOS 26.4 run and Xcode 27 plus visionOS 27 run.
- Compare the candidate toolchain with the current supported Xcode release before making the final compatibility judgment.
- Record exact device and simulator identifiers at execution time; do not rely on stale hard-coded destinations.
- Define the minimum supported OS from evidence, not assumption.
- Reject pre-26, Intel, Rosetta, and Catalyst configurations as outside the supported release matrix; verify every qualifying build is arm64.

### 10.3 Toolchain and build documentation (`QA-003`)

- Verify the Metal toolchain and any terminal-engine native artifacts in clean builds.
- Update stale build instructions, supported-toolchain statements, and simulator destinations.
- Confirm a clean checkout can reproduce dependency resolution, compilation, tests, archive, and export.
- Record prerequisites in one maintained build/deployment source and link to it rather than copying volatile identifiers.

### 10.4 Physical-device validation (`QA-004`)

- Test Vision Pro as the primary release platform.
- Verify that the terminal can reach 100% transparency and that opacity and blur sliders remain responsive, independent, understandable, and persistent.
- Exercise Secure Enclave/biometric flows, hardware keyboards, dictation, IME, mouse/pointer behavior, window focus, immersive transitions, memory pressure, and network changes.
- Validate macOS and iPadOS/iOS on their supported feature subsets when those targets are release candidates.

### 10.5 Performance and accessibility (`QA-004`)

- Measure launch, connect, first prompt, sustained output, resize, search, scrollback, restore, and memory behavior.
- Test VoiceOver, Voice Control, Dynamic Type where applicable, Reduce Transparency, Increase Contrast, reduced motion, keyboard navigation, and focus order.
- Accessibility accommodations may change defaults or offer alternate presentation, but must not silently remove the user's ability to choose full terminal transparency.

### 10.6 Privacy and security review

- Complete the security checklist for authentication, authorization, data handling, logging, dependencies, recording, AI, transfers, and sync.
- Verify privacy manifests, entitlements, usage descriptions, Keychain access groups, App Group identifiers, CloudKit containers, and exported data paths.
- Confirm logs, diagnostics, recordings, and screenshots do not disclose credentials or terminal content without explicit user action.

### 10.7 Honest product surface (`QA-005`)

- Reconcile README, website, App Store metadata, screenshots, onboarding, settings, and in-app labels with implemented behavior.
- Verify removed SharePlay and release-hidden HTML Preview, SSH Agent, PTY/compression/agent-forwarding, and sync surfaces stay absent; verify forwarding uses the shared production manager.
- Put the premium Vision Pro transparent-terminal experience at the center of product messaging.
- Ensure screenshots and descriptions demonstrate the real opacity and blur controls without implying unsupported behavior.

### 10.8 TestFlight and App Store gates (`QA-005`)

- Complete signing, archive, export, privacy, entitlement, metadata, and reviewer-note checks from `memory-bank/release-checklist.md`.
- Run a TestFlight cohort with upgrade/migration coverage before production submission.
- Track release-candidate defects in this README and link each fix to its verification evidence.
- Require an explicit go/no-go decision after all blocking items close.

## Release Exit Criteria

- Every ledger item in the release README is `Complete`, `Deferred` with an approved rationale, or `Not applicable` with evidence; no item remains silently open.
- All required automated suites pass on supported configurations.
- Vision Pro physical-device validation confirms the transparent terminal, opacity control, and blur control remain intact.
- Security and privacy reviews have no unresolved release blockers.
- Documentation and store claims match shipped behavior.
- Archive, TestFlight installation, upgrade, rollback/recovery, and App Store submission checks succeed.
- The release owner records an explicit go decision.

## Evidence Required to Close

- Test reports and compatibility matrix.
- Physical-device checklist with OS/build identifiers.
- Performance and accessibility results.
- Security/privacy sign-off.
- Final feature-claim audit.
- TestFlight summary and App Store submission record.
- Completed dashboard and ledger in `README.md`.
