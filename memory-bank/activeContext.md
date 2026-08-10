# Active Context

## Current Focus (reconciled 2026-08-10)
- The current glas.sh server-form candidate consolidates Add/Edit appearance
  controls and adopts a bounded compact grouped form on macOS without changing
  connection, credential, routing, or persistence behavior. A signed Mac build
  passes and 274/274 Mac unit tests pass. Manual review confirmed the native
  grouped direction and identified one open visual refinement: editable values
  must align to a common trailing axis before final approval.
- glassdb PR [#8](https://github.com/msitarzewski/glassdb.app/pull/8) merged as
  `4b18f79`, carrying the full-row connection selection, simplified actions/detail,
  and unified SQL workspace reviewed after the Phase 08 contract publication.
  This is downstream UX evidence, not glas.sh app migration or cross-device sync.
- Phase 08.1/08.8 is complete: GlasSecretStore PR #4 is merged, the
  Foundation-only GlassConnectionKit version-one endpoint contract is published at
  `0ced944`, and glassdb PR #7 is merged with exact pins for both shared packages.
  App-record migration, per-record storage, eligible credential mobility, CloudKit
  synchronization, onboarding, and physical cross-device acceptance remain open.
- The One Base release was implementation/QA approved on 2026-07-25. One native `glas.sh` application target and scheme now serve iPhone, iPad, visionOS, and native Apple Silicon macOS.
- One `@main` application composes the existing native platform scenes. `Platforms/macOS` is the guarded AppKit/local-PTY implementation boundary; the duplicate Mac application/test targets and scheme are retired.
- The public repository structure was implementation/QA approved on 2026-07-25: Mac sources/resources moved from the misleading `glas.sh-mac` name to `Platforms/macOS`, Mac tests moved beneath `glas.shTests/macOS`, and every moved file retained its original Git blob content.
- Product identity is unified as `sh.glas.app`; SDK-specific plist, entitlements, icons, and widget filtering preserve shared GlasSecretStore, app-group, Keychain, iCloud, terminal, and platform behavior.
- The approved One Base release was merged to `main` through PR [#30](https://github.com/msitarzewski/glas.sh/pull/30); merge commit `d9237f97` and GitHub are the canonical publication record.
- This completion is not an App Store distribution decision. Physical Vision Pro SSH to the development Mac over Tailscale now works, but the full device matrix, initial terminal sizing, native session-sidebar dismissal, distribution certificate trust/notarization, final hosted Mac XCTest after the render-only delta, and external dependency-advisory querying retain explicit evidence boundaries in the release dashboard.
- Working branch: `codex/server-form-layout` (based on
  `codex/native-mac-terminal-chrome`).

## What's Next
- **Preserve the completed One Base publication.**
  - PR [#30](https://github.com/msitarzewski/glas.sh/pull/30) and merge commit `d9237f97` are the canonical review and merge record.
  - Retain baseline `c9f7a406` and the approved single-diff governance variance.
- **Continue native terminal UX work from the public platform boundary.**
  - Keep Mac-only titlebar, sidebar, AppKit window, local PTY, tab, and split behavior in `Platforms/macOS`.
  - Keep shared connection, credential, trust, terminal, workgroup, theme, and appearance behavior in the unified application core.
  - The approved model-owned `.sidebarAdaptable` terminal workspace now replaces
    the former AppKit tab-group mirror. `SessionManager` and the workspace model
    own selection, lifetime, explicit close, restoration, and transactional
    movement between windows.
  - Connections and terminal windows use one native automatic sidebar control,
    full-height sidebar material, and matching unified compact titlebars.
    Terminal identity and separate global/terminal tool clusters remain stable
    as the sidebar opens, closes, or adapts at compact widths.
  - The same authoritative workgroup/session intentions drive the system
    visionOS tab ornament and session sidebar, native iPad top-tab/sidebar
    adaptation, and compact iPhone switching.
  - Preserve independent spatial windows, one bottom tools ornament per window,
    fully transparent terminal canvases, and fully opaque terminal glyphs.
- **Close remaining distribution/device evidence.**
  - Preserve the successful physical Vision Pro -> Mac SSH/Tailscale result, then run the remaining interaction, accessibility, performance, security, and distribution-signing/notarization matrix.
  - Resolve the initially undersized Vision terminal scene and provide a discoverable native session-sidebar dismissal route without adding a custom tab/sidebar authority.
  - Re-run final hosted Mac unit/UI tests after the protected stale `testmanagerd` state clears.
  - Run an approved dependency-advisory service or provision an offline OSV database.
- **Continue Phase 08: the Magic / First Class Glass-family connection experience.**
  - Deliver the user model **My Connections**: define once, find everywhere,
    and connect with the least intervention compatible with honest security.
  - Extend the published neutral endpoint contract into product overlays and
    per-record migration/storage before any CloudKit synchronization code.
  - Use the canonical acceptance path: define an SSH connection in glas.sh on
    iPhone, then select and use it in glassdb on Vision Pro as the tunnel to a
    database without re-entering eligible connection or credential data.
  - Preserve `SYNC-001` and `SYNC-008` as complete foundation work. `SYNC-002`
    through `SYNC-007` remain open until their implementation and verification.
  - Finish the glas.sh native server-form value-column alignment and manual Add/Edit
    acceptance without changing the shared connection or credential contract.
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
  - The 2026-08-10 server-form candidate passes a signed native Mac Debug build
    and 274/274 Mac unit tests. A focused local Mac UI run failed before form
    validation at the existing Window-menu recovery assertion, so no UI pass is
    claimed. Local foreground GUI automation now requires explicit user approval;
    simulator work remains allowed.
  - The 2026-07-30 adaptive-workspace publication checkpoint passes 274/274 native Mac unit tests with zero failures, skips, or runtime warnings. Exact-current visionOS 27, iPadOS 27, and iOS 27 simulator builds also pass.
  - The final native-chrome diff check and production incomplete-marker scan are clean. User visual review approved the Connections and terminal layouts. The unbounded Mac UI harness was stopped after its host runner stalled between app launches; no UI-suite pass is claimed for that run.
  - Public platform-boundary cleanup passes 251/251 Mac tests, iPhone 17 Pro and Vision Pro 27 simulator builds, and simulator install/launch smokes on both products.
  - iPhone and iPad iOS 27 unit suites pass 232/232 each; iPad full UI passes 2/2 and final compact iPhone smoke passes 1/1 with zero runtime warnings.
  - visionOS 26.4 and 27 unit suites pass 229/229 each; 26.4 app smoke passes and 27 UI completes with one pass plus one explicit simulator-input skip.
  - A fresh exact-current native arm64 Mac Release archive and direct launch pass with zero compiler/analyzer warnings. The immediately preceding unified-host suite passes 251/251; final hosted XCTest is blocked by protected stale `testmanagerd`.
  - GlasSecretStore passes 76/76 at accepted revision `9be45c9` and hosted CI is
    green. GlassConnectionKit passes 11/11 plus release build and hosted CI at
    `0ced944`; RealityKitContent builds.
  - Final diff, project/plist/entitlement, production incomplete-marker, target/scheme/product, duplicate-entry, and tracked-diff Gitleaks scans pass.
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

## Build & Dependency State (verified 2026-08-09)
- One Swift 6 `glas.sh` application target and scheme support macOS, iOS/iPadOS, and visionOS 26+; exact-current Xcode 27 destination builds pass. Matching Xcode 26.x archive/runtime proof remains pending.
- swift-crypto 4.5.1, swift-nio 2.101.3, swift-log 1.14.0, swift-collections 1.6.0, swift-asn1 1.7.1, swift-argument-parser 1.8.2, SwiftTerm 1.15.0, swift-atomics 1.3.1, swift-system 1.7.4, BigInt 6.0.0, GlasSecretStore accepted revision `9be45c91d145333252e3f5b03a5e5b6e6349e3e6`, GlassConnectionKit published revision `0ced944e3a9799201f6563f057f7f760e9e7b988` (glassdb adopted it; glas.sh and GlasSecretStore integration remain staged per Phase 08)
- Vendored Citadel + swift-nio-ssh stay at original tools versions (5.9 / 5.10) to preserve Swift 5 semantics — bumping their tools versions surfaces strict-concurrency errors in static-var declarations and implicit closure captures.
- Build: the unified app is Apple Silicon/arm64-only with OS 26.0 deployment floors and current bundle identifier `sh.glas.app`.
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
