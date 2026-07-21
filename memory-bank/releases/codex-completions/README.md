# Codex Completions Release Program

## Purpose

This program converts the external assessment at `../docs/glas.sh-results.txt`, the Functional Hardening backlog in `memory-bank/activeContext.md`, and the 2026-07-17 Codex review into an executable sequence of releases.

The program is complete only when every item in the canonical ledger below is either:

- implemented and supported by review and verification evidence;
- deliberately hidden from release builds with verification evidence; or
- explicitly deferred by the user with a documented rationale and destination milestone; or
- proven not applicable to the supported release scope, with user approval and evidence.

## Product invariant: the reason glas.sh exists

glas.sh is first and foremost a premium terminal experience for Apple Vision Pro. The defining capability is a terminal window that can be made genuinely 100% transparent, with user-controlled opacity and blur.

This is a non-negotiable release invariant:

- The terminal must retain a true 100% transparent mode.
- Opacity and blur remain independently understandable, continuously adjustable controls.
- A readable default or accessibility recommendation must not clamp away full transparency.
- Liquid Glass may shape navigation, ornaments, toolbars, and controls, but it must not replace the user-controlled transparent terminal canvas.
- Native macOS, iPadOS, and iOS work is secondary to preserving the premium Vision Pro experience.
- Appearance migrations must preserve existing global and per-session intent.

This corrects the audit's recommendation that the terminal canvas should always remain opaque or near-opaque (`../docs/glas.sh-results.txt:207`). The release program keeps the audit's contrast and glass-layering concerns as design and accessibility requirements, while preserving transparency as a core product feature.

Current integration points are `glas.sh/SettingsManager.swift:1130`, `glas.sh/SettingsView.swift:574`, `glas.sh/TerminalWindowView.swift:574`, and `glas.sh/TerminalWindowView.swift:603`.

## Supported release platform

- Apple operating systems version 26 or newer.
- Apple Silicon only; Intel and Catalyst are outside this release scope.
- visionOS is the primary product platform and physical Vision Pro is the release reference device.
- Native macOS, iPadOS, and iOS targets must use the shared arm64/OS 26+ core and cannot weaken the Vision Pro experience.

## Approved implementation checkpoint — 2026-07-17

The user approved the current code and automated-QA checkpoint on 2026-07-17. This approval authorizes the Memory Bank update; it is not the final App Store go decision.

- The current visionOS candidate builds as an arm64-only Mach-O with minimum visionOS 26.0 using Xcode 27.0 (27A5209h) and SDK 27.0.
- The full app test action passes 164/164 on both visionOS 26.4 and visionOS 27.0 arm64 simulators, with zero failures, skips, expected failures, or runtime warnings.
- GlasSecretStore passes 75/75 tests across 13 suites.
- `git diff --check`, the production TODO/FIXME/stub scan, independent release/security audits, and the final unsigned Release build pass.
- The final isolated Gitleaks source/history scan found zero actionable production credentials. Raw detections are confined to ignored generated dependency artifacts, vendored fixtures/examples, synthetic key-envelope tests, and documentation phrase false positives.
- The installed app smoke-launches on both simulator runtimes using bundle identifier `sh.glas.app`.

Distribution remains blocked on the open ledger items, especially matching-Xcode-26 proof, physical Vision Pro/security/input/accessibility/performance checks, cross-repository glassdb acceptance, the terminal conformance corpus, explicit completion or deferral of Phases 06–09, signing, archive, TestFlight, and App Store gates.

## Approved native-platform checkpoint — 2026-07-19

- The user approved the native macOS/visionOS parity candidate after iterative visual review on macOS and physical Vision Pro.
- The native Apple Silicon/macOS 26+ target now provides local PTY and saved-host SSH terminals, multiwindow workspaces, tabs, splits, focused menus, secure keyboard entry, native window chrome, and platform-consistent terminal footer actions.
- The terminal canvas remains independently tintable, transparent, and blurred. Full transparency remains available, while ANSI glyphs render above the glass composition and retain their selected sRGB palette.
- Apple Terminal theme import and iCloud theme/appearance synchronization share the existing settings model with visionOS.
- SwiftTerm 1.15.0 remains the production terminal engine. The physical Vision Pro drawing failure was repaired without abandoning the tested CoreGraphics path; a speculative engine rewrite remains outside this checkpoint.
- Final automated evidence: macOS 20/20; visionOS 26.4 183/183; visionOS 27.0 183/183; NIOSSH 331/331; Citadel 39 passed with five expected environment skips; GlasSecretStore 75/75.
- The macOS Release is a signed thin arm64 binary with hardened runtime, runtime 27.0, bundle identifier `sh.glas.mac`, and a packaged `AppIcon.icns`.
- Final `git diff --check`, production marker scan, and isolated tracked/untracked Gitleaks scans pass.

## Approved terminal-settings recovery — 2026-07-20

- Restored reliable access to the existing `Terminal`, `Overrides`, and `Port Forwarding` sections by placing their segmented selector in persistent sheet content rather than the principal toolbar.
- Per-session tint, opacity, blur, material, theme, cursor, and forwarding behavior continues through the existing settings/session models; no parallel appearance store was introduced.
- Regression coverage enumerates all three historical destinations and labels on macOS and visionOS.
- macOS tests passed 27/27; the complete visionOS suite passed serially; macOS and visionOS Release builds passed; diff, production-marker, and isolated Gitleaks scans were clean.
- Task evidence: `memory-bank/tasks/2026-07/200726_terminal-settings-section-recovery.md`.

## Status vocabulary

| Status | Meaning |
|---|---|
| `Not started` | No approved implementation work has begun. |
| `In progress` | Work exists but its milestone exit gate has not passed. |
| `Blocked` | Progress requires a documented external decision or dependency. |
| `QA` | Implementation is complete and verification is running or awaiting evidence. |
| `Complete` | Acceptance criteria, tests, review, and required documentation are complete. |
| `Deferred` | User-approved movement to a later named milestone. |
| `Hidden` | Incomplete functionality is unavailable in release UI and that state is tested. |
| `Not applicable` | User-approved exclusion because the item does not apply to the supported release scope, with evidence. |

## Program dashboard

| Phase | Milestone | Status | Depends on | Exit gate |
|---|---|---|---|---|
| [00](./00-baseline-and-governance.md) | Baseline and governance | Complete | None | Ledger, evidence rules, toolchain matrix, and release policy approved |
| [01](./01-session-state-and-authorization.md) | Session state and authorization | QA | 00 | One authoritative server/session-opening path with flow tests |
| [02](./02-secrets-authentication-and-host-trust.md) | Secrets, authentication, and host trust | In progress | 01 | Namespaced secrets, bound authorization, explicit crypto policy, authoritative host trust |
| [03](./03-recording-logging-transfer-and-ai-safety.md) | Recording, logging, transfer, and AI safety | In progress | 01, 02 | Protected recording, redacted logs, safe SFTP, deterministic AI execution policy |
| [04](./04-terminal-correctness-and-engine-boundary.md) | Terminal correctness and engine boundary | In progress | 00, 01 | SwiftTerm behind a tested boundary; terminal input/search/protocol correctness gates pass |
| [05](./05-feature-completion-and-honest-ui.md) | Feature completion and honest UI | QA | 01, 03, 04 | Every visible feature completes end to end or is hidden; transparency invariant passes |
| [06](./06-native-platform-foundation.md) | Native platform foundation | QA | 02, 04 | Shared core boundaries and native platform target plan validated without Vision Pro regression |
| [07](./07-workspaces-and-shell-integration.md) | Workspaces and shell integration | In progress | 04, 06 | Semantic shell and resumable workspace flows pass platform tests |
| [08](./08-glassdb-metadata-sync.md) | glassdb metadata synchronization | Not started | 02, 06 | Versioned schema, atomic local sharing, and deterministic optional sync policy |
| [09](./09-terminal-engine-evaluation.md) | Terminal engine evaluation | Not started | 04, 07 | Measured SwiftTerm/libghostty decision recorded with evidence |
| [10](./10-release-validation-and-distribution.md) | Release validation and distribution | Blocked | 01–09 as applicable | Security, conformance, compatibility, device, TestFlight, and App Store gates pass |

## Current verified baseline

- Branch: `agent/macos-27-terminal`, based on `origin/main`, with the final implementation approved for publication.
- Toolchain: Xcode 27.0 (27A5209h), SDK 27.0, Metal Toolchain installed.
- App tests: 183/183 passed on visionOS 26.4 arm64 Simulator and 183/183 passed on visionOS 27.0 arm64 Simulator; native macOS tests pass 20/20.
- Package tests: NIOSSH 331/331; Citadel 39 passed with five expected live-environment skips; GlasSecretStore 75/75.
- GlassDBKit's locally executable coverage passed at the prior checkpoint; environment-dependent live-service cases remain external gates.
- Release architecture: the generic visionOS Release build is an arm64 Mach-O with `LC_BUILD_VERSION` platform `VISIONOS`, minimum OS 26.0, and SDK 27.0.
- Defining appearance path: SwiftTerm retains a clear backing; opacity and blur are independent; both zero produces full transparency; selected frost, font, selection, caret, and ANSI colors reach the live terminal. The tools menu uses fixed declaration order so its first action is not clipped by automatic reversal.
- Security re-audit: the glas.sh and GlasSecretStore recording, SFTP, listener, credential, host-trust, forwarding, generated-command, and deep-link findings are repaired. Credential migration is forward-only and collision-safe; SSH-key deletion is transactional, artifact-aware, and fails closed when an incomplete representation cannot be reconstructed. The external glassdb migration finding remains open until accepted in that repository.
- Secret scan: the latest accepted immutable artifacts are under `/private/tmp/codex-completions-gitleaks/20260717T230527Z-65126204-c18a-4acb-9430-acb4a17fdbea`; manifest SHA-256 is `91847206a34d2f1ba70f8bacad02c90c8301bc63f5b277f12f60ccf880098d69`. Source reported 6,639 classified non-production detections and history reported 21; actionable production credentials: 0. Tree invariance passed and reports are fully redacted, checksum-verified, and read-only. A subsequent staged-diff scan also reported zero leaks.
- Remaining gates: a matching Xcode 26.x build/test run, physical Vision Pro transparency/security/input/accessibility/performance validation, live external-service workflows, the full terminal conformance corpus, cross-repository work, explicit completion or deferral of Phases 06–09, and signing/TestFlight/App Store distribution.

## Canonical item ledger

Each item has one owning phase. Cross-cutting phase documents may reference an item, but completion is recorded only here.

### Session and authorization

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `SES-001` | Preserve and finish the centralized session-opening policy for normal connect, reconnect, duplicate, layout, widget, deep-link, and auto-reconnect flows | `../docs/glas.sh-results.txt:47`; `memory-bank/activeContext.md#Follow-up Connection Flows` | 01 | QA |
| `SES-002` | Replace the two independently cached `ServerManager` instances with one authoritative source so edits, deep links, jump chains, and last-connected writes cannot diverge | Codex review; `glas.sh/ConnectionManagerView.swift:15`; `glas.sh/SessionManager.swift:20` | 01 | QA |
| `SES-003` | Require an explicit external connection decision and handle cold-launch, invalid, missing, edited, and deleted server IDs | `../docs/glas.sh-results.txt:47`; `glas.sh/glas_shApp.swift:145` | 01 | QA |
| `SES-004` | Resolve password, imported-key, hardware-key, jump-host, and unsupported-agent behavior consistently on every entry path | `memory-bank/activeContext.md#Follow-up Connection Flows` | 01 | QA |
| `SES-005` | Add deterministic partial-failure reporting and cleanup for multi-server layout restoration | `memory-bank/activeContext.md#FLOW-004` | 01 | QA |

### Secrets, authentication, and SSH trust

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `SEC-001` | Namespace shared Keychain accounts by protocol and purpose and perform a verified one-time glas.sh/glassdb migration | `../docs/glas.sh-results.txt:55` | 02 | QA |
| `SEC-002` | Remove automatic broad legacy SSH downgrade; make compatibility explicit, per-host, confirmed, warned, and tested | `../docs/glas.sh-results.txt:64` | 02 | Complete |
| `SEC-003` | Bind user presence to protected Keychain retrieval or Secure Enclave signing through access control, not a detached preflight prompt | `../docs/glas.sh-results.txt:100` | 02 | QA |
| `SEC-004` | Add the required biometric privacy description | `../docs/glas.sh-results.txt:106`; `glas.sh/Info.plist:5` | 02 | Complete |
| `SEC-005` | Replace the hardcoded team-prefixed Keychain access group with entitlement/build-setting-derived configuration | `../docs/glas.sh-results.txt:137` | 02 | QA |
| `SEC-006` | Add iOS support to GlasSecretStore | `../docs/glas.sh-results.txt:129` | 02 | QA |
| `SEC-007` | Use the data-protection Keychain explicitly for macOS configurations | `../docs/glas.sh-results.txt:132` | 02 | Complete |
| `SEC-008` | Distinguish hardware signing keys from device-wrapped exportable secrets in model names, APIs, and product language | `../docs/glas.sh-results.txt:141` | 02 | Complete |
| `SEC-009` | Add byte-oriented parsing/signing paths and document SecureBytes as damage reduction rather than complete lifecycle protection | `../docs/glas.sh-results.txt:148` | 02 | In progress |
| `TRUST-001` | Make GlasSecretStore authoritative for host trust, with versioned migration, verified counts, and deletion of plaintext legacy copies | `../docs/glas.sh-results.txt:90` | 02 | Complete |
| `TRUST-002` | Preserve first-seen/last-seen history and require explicit host-key rotation approval | `../docs/glas.sh-results.txt:95` | 02 | Complete |
| `TRUST-003` | Revoke or supersede conflicting old host-key pins when a changed key is approved | Codex review; `glas.sh/SessionManager.swift:100`; `glas.sh/Models.swift:1521` | 02 | Complete |

### Recording, logs, transfer, and generated commands

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `REC-001` | Make recording output-only by default | `../docs/glas.sh-results.txt:73` | 03 | Complete |
| `REC-002` | Require separate explicit consent before capturing keystrokes and explain remote-prompt credential risk | `../docs/glas.sh-results.txt:80` | 03 | Complete |
| `REC-003` | Show a persistent recording and input-capture indicator | `../docs/glas.sh-results.txt:82` | 03 | Complete |
| `REC-004` | Stop and finalize recordings automatically on disconnect, close, and failure | `../docs/glas.sh-results.txt:83` | 03 | Complete |
| `REC-005` | Apply `complete` or justified `completeUnlessOpen` file protection and define retention, export, and deletion | `../docs/glas.sh-results.txt:84`; `memory-bank/activeContext.md#SEC-001` | 03 | In progress |
| `REC-006` | Record live terminal dimensions rather than fixed metadata | `../docs/glas.sh-results.txt:85` | 03 | Complete |
| `LOG-001` | Remove credential fragments and untrusted response bodies from Tailscale logs, encode form values, and cap diagnostics | `../docs/glas.sh-results.txt:109` | 03 | Complete |
| `SFTP-001` | Validate remote basenames and destination containment | `../docs/glas.sh-results.txt:112` | 03 | Complete |
| `SFTP-002` | Stream to protected temporary files with collision policy, cancellation/resume, verification, and atomic rename | `../docs/glas.sh-results.txt:113` | 03 | Complete |
| `AI-001` | Put generated commands into an editable composer and classify control operators, destructive tools, privilege escalation, and credential operations independently of model labels | `../docs/glas.sh-results.txt:116` | 03 | Complete |

### Terminal correctness and architecture

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `TERM-001` | Introduce a narrow replaceable `TerminalEngine` boundary and keep SwiftTerm as the first implementation | `../docs/glas.sh-results.txt:154` | 04 | Complete |
| `TERM-002` | Search the live emulator buffer rather than `TerminalSession.output` | `../docs/glas.sh-results.txt:173` | 04 | Complete |
| `TERM-003` | Prevent the focus-maintenance timer from stealing focus from search, sheets, composers, and other controls | `../docs/glas.sh-results.txt:176` | 04 | Complete |
| `TERM-004` | Implement terminal delegates for links, clipboard, working directory, and semantic content | `../docs/glas.sh-results.txt:179` | 04 | Complete |
| `TERM-005` | Add multiline and bracketed-paste review | `../docs/glas.sh-results.txt:182` | 04 | Complete |
| `TERM-006` | Define and enforce OSC 52 clipboard policy | `../docs/glas.sh-results.txt:182` | 04 | Complete |
| `TERM-007` | Validate OSC 8 links before opening | `../docs/glas.sh-results.txt:182` | 04 | Complete |
| `TERM-008` | Support and validate IME composition and dictation | `../docs/glas.sh-results.txt:182` | 04 | In progress |
| `TERM-009` | Complete hardware-keyboard mapping and accessibility validation | `../docs/glas.sh-results.txt:183` | 04 | QA |
| `TERM-010` | Wire cursor style, cursor blinking, maximum scrollback, and save-scrollback behavior to the emulator | `../docs/glas.sh-results.txt:185` | 04 | Complete |
| `TERM-011` | Build a conformance corpus covering vttest, tmux, ncurses, Vim/Neovim, alternate screen, resize/reflow, fragmented UTF-8, graphemes, RTL, OSC 8/52/133, mouse modes, and large scrollback | `../docs/glas.sh-results.txt:188` | 04 | In progress |
| `TERM-012` | Measure rendering, graphemes, ligatures, synchronized output, Kitty graphics/keyboard, and latency against the stated premium target | `../docs/glas.sh-results.txt:157` | 04 | Not started |

### Vision Pro experience and visible feature truth

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `VIS-001` | Preserve a genuinely 100% transparent terminal mode | User correction, 2026-07-17 | 05 | QA |
| `VIS-002` | Preserve clear, continuous user control over terminal opacity | User correction, 2026-07-17 | 05 | QA |
| `VIS-003` | Preserve clear, continuous user control over terminal blur independently from opacity | User correction, 2026-07-17 | 05 | QA |
| `VIS-004` | Migrate legacy global and per-session glass settings without silently discarding opacity, blur, material, or tint intent | Codex review; `glas.sh/SettingsManager.swift:91`; `glas.sh/WindowRecoveryManager.swift:57` | 05 | Complete |
| `VIS-005` | Use Liquid Glass deliberately for navigation and controls, avoid accidental glass-on-glass, and provide contrast/accessibility guidance without removing transparency | `../docs/glas.sh-results.txt:207`; user correction | 05 | QA |
| `FEAT-001` | Complete SharePlay authorization, rendering, read-only behavior, roles, cleanup, and audited input—or hide it | `../docs/glas.sh-results.txt:251` | 05 | Hidden |
| `FEAT-002` | Connect terminal-local port-forward controls to the real shared forwarding manager | `../docs/glas.sh-results.txt:254` | 05 | Complete |
| `FEAT-003` | Consolidate or remove the standalone forwarding window's separate transient state | `memory-bank/activeContext.md#FUNC-004` | 05 | Complete |
| `FEAT-004` | Give HTML Preview an explicit tunnel or remote-origin policy, scheme/host validation, and visible origin—or hide it | `../docs/glas.sh-results.txt:257` | 05 | Hidden |
| `FEAT-005` | Disable SSH Agent UI until an app-owned agent design is implemented and tested | `../docs/glas.sh-results.txt:260` | 05 | Hidden |
| `FEAT-006` | Hide or fully wire requestPTY, compression, and agent forwarding | `../docs/glas.sh-results.txt:263` | 05 | Hidden |
| `FEAT-007` | Wire auto-record to the protected recording lifecycle or remove it | `memory-bank/activeContext.md#FUNC-005` | 05 | Hidden |
| `FEAT-008` | Wire Tailscale auto-discovery to actual discovery and refresh behavior or remove it | `memory-bank/activeContext.md#FUNC-008` | 05 | Hidden |
| `FEAT-009` | Make sidebar default visibility affect the initial Connections presentation or remove it | `memory-bank/activeContext.md#FUNC-009` | 05 | Hidden |
| `FEAT-010` | Make info-panel default visibility affect the initial server-detail presentation or remove it | `memory-bank/activeContext.md#FUNC-010` | 05 | Hidden |
| `FEAT-011` | Make sidebar position affect supported layout behavior or remove it | `memory-bank/activeContext.md#FUNC-011` | 05 | Hidden |
| `FEAT-012` | Expose AI session summaries through a bounded privacy-aware flow or remove unused implementation | `memory-bank/activeContext.md#FUNC-012` | 05 | Hidden |

### Native platforms, workspaces, synchronization, and engine decision

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `PLAT-001` | Keep visionOS as the premium reference experience: independent terminals, spatial grouping, adaptive geometry, ornaments, accessibility, and privacy | `../docs/glas.sh-results.txt:198`; product invariant | 06 | QA |
| `PLAT-002` | Add a native macOS shell with menus, tabs/splits, secure keyboard entry, and local PTY support | `../docs/glas.sh-results.txt:199` | 06 | Complete |
| `PLAT-003` | Add a native iPadOS shell with multiwindow workspaces, keyboard-first interaction, and adaptive sidebar | `../docs/glas.sh-results.txt:200` | 06 | Not started |
| `PLAT-004` | Add a native iOS shell with compact session switching, focused terminal presentation, and command accessories | `../docs/glas.sh-results.txt:201` | 06 | Not started |
| `PLAT-005` | Reuse and incrementally separate existing package code into terminal core, transport/domain, and spatial-only targets | `../docs/glas.sh-results.txt:203` | 06 | QA |
| `PLAT-006` | Use visionOS 27 for adaptive geometry, toolbar behavior, accessibility, and privacy rather than gratuitous spectacle | `../docs/glas.sh-results.txt:216` | 06 | QA |
| `WORK-001` | Add iTerm2-style command blocks, working directory, exit status, semantic selection, and file references | `../docs/glas.sh-results.txt:162` | 07 | In progress |
| `WORK-002` | Add tabs, splits, semantic history, and layout restoration around fresh/recoverable sessions | `../docs/glas.sh-results.txt:274` | 07 | QA |
| `WORK-003` | Provide tmux/Zellij discovery and attach before considering a custom roaming daemon | `../docs/glas.sh-results.txt:165` | 07 | Not started |
| `SYNC-001` | Define a versioned `EndpointProfile` with stable identity, host, port, username, jump chain, and tags | `../docs/glas.sh-results.txt:235` | 08 | Not started |
| `SYNC-002` | Keep terminal and database settings as app-specific overlays | `../docs/glas.sh-results.txt:236` | 08 | Not started |
| `SYNC-003` | Store same-device metadata atomically in the App Group instead of replacing whole UserDefaults arrays | `../docs/glas.sh-results.txt:237` | 08 | Not started |
| `SYNC-004` | Make private CloudKit/CKSyncEngine synchronization opt-in and limited to non-secret metadata | `../docs/glas.sh-results.txt:238` | 08 | Not started |
| `SYNC-005` | Represent device-bound Secure Enclave keys as unavailable on other devices without substituting credentials | `../docs/glas.sh-results.txt:239` | 08 | Not started |
| `SYNC-006` | Make password/private-key synchronization a separate explicit policy | `../docs/glas.sh-results.txt:242` | 08 | Not started |
| `SYNC-007` | Define tombstones, `updatedAt`, source device, and deterministic conflicts | `../docs/glas.sh-results.txt:243` | 08 | Not started |
| `SYNC-008` | Perform reuse analysis before introducing a small shared-model package; do not place endpoint schema in GlasSecretStore or RealityKitContent | `../docs/glas.sh-results.txt:245` | 08 | Not started |
| `ENG-001` | Run a bounded libghostty integration spike after SwiftTerm hardening | `../docs/glas.sh-results.txt:154` | 09 | Not started |
| `ENG-002` | Compare engines using fidelity, latency, memory, protocol coverage, accessibility, platform fit, and maintainability | `../docs/glas.sh-results.txt:277` | 09 | Not started |

### Validation and release evidence

| ID | Item | Source | Owner | Status |
|---|---|---|---|---|
| `QA-001` | Replace the placeholder test and add security, migration, connection-flow, emulator-conformance, and feature-lifecycle regression coverage | `../docs/glas.sh-results.txt:188`; Codex review | 10 | Complete |
| `QA-002` | Validate Xcode 26.4 with visionOS 26.x and Xcode 27 with visionOS 27; never infer runtime compatibility from compile success alone | `../docs/glas.sh-results.txt:280`; 2026-07-17 verification | 10 | Blocked |
| `QA-003` | Keep the Metal Toolchain prerequisite verified and update stale build documentation and simulator destinations | `memory-bank/techContext.md#SPM Dependency Pins`; 2026-07-17 verification | 10 | Complete |
| `QA-004` | Run real-device checks for Secure Enclave, Optic ID/user presence, transparency/blur, keyboard focus, accessibility, and performance | `memory-bank/activeContext.md#Platform Verification Policy` | 10 | In progress |
| `QA-005` | Verify public README, App Store copy, screenshots, privacy declarations, and feature claims match release behavior | `memory-bank/release-checklist.md#Listing content`; audit scorecard | 10 | QA |

## Completion and evidence rules

1. Work begins with an approved implementation plan citing current code and Memory Bank patterns.
2. New production files require documented reuse analysis.
3. Each ledger item has acceptance criteria in its owning phase document.
4. Every behavior change needs proportionate automated coverage and a manual/device path when platform behavior cannot be simulated.
5. No phase completes with ignored test, build, security, migration, or compatibility failures.
6. Visible incomplete features are hidden rather than described as functional.
7. The Vision Pro transparency invariant is exercised in automated state/migration tests and on physical hardware before release.
8. Completion evidence includes the reviewed diff, commands and results, device/runtime matrix, security review, and user approval.
9. After approval, the applicable phase document and this dashboard are updated; retrospective task documentation is created separately under `memory-bank/tasks/YYYY-MM/`.

## Relationship to existing release material

- `memory-bank/release-checklist.md` remains the v1.0 App Store submission checklist.
- `memory-bank/activeContext.md` remains the current work focus.
- `memory-bank/progress.md` remains the milestone history.
- This directory is the prospective multi-release execution program and canonical audit ledger.
