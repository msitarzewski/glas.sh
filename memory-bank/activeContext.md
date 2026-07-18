# Active Context

## Current Focus
- The `codex-completions` implementation and automated-QA checkpoint was approved on 2026-07-17. Functional hardening for the current visionOS candidate is implemented; the repository is now in release validation rather than feature-count expansion.
- The current checkpoint is not an App Store go decision. Physical-device, matching-toolchain, conformance, cross-repository, and distribution gates remain open.
- Working branch: `glass-system-redesign`. The worktree contains active user changes; do not overwrite or revert them.

## What's Next
- **Close the remaining codex-completions release gates.**
  - Finish physical IME/dictation, hardware-keyboard/accessibility, representative TUI, terminal conformance, and performance evidence.
  - Finish recording export/device policy and cross-repository glassdb acceptance.
  - Complete Phases 06–09 or obtain an explicit user-approved `Deferred`/`Not applicable` disposition for each open item.
  - Validate the current tree with matching Xcode 26.x plus visionOS 26.x and run the physical Vision Pro matrix.
- **Preserve the completed security/feature hardening.**
  - One authoritative session-opening path, explicit deep-link confirmation, Keychain-authoritative host trust, namespaced credentials, and hardware-bound signing.
  - Output-only recording default, protected/bounded storage, fail-closed deletion, redacted diagnostics, SFTP no-clobber transfer, and deterministic AI confirmation.
  - SharePlay and unused AI summaries removed, HTML Preview Debug-only, unsupported SSH Agent/inert settings absent, and forwarding backed by the shared manager.
- **Current automated evidence.**
  - 164/164 app tests pass on both visionOS 26.4 and visionOS 27.0 arm64 simulators with zero failures, skips, expected failures, or runtime warnings.
  - GlasSecretStore passes 75/75 tests across 13 suites.
  - The generic Release app is arm64 with minimum visionOS 26.0 and SDK 27.0; simulator installation and smoke launch pass on both runtimes.
  - Independent post-fix audits, `git diff --check`, and the production stub scan pass. The sibling glassdb repair still needs its own current suite and cross-repository acceptance.
  - The final UUID-isolated Gitleaks scan reports zero actionable production credentials; classified raw findings are non-production generated dependencies, vendored fixtures, synthetic tests, or documentation phrases.
- Resume provisioning, TestFlight, and App Store submission only after the Functional release gates in `release-checklist.md` pass.

## Historical Version Zero Audit Snapshot (2026-06-12; superseded by codex-completions)

The present-tense findings below record the pre-hardening baseline. They are retained for provenance and must not be read as current release state.

### Security Follow-up
- Session recordings currently capture raw input and output and store them as ordinary files in Documents (`glas.sh/Models.swift:490`, `glas.sh/SessionRecorder.swift:99`, `glas.sh/SessionRecorder.swift:191`).
- External `glassh://connect` links can initiate saved connections without sharing the normal Secure Enclave preflight path (`glas.sh/glas_shApp.swift:143`, `glas.sh/ConnectionManagerView.swift:583`).
- SSH negotiation automatically retries with legacy SHA-1 compatibility algorithms after a modern negotiation failure (`glas.sh/Models.swift:1053`, `Packages/Citadel/Sources/Citadel/Client.swift:91`).
- Tailscale diagnostics include API-key prefixes and response payloads that may contain sensitive operational data (`glas.sh/TailscaleClient.swift:91`, `glas.sh/TailscaleClient.swift:156`).
- SFTP downloads use the server-provided filename directly at the selected destination and need path/overwrite policy (`glas.sh/SFTPBrowserView.swift:617`).
- AI-generated commands and suggested fixes can execute with one click; destructive actions need deterministic confirmation independent of model-provided risk labels (`glas.sh/AIAssistant.swift:348`, `glas.sh/AIAssistant.swift:435`).

### Definite Functional Dead Ends
- HTML Preview opens the device-local `http://localhost:8080`; it does not use the SSH session, SFTP, or a tunnel (`glas.sh/TerminalWindowView.swift:496`, `glas.sh/HTMLPreviewWindow.swift:152`).
- SharePlay is not attached to the terminal session output path, and received messages are intentionally ignored (`glas.sh/TerminalWindowView.swift:37`, `glas.sh/SharePlayManager.swift:123`).
- Terminal-local port-forward toggles only change displayed state and do not start or stop a tunnel (`glas.sh/TerminalWindowView.swift:881`).
- The standalone port-forwarding window is not opened by current UI and maintains separate transient forwarding state (`glas.sh/glas_shApp.swift:97`, `glas.sh/PortForwardingManagerView.swift:12`).
- Auto-record, save scrollback, maximum scrollback, Tailscale auto-discovery, sidebar visibility, info-panel visibility, and sidebar position are persisted settings without runtime consumers.
- AI session summarization has implementation but no caller or user flow (`glas.sh/AIAssistant.swift:161`).
- SSH Agent remains a selectable authentication method but falls back to password behavior (`glas.sh/Models.swift:1006`).

### Broken Follow-up Paths
- Password-authenticated auto-reconnect, manual reconnect, duplicate session, layout preset, and widget/deep-link launch do not consistently retrieve the saved password before reconnecting.
- These are counted separately from the feature dead ends because the initial connection path works, but the advertised follow-up path does not.

## Functional Hardening Backlog

Priority definitions:
- **P0**: Security boundary or shared architecture required before other functional work.
- **P1**: Release-blocking user-visible behavior.
- **P2**: Complete, hide, or remove before advertising the feature.

### Security

| ID | Priority | Work | Acceptance criteria |
|---|---|---|---|
| `SEC-001` | P0 | Recording privacy and protected storage | Recording defaults to output-only, input capture requires explicit disclosure, files use platform data protection, and retention/export/delete behavior is user-visible and tested. |
| `SEC-002` | P0 | External connection authorization | `glassh://` and widget requests resolve to a confirmation UI before connecting; all connection entry paths share credential and Secure Enclave authorization policy. |
| `SEC-003` | P1 | Legacy SSH algorithm policy | SHA-1 compatibility fallback is disabled by default, enabled per server with a warning, visible in diagnostics, and covered by negotiation tests. |
| `SEC-004` | P0 | Sensitive log redaction | Production logs contain no API-key fragments, OAuth payloads, terminal commands, credentials, or unbounded service response bodies. |
| `SEC-005` | P1 | SFTP destination safety | Remote names cannot escape the selected folder, existing files require an explicit overwrite policy, and unusual names have tests. |
| `SEC-006` | P1 | AI command execution confirmation | Destructive or unclassified generated commands require deterministic confirmation; model-provided risk labels are informational only. |

### Feature Completion

| ID | Priority | Work | Acceptance criteria |
|---|---|---|---|
| `FUNC-001` | P1 | HTML Preview | Preview reaches the intended remote service through an explicit SSH tunnel or remote URL workflow; otherwise the release UI is hidden. |
| `FUNC-002` | P2 | SharePlay | The sharing manager is attached to the terminal session, viewers render output, lifecycle cleanup works, and control remains read-only unless separately authorized; otherwise hide the feature. |
| `FUNC-003` | P1 | Terminal-local port forwarding | Add/toggle/delete controls operate real `PortForwardManager` tunnels and reflect confirmed lifecycle state rather than mutating display state. |
| `FUNC-004` | P2 | Standalone port-forward window | The window opens from a discoverable entry point and shares forwarding state with sessions, or is removed in favor of terminal-local management. |
| `FUNC-005` | P1 | Auto-record sessions | The setting starts and stops recording at session lifecycle boundaries under the `SEC-001` policy, or is removed. |
| `FUNC-006` | P2 | Save scrollback | The setting controls actual persistence with a documented storage location and privacy behavior, or is removed. |
| `FUNC-007` | P1 | Maximum scrollback | Runtime terminal buffering uses the configured value and enforces a safe upper bound. |
| `FUNC-008` | P2 | Tailscale auto-discovery | The setting controls discovery behavior and refresh timing, or is removed. |
| `FUNC-009` | P2 | Sidebar default visibility | The setting changes initial Connections presentation, or is removed. |
| `FUNC-010` | P2 | Info-panel default visibility | The setting changes initial server-detail presentation, or is removed. |
| `FUNC-011` | P2 | Sidebar position | The setting changes supported layout behavior, or is removed if visionOS does not support the promised placement. |
| `FUNC-012` | P2 | AI session summaries | A recording-summary flow is reachable, privacy-scoped, size-bounded, and displays results; otherwise remove the unused implementation. |
| `FUNC-013` | P1 | SSH Agent authentication | Agent auth uses a real agent integration with clear availability errors, or the auth method is unavailable in release UI. It must never fall back to password under the Agent label. |

### Follow-up Connection Flows

| ID | Priority | Work | Acceptance criteria |
|---|---|---|---|
| `FLOW-001` | P0 | Auto-reconnect | Reconnect resolves credentials and authorization through the shared session-opening policy and succeeds for password, imported-key, and Secure Enclave configurations. |
| `FLOW-002` | P0 | Manual reconnect | Reconnect preserves the server configuration, resolves credentials, and reports authorization or connection failures without silently discarding context. |
| `FLOW-003` | P0 | Duplicate session | Duplicate creates and opens a new authorized session, including password and Secure Enclave paths. |
| `FLOW-004` | P0 | Layout presets | Each restored server uses the shared opening policy; partial failures are reported per server without aborting successful sessions. |
| `FLOW-005` | P0 | Widget and deep-link launch | External requests require confirmation, reject invalid or unavailable server IDs, and then use the same credential, host-key, and user-presence policy as normal connections. |

### Execution Order
1. `SEC-002` + `FLOW-001...005`: build the shared session-opening and authorization policy.
2. `SEC-001` + `SEC-004`: protect terminal data and remove sensitive diagnostics.
3. `SEC-003`, `SEC-005`, `SEC-006`: close remaining release security boundaries.
4. `FUNC-003`, `FUNC-005`, `FUNC-007`, `FUNC-013`: fix release-visible controls with direct runtime consequences.
5. `FUNC-001`, `FUNC-002`, `FUNC-004`, `FUNC-006`, `FUNC-008...012`: complete or hide experimental surfaces.
6. Run the Functional release gates and real-device TestFlight matrix.

## Platform Verification Policy
- The checked-in project has a visionOS 26.0 deployment floor and is currently verified with the visionOS 27 SDK. Use installed-SDK inspection plus matching runtime/device evidence; do not infer runtime behavior from compile success.
- For SwiftUI scene routing, external events, window management, LocalAuthentication, Liquid Glass, GroupActivities, WidgetKit, WebKit, and RealityKit behavior:
  1. Inspect the installed SDK interface and compile against the project toolchain.
  2. Check the current official Apple documentation and visionOS release notes.
  3. Verify behavior in the visionOS simulator where possible.
  4. Require physical-device verification for Secure Enclave, eye/hand interaction, immersive presentation, and keyboard focus behavior.
- Official references:
  - [visionOS release notes](https://developer.apple.com/documentation/visionos-release-notes)
  - [OpenWindowAction](https://developer.apple.com/documentation/swiftui/openwindowaction)
  - [onOpenURL](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:))
  - [handlesExternalEvents](https://developer.apple.com/documentation/swiftui/scene/handlesexternalevents(matching:))
  - [LocalAuthentication evaluatePolicy](https://developer.apple.com/documentation/localauthentication/lacontext/evaluatepolicy(_:localizedreason:reply:))
  - [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)

## Build & Dependency State (verified 2026-07-17)
- Xcode 27.0 (27A5209h) / visionOS 27 SDK; visionOS 26.4 and 27.0 simulator test actions pass. Matching Xcode 26.x proof remains pending.
- swift-crypto 4.5.1, swift-nio 2.101.3, swift-log 1.14.0, swift-collections 1.6.0, swift-asn1 1.7.1, swift-argument-parser 1.7.1, SwiftTerm 1.13.0, swift-atomics 1.3.1, swift-system 1.7.4, BigInt 5.7.0
- Vendored Citadel + swift-nio-ssh stay at original tools versions (5.9 / 5.10) to preserve Swift 5 semantics — bumping their tools versions surfaces strict-concurrency errors in static-var declarations and implicit closure captures.
- Build: final unsigned generic Release succeeds; app is arm64-only with minimum visionOS 26.0.
- `CURRENT_PROJECT_VERSION = 2`, `MARKETING_VERSION = 1.0`

## Known Platform Limitations
- Bell audio not spatialized per-window (visionOS has no API for per-window short audio effects)
- No custom passthrough blur (only system Materials)
- SharePlay is not part of this release; its source and entitlement are removed.
- Secure Enclave keys are device-bound (cannot transfer)
- SecureEnclave.isAvailable returns false in simulator
- Xcode 26 ships a separate "Metal Toolchain" component required for SwiftTerm 1.12.0+ (installed in this environment via `xcodebuild -downloadComponent MetalToolchain`)

## Sprint 2 Learnings (apply to future sprints)
- **Window restoration**: `.restorationBehavior(.automatic)` is incompatible with ephemeral in-memory sessions. SSH connections can't survive app quit. Layout presets (reconnect fresh) are the right pattern instead.
- **Window(id:) singleton**: `Window` (not `WindowGroup`) only allows one instance. Calling `openWindow(id:)` on an already-open `Window` crashes. Use `dismiss()` instead, or guard with visibility checks.
- **visionOS focus/keyboard (superseded)**: the earlier two-second unconditional focus timer could steal focus. Production now uses explicit aggregate focus ownership, explicit resign, and bounded key-window-aware retry before replaying the configured caret theme.
- **AVAudioSession**: Must set `.ambient` category to mix with other audio. Default category interrupts media playback.
- **Widget data encoding**: Widget extension must exactly match the main app's `Codable` field types and raw values. Mismatched enum raw values cause silent decode failures (empty data, not crashes).
- **Widget target in pbxproj**: Can be added entirely via pbxproj editing — `PBXFileSystemSynchronizedRootGroup` auto-includes files. Widget needs `NSExtension` / `com.apple.widgetkit-extension` in its own Info.plist.
- **Foundation Models API**: `LanguageModelSession(instructions:)` sets system prompt. `session.respond(to:generating:)` returns `Response<T>` — access generated value via `.content`.
- **visionOS blur**: No API exists for custom gaussian blur of passthrough behind a window. Only system `Material` types provide blur. Don't conflate material frost with blur.
- **Keepalive logic**: Count failures, not sends. `sendKeepAlive()` succeeding proves the transport is alive — only increment missed counter when it throws.

## Dependency Refresh Learnings (2026-05-16)
- **swift-crypto `_CryptoExtras`** transitively exposes `CCryptoBoringSSL`. Citadel imports `CCryptoBoringSSL` directly in `AES.swift` and `RSA.swift`. Keep `_CryptoExtras` listed as a Citadel target dependency even though no Citadel source `import _CryptoExtras`.
- **SPM resolver conservatism**: when no explicit pin exists, the resolver picks the version compatible with the lowest tools-version package in the graph, even if `from:`/range constraints would allow newer. To force absolute latest, edit `Package.resolved` directly with `version` + `revision` SHA fields.
- **Bumping vendored packages' tools-version to 6.x activates Swift 6 strict concurrency** on their source — surfaces static-var and closure-capture errors. Don't bump tools-version on vendored copies unless you're prepared to fix those errors. Constraint widening alone is enough to enable dependency upgrades.
- **`PBXFileSystemSynchronizedRootGroup` auto-bundles `PrivacyInfo.xcprivacy`** — just drop it in the target folder, no pbxproj edits needed. Only `Info.plist` is excluded via `membershipExceptions`.
- **Task cleanup in `@MainActor` observable models**: use `isolated deinit` so actor-isolated tasks can be cancelled without unsafe isolation annotations.
