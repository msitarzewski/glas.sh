# Decisions

## 2026-07-25: One native multiplatform app target supersedes the separate Mac app target
- Status: Approved
- Supersedes: the separate-target portion of `2026-07-19: Native macOS shell reuses the shared terminal core`
- Context:
  - The native Mac shell proved its AppKit workspace, local PTY, tabs, splits, focused commands, and window-material behavior, but a second application target duplicated product identity, scheme, test host, resource, entitlement, and scene configuration.
  - glassdb demonstrates that one native application target can select iOS, macOS, and visionOS SDK behavior without Catalyst.
  - Credentials and trust must remain visible across glass apps through GlassSecretStore and the shared Keychain/app-group contract.
- Decision:
  - Use the existing `glas.sh` target and scheme as the sole application product across iPhone, iPad, visionOS, and native Apple Silicon macOS.
  - Keep one `@main` application and compose the existing native scene graphs through platform boundaries.
  - Retain the native Mac implementation under `Platforms/macOS` as guarded platform source/resources, not as an application target.
  - Use one bundle identifier, `sh.glas.app`, with SDK-specific plist, entitlement, icon, architecture, and extension filtering.
  - Keep the widget as a separate extension binary and keep unit/UI tests as separate test bundles hosted by the unified app.
- Alternatives:
  - Keep the separate Mac app target — rejected because it duplicates build and product authority.
  - Use Mac Catalyst — rejected because the product requires native AppKit windowing, commands, tabs, local PTY behavior, and Apple Silicon-only delivery.
  - Rewrite the native shells into one identical cross-platform view tree — rejected because feature parity requires shared capability with Apple-native presentation.
- Consequences:
  - One scheme exposes My Mac, iPhone, iPad, and Vision Pro destinations.
  - Shared credentials, defaults, themes, trust, servers, and workgroups retain one product identity and shared storage contract.
  - Platform-only source must maintain complete compile-time guards and one scene/command registration authority.
  - Public source organization mirrors the target graph: shared application code in `glas.sh`, native Mac adaptations in `Platforms/macOS`, and Mac-only tests in `glas.shTests/macOS`.
  - The historical separate target remains recoverable from baseline commit `c9f7a406`, but is absent from the current project.
- References: `memory-bank/releases/one-base/README.md`, `memory-bank/tasks/2026-07/250726_one-base-release.md`

## 2026-07-21: Shared Connection Library projection with native platform shells
- Status: Approved
- Context:
  - Saved profiles, tags, favorites, recents, workgroup recipes, and optional network discovery were presented through duplicated platform-specific navigation state.
  - visionOS ornaments, macOS/iPadOS split views, and compact iPhone navigation require different composition without forking product behavior.
  - Optional Network visibility previously risked synchronous Keychain work in SwiftUI render evaluation.
- Decision:
  - Add one transient `ConnectionLibraryProjection` over existing authoritative stores; collections remain normalized tag views and workgroups remain recipes/runtime groups.
  - Build the projection once per body evaluation and cache network credential presence outside the render hot path.
  - Share capability, selection, filtering, and action semantics while using native platform shells rather than identical view trees.
  - Extend the existing primary iOS/visionOS app target and shared managers; do not create a second iPhone/iPad product core.
  - Remove replaced connection sections, filter flags, helper projections, and abandoned routes in the same release.
- Alternatives:
  - Persist a new collection/library database — rejected because tags and existing managers already own the data.
  - Build separate platform connection hubs — rejected because it duplicates domain, security, and routing behavior.
  - Read Keychain state directly from body-fed computed properties — rejected because synchronous secret-store calls block rendering and execute repeatedly.
- Consequences:
  - All platforms expose the same Library behavior with native navigation.
  - Connection/session authorization and terminal appearance remain authoritative and unchanged.
  - `ConnectionManagerView.swift` grows in raw presentation lines for four native shells, while duplicate domain/navigation state is removed.
  - Xcode 27 beta UI-runner finalization and physical CoreDevice launch-capture limitations remain explicitly recorded evidence boundaries.
- References: `memory-bank/releases/connection-library/README.md`, `memory-bank/tasks/2026-07/210726_connection-library-release.md`

## 2026-02-07: Adopt memory-bank structure from AGENTS.md
- Status: Approved
- Context: Project needed durable, structured context and task history outside runtime app source.
- Decision: Create `memory-bank/` core files and move legacy markdown task docs into dated monthly task records.
- Consequences: Cleaner source tree, better continuity for future AI/human sessions, explicit task history location.

## 2026-02-16: Preserve key compatibility while enforcing RSA SHA-2 auth framing
- Status: Approved
- Context: Existing users rely on legacy RSA keys, but OpenSSH servers reject legacy `ssh-rsa` userauth signatures. App showed `allAuthenticationOptionsFailed` despite valid keys.
- Decision:
  - Keep RSA key blob format compatibility (`ssh-rsa` key encoding/public key lines).
  - Update userauth request/signature path to RSA SHA-2 (`rsa-sha2-512`) framing and signing behavior.
  - Add explicit auth diagnostics in app UI for faster server/client mismatch triage.
- Consequences:
  - Legacy RSA users stay supported.
  - Modern OpenSSH interop restored without forcing immediate key migration.
  - Additional vendored SSH-layer maintenance responsibility accepted.

## 2026-02-16: Prefer queued terminal chunk handoff + minimal PTY CR/LF override
- Status: Approved
- Context: In-place progress/status updates (carriage-return driven) were intermittently stacking as new lines. Remote PTY settings on affected hosts were already sane, indicating local stream handoff loss under burst output.
- Decision:
  - Keep PTY mode override minimal: set only `OCRNL=0` (disable CR->NL rewrite), avoid forcing `ONLCR`/`ONLRET`.
  - Replace single-value terminal chunk handoff with queued drain semantics between session model and SwiftTerm host update path.
- Consequences:
  - In-place progress rendering behavior is stable across apt/wget/curl-like workloads.
  - Terminal bridge correctness improves under high-frequency output, with modest memory overhead for short-lived pending chunk queues.

## 2026-02-20: Code quality overhaul — single-responsibility files and structured logging
- Status: Approved
- Context: `Managers.swift` had grown to 1,564 lines combining unrelated concerns (server management, settings, keychain, SSH config parsing, port forwarding, window recovery). Magic strings for UserDefaults/Keychain keys were scattered across files. `print()` statements used for debugging.
- Decision:
  - Split `Managers.swift` into 10 focused files, each with a single responsibility.
  - Extract all storage key strings into typed enums in `Constants.swift`.
  - Replace all `print()` calls with structured `os.Logger` under subsystem `sh.glas`.
  - Fix concurrency safety issues (`@unchecked Sendable`, force casts).
  - Expand test suite from 3 to 25 tests covering all extracted modules.
- Consequences:
  - Code navigation and maintenance improved significantly.
  - Compile-time safety for storage keys — typos caught at build time.
  - Structured logging enables filtering by category in Console.app.
  - Test coverage provides regression safety for future refactors.

## 2026-02-28: Keychain persistence hardening — error surfacing and AutoFill suppression
- Status: Approved
- Context: Silent `try?` on keychain saves caused "no saved password" errors at connect time with no diagnostic trail. visionOS AutoFill system dialog appeared on credential-style SecureFields, confusing users. Editing a server didn't show the existing saved password.
- Decision:
  - Replace all `try?` keychain saves with `do/catch` + `Logger.keychain.error()` + user-facing alert.
  - Suppress AutoFill on app-managed SecureFields via `.textContentType(.init(rawValue: ""))`.
  - Pre-load existing passwords in edit flows.
  - Migrate keychain entries when host/port/username changes; clean up orphans on auth method switch.
- Consequences:
  - Keychain failures are immediately visible to both developers (logs) and users (alerts).
  - AutoFill no longer interferes with app-managed credential fields.
  - Edit flows show accurate saved state, preventing accidental password loss.

## 2026-03-15: Sprint 1 "Command Center" — close table-stakes gaps
- Status: Approved
- Context: Competitive analysis showed glas.sh missing critical features vs La Terminal (spatial monitoring, cloud AI), Prompt 3 (Mosh, GPU rendering), and Termius (teams, SOC2). Sprint 1 closes the most impactful gaps.
- Decision:
  - Auto-reconnect with exponential backoff, reading setting directly from UserDefaults to avoid SettingsManager coupling.
  - Local port forwarding only in Sprint 1; remote and dynamic deferred. Uses NIO ServerBootstrap + Citadel DirectTCPIP.
  - Jump host via Citadel's existing `SSHClient.jump(to:)` — single hop only, multi-hop deferred.
  - SFTP browser as separate window scene (not inline in terminal) for spatial workflow flexibility.
  - Quick connect via search bar parsing (Option B) rather than separate text field — reuses existing UI.
  - Favorites as first sidebar section with context menu toggle rather than dedicated view.
- Consequences:
  - All 6 table-stakes features ship together, building on existing Citadel infrastructure.
  - Port forwarding, jump host, and SFTP all leverage APIs that were already in Citadel but unexposed.
  - Auto-reconnect and quick connect have minimal dependency footprint (no new packages).
- References: `tasks/2026-03/260315_sprint1-command-center.md`

## 2026-03-15: Shared App Group defaults for cross-app data sharing
- Status: Approved
- Context: glas.sh and glassdb share SSH credentials via Keychain access group, but server configs, SSH key metadata, and trusted host keys were stored in `UserDefaults.standard` (per-app sandboxed), making them invisible across apps.
- Decision:
  - Add App Group entitlement (`group.sh.glas.shared`) to glas.sh (glassdb already had it).
  - Move `servers`, `sshKeys`, `trustedHostKeys` to `UserDefaults(suiteName: "group.sh.glas.shared")`.
  - Run one-time migration at bootstrap with per-app sentinel in `.standard`.
  - Keep all 20+ UI/terminal settings on `.standard` (app-specific by design).
  - Do not delete old `.standard` data (inert backup for downgrade safety).
- Consequences:
  - Both apps can now read shared server/key data.
  - Migration is idempotent and crash-safe.
  - glassdb follow-up PR needed to read from shared suite.

## 2026-03-15: Comprehensive audit fix — NIO lifecycle propagation and app feature wiring
- Status: Approved
- Context: Audit revealed 15+ instances of code that existed but wasn't connected — same class of bug as the terminal input freeze (parentChannelWritabilityChanged never called). Affected NIO event propagation, Citadel exec/SFTP lifecycle, and app-layer settings that had UI but no behavior.
- Decision:
  - Fix all NIO lifecycle propagation gaps (channelInactive, writabilityChanged, GlueHandler close).
  - Fix Citadel API wiring (channelHandlers, inboundChannelHandler, onExit, SFTP initialized).
  - Wire all inert app settings to actual behavior (confirmBeforeClosing, bell, snippets, closeAllSessions).
  - Mark unimplementable features as "Coming Soon" (forwardAgent, compression, port forwarding) rather than showing false active state.
  - Remove confirmed dead code; keep active scaffolding (favorites, progress stages, SE key retrieval).
- Consequences:
  - NIO pipeline events now propagate correctly end-to-end.
  - Every user-visible setting has corresponding behavior.
  - Users are no longer misled by features that don't work.
  - Dead code removed reduces maintenance burden and confusion.
- References: `tasks/2026-03/260315_comprehensive-audit-fix.md`

## 2026-03-16: Sprint 2 "Spatial Leap" — on-device AI, spatial audio, widgets
- Status: Approved
- Context: Sprint 2 targets visionOS 26 differentiators — Foundation Models (private AI), spatial audio, WidgetKit. No competitor (La Terminal, Prompt 3, Termius) has on-device AI or spatial audio on visionOS.
- Decisions:
  - Gate all Foundation Models code behind `#if canImport(FoundationModels)` — allows building on older SDKs.
  - Use `@Generable` structs with `@Guide` annotations for structured AI output (`CommandSuggestion`, `ErrorExplanation`).
  - Create fresh `LanguageModelSession` per request (4K token limit too small for conversation history).
  - Use `AVAudioPlayer` with `.ambient` audio session for bell sounds — mixes with other audio, doesn't interrupt media.
  - Source authentic VT100 bell sound from open-source `terminal_beeps` repo rather than generating synthetic tone.
  - Layout presets (reconnect fresh) instead of window restoration — SSH sessions are ephemeral, can't survive app quit.
  - Widget extension target added via direct pbxproj editing — `PBXFileSystemSynchronizedRootGroup` auto-syncs directory contents.
  - Widget `WidgetServerConfig` must exactly match app's `ServerConfiguration` Codable encoding (lowercase enum raw values).
  - SFTP download flow: pick destination folder first via `.fileImporter(.folder)`, then stream download with chunked progress — avoids visionOS z-order issue with system save dialogs.
  - Promote frequently-used actions (AI, SFTP) to bottom ornament icon row, not buried in menu.
- Consequences:
  - AI features work on-device, fully private, no cloud dependency.
  - Bell audio mixes cleanly with background media.
  - No ghost windows on app relaunch.
  - Widgets show live server data from shared App Group defaults.
  - SFTP batch operations significantly improve file management workflow.
- References: `tasks/2026-03/260316_sprint2-spatial-leap.md` (in README)

## 2026-03-16: visionOS keyboard focus maintenance timer
- Status: Superseded by the approved 2026-07-17 explicit focus-ownership decision below
- Context: visionOS RTI (Remote Text Input) system silently drops first responder from TerminalView after a few seconds of keyboard idle. User loses ability to type — `RTIInputSystemClient remoteTextInputSessionWithID:performInputOperation: perform input operation requires a valid sessionID` errors flood the log.
- Decision: Add a 2-second periodic timer in `SwiftTermHostModel` that checks `isFirstResponder` and re-asserts `becomeFirstResponder()` if lost. Timer starts on attach, stops on disappear.
- Alternatives: Tried initial focus retry (3×50ms) — insufficient for ongoing idle loss. Could override `resignFirstResponder` on TerminalView but SwiftTerm's UIView subclass isn't easily extensible from outside.
- Consequences: Keyboard stays active indefinitely. 2-second timer is lightweight (no-op when already first responder). May cause focus fights if user intentionally focuses another element — mitigated by stopping timer on disappear.

## 2026-03-16: Window restoration incompatible with ephemeral SSH sessions
- Status: Approved
- Context: `.restorationBehavior(.automatic)` was enabled on terminal and SFTP windows for Sprint 2D (persistent layouts). On-device testing revealed: restored windows show "Session not found" because SSH sessions are in-memory and don't survive app quit. Main `Window` (singleton) also restored, creating a duplicate alongside `.defaultLaunchBehavior(.presented)`.
- Decision: Revert ALL windows to `.restorationBehavior(.disabled)`. Use `LayoutPreset` (save server IDs, reconnect fresh on open) as the persistent layout mechanism instead.
- Consequences: No ghost windows on relaunch. Layout presets create fresh connections. Users must reconnect after app quit (expected behavior for SSH clients).

## 2026-05-16: swift-crypto 4.x adoption + PrivacyInfo.xcprivacy + App Store readiness
- Status: Approved
- Context: Pre-WWDC26 push to ship glas.sh on the App Store. Project had not been touched in ~2 months; all SPM deps were stale, swift-crypto major 4.x was available but the vendored Citadel/swift-nio-ssh Package.swift constraints capped at `<4.0.0`, no `PrivacyInfo.xcprivacy` was present (required by App Store since May 2024), and the build number was still `1`.
- Decision:
  - Widen swift-crypto constraint in vendored `Packages/Citadel/Package.swift` and `Packages/swift-nio-ssh/Package.swift` to `..<"5.0.0"`. Keep both at their original tools-versions (5.9 / 5.10) — bumping them activates Swift 6 strict concurrency on the vendored source and surfaces static-var / closure-capture errors.
  - Keep `_CryptoExtras` listed as a Citadel target dependency even though no Citadel source imports it directly — it transitively exposes `CCryptoBoringSSL`, which Citadel's `RSA.swift` and `AES.swift` do import directly. Removing it breaks the build.
  - Force-pin all other SPM deps to absolute latest via explicit `Package.resolved` entries (with both `version` and `revision` SHA). SPM resolver is conservative on free choice and won't pick latest automatically when the package graph contains a low-tools-version package.
  - Install Xcode 26 "Metal Toolchain" component to support SwiftTerm 1.12.0+ (introduced Metal shaders).
  - Add `PrivacyInfo.xcprivacy` to `glas.sh/` and `glasWidgets/` directories. `PBXFileSystemSynchronizedRootGroup` auto-bundles them — no pbxproj edits needed.
  - Manifest declares only `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`). Audit confirmed no file timestamp, disk space, or system boot time API usage.
  - Add `nonisolated` to all 10 `Logger` statics (default-MainActor inference in Swift 6 / Xcode 26 makes module-level statics MainActor-isolated, breaking access from `OSAllocatedUnfairLock.withLock` closures).
  - Add `nonisolated` to `PromptingHostKeyValidator.cacheKey`.
  - Add `@MainActor` to `SwiftTermHostView.Coordinator.dismissEditMenu()` — `@objc` selector called from `UITapGestureRecognizer` target on main thread.
  - Leave the 4 `nonisolated(unsafe)` Task properties in `Models.swift:312-319` as-is. Swift compiler suggests `nonisolated` but its own language rules reject `nonisolated` on mutable stored properties. `nonisolated(unsafe)` is the only form that compiles and provides the escape hatch needed for `deinit` access. Accept the "has no effect" warning — compiler bug.
  - Bump `CURRENT_PROJECT_VERSION` 1 → 2 across all 6 build configs. Keep `MARKETING_VERSION` at 1.0 for initial submission.
- Alternatives considered:
  - Bumping vendored Citadel/swift-nio-ssh tools-version to 6.1 — rejected after testing: surfaces Swift 6 strict-concurrency errors in vendored source (static-var on non-Sendable types, implicit self captures in closures). Would require source-level changes to vendored audit-fixed code.
  - Re-vendoring from upstream Citadel 0.12.1 / swift-nio-ssh 0.13.0 — rejected: would lose the 8 audit fixes landed 2026-03-15.
  - Using `swiftLanguageMode(.v5)` swiftSetting — would work but adds complexity for marginal benefit; constraint widening alone is sufficient.
- Consequences:
  - All dependencies at absolute latest. Build clean on Xcode 26.4 / visionOS 26.4 SDK with 0 errors and 5 non-blocking warnings.
  - App Store privacy manifest requirement satisfied.
  - Vendored package audit fixes preserved; no source-level changes to Citadel or swift-nio-ssh.
  - Build number ready for first TestFlight upload.
  - SwiftTerm 1.13.0 Metal renderer now available (perf improvements on visionOS).
- References: `tasks/2026-05/260516_dependency-refresh-and-app-store-prep.md`

## 2026-02-28: Migrate SSH key operations to SecureBytes API
- Status: Approved
- Context: GlasSecretStore introduced `SecureBytes` type for secure memory handling. SSH key save/retrieve operations in `KeychainManager` and `SettingsManager` still used raw `String` internally at the keychain boundary.
- Decision:
  - Wrap String to SecureBytes at the KeychainManager save boundary.
  - Extract strings via `.toUTF8String()` / `.toData()` at retrieve sites.
  - Keep public wrapper API unchanged — callers still pass and receive String.
- Consequences:
  - Internal keychain operations use secure memory representation.
  - No API-breaking changes for existing callers.
  - Incremental step toward full secure memory handling for key material.

## 2026-06-12: Transition from Version Zero acceleration to Functional hardening
- Status: Approved
- Context:
  - The Version Zero phase intentionally optimized for rapid product exploration and established a broad native visionOS SSH feature surface.
  - A fresh codebase audit found that several user-visible controls stop before completing their advertised workflow, and some security-sensitive entry paths do not share the same authorization policy.
  - The repository is public and open source, so status documentation should distinguish implemented scaffolding, experimentally reachable behavior, and release-ready end-to-end functionality.
- Decision:
  - Treat work through March 2026 as the **Version Zero rapid acceleration** phase.
  - Begin a **Functional hardening** phase before App Store submission.
  - Define a feature as functional only when its UI entry point, runtime behavior, failure handling, security policy, cleanup, and tests complete end to end.
  - Centralize session opening before fixing individual reconnect-like call sites. The shared policy must resolve credentials, perform user-presence checks, apply host-key policy, and distinguish user-initiated external requests.
  - Complete or hide experimental surfaces rather than leaving controls that imply unsupported behavior.
  - Keep historical sprint records intact, but use `activeContext.md`, `progress.md`, and `release-checklist.md` for current readiness status.
- Initial priority order:
  1. Unified session-opening and authorization policy.
  2. Recording protection and sensitive-log redaction.
  3. Explicit legacy SSH compatibility policy.
  4. SFTP destination safety and AI command confirmation.
  5. HTML Preview, SharePlay, and port-forwarding end-to-end completion or release-build removal.
  6. Security-focused integration tests and TestFlight verification.
- Consequences:
  - App Store submission work pauses until Functional release gates pass.
  - Existing Version Zero code is reused as scaffolding where it has valid integration points.
  - Feature count is no longer used as a readiness proxy; verified end-to-end behavior is the release criterion.

## 2026-07-17: Codex-completions release scope and Vision Pro invariant
- Status: Approved
- Context:
  - The product exists to provide a premium terminal on Apple Vision Pro, including a terminal canvas that can be genuinely 100% transparent.
  - The release targets Apple OS 26 or newer on Apple Silicon, with visionOS as the current shipping target and reference experience.
  - An audit recommendation for a near-opaque terminal conflicted with the product's defining purpose.
- Decision:
  - Preserve independent continuous opacity and blur controls; both at zero must remain a supported fully transparent state.
  - Keep Vision Pro spatial presentation and user choice above generic cross-platform defaults.
  - Use Liquid Glass for controls and hierarchy without forcing opacity onto the terminal canvas.
  - Treat native macOS/iPadOS/iOS, workspace expansion, metadata sync, and alternate-engine evaluation as open program phases until explicitly completed or given a user-approved disposition.
  - Approve the 2026-07-17 code and automated-QA checkpoint, but keep physical-device, matching-Xcode-26, signing, TestFlight, and App Store go/no-go gates open.
- Consequences:
  - Accessibility guidance may recommend readable combinations but cannot clamp away full transparency.
  - The current candidate is arm64-only with a visionOS 26.0 deployment floor.
  - The release program remains honest about unfinished Phases 06–09 and manual/distribution work.
- References: `memory-bank/releases/codex-completions/README.md`, `memory-bank/tasks/2026-07/170726_codex-completions-release.md`

## 2026-07-17: Explicit terminal focus ownership supersedes periodic focus stealing
- Status: Approved
- Context: The earlier two-second first-responder timer prevented RTI idle loss but could reclaim focus from search, sheets, command composition, and other controls. SwiftTerm also creates its caret after becoming first responder, so the initial theme assignment could leave a black caret.
- Decision:
  - Replace unconditional periodic reclamation with aggregate focus ownership, explicit resign, and bounded key-window-aware retry.
  - Replay the configured caret theme after focus succeeds.
  - Preserve live ANSI palette installation independently from default unstyled shell text.
- Consequences:
  - Terminal focus no longer competes with active controls or IME ownership.
  - The focused caret uses the selected theme instead of SwiftTerm's transient default.
  - Physical Vision Pro keyboard/IME/dictation validation remains required.
- References: `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`, `memory-bank/releases/codex-completions/04-terminal-correctness-and-engine-boundary.md`

## 2026-07-17: Forward-only credential migration and artifact-aware key deletion
- Status: Approved
- Context: Shared legacy Keychain sources can be read by more than one app, concurrent destination writes must not be overwritten, and partial SSH-key representations can survive when material retrieval returns `notFound`.
- Decision:
  - Migrations atomically add a destination only when absent, preserve conflicting/concurrent destinations, and never delete shared legacy sources.
  - SSH-key deletion snapshots all generic representations, resolves deterministic legacy Secure Enclave tags, deletes hardware last, verifies expected absence, and restores exact artifacts on recoverable failure.
  - If the original representation cannot be reconstructed, retain a recovery-required journal and fail closed rather than claiming verified restoration.
- Consequences:
  - Migration is retryable and downgrade-compatible without destructive shared-source cleanup.
  - Orphaned passphrases/tags/hardware keys are detected even when full material retrieval is nil.
  - GlasSecretStore's 75-test suite and app regression coverage protect the lifecycle contract.
- References: `Packages/GlasSecretStore/Sources/GlasSecretStore/Keychain/SSHKeyKeychainStore.swift`, `glas.sh/SettingsManager.swift`, `memory-bank/releases/codex-completions/02-secrets-authentication-and-host-trust.md`

## 2026-07-19: Native macOS shell reuses the shared terminal core
- Status: Approved
- Context:
  - macOS needs a day-to-day multiwindow terminal experience with native menus, tabs, splits, local PTY support, and standard window chrome.
  - The Vision Pro product invariant requires full terminal transparency and independent opacity/blur controls to survive every shared-core change.
- Decision:
  - Build a native Apple Silicon/macOS 26+ application target rather than Catalyst.
  - Reuse the shared SSH, trust, settings, themes, terminal engine, and appearance models; keep AppKit window policy and local PTY lifecycle in the macOS target.
  - Register workspace commands once at app scope and route window-specific actions through focused values.
  - Keep SwiftTerm 1.15.0 as the production engine while the current CoreGraphics path satisfies physical Vision Pro rendering; do not begin a terminal rewrite without the separate Phase 09 evidence gate.
- Consequences:
  - macOS gains native local/SSH multiwindow workspaces without forking security or appearance policy.
  - ANSI glyph colors remain independent of the transparent/blurred terminal canvas.
  - iPadOS/iOS shells, a comparative engine spike, and App Store distribution remain separately tracked work.
- References: `Platforms/macOS/MacTerminalWindowPolicy.swift`, `Platforms/macOS/MacWorkspaceView.swift`, `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`, `memory-bank/releases/codex-completions/06-native-platform-foundation.md`

## 2026-07-25: Model-owned adaptive tabs replace AppKit tab-group mirroring
- Status: Approved and implemented
- Context:
  - The product must preserve independent spatial terminal windows on Vision
    Pro while providing compact native session navigation inside each window.
  - The Mac prototype mirrors `NSWindowTabGroup` into a custom
    `NavigationSplitView` and suppresses the native horizontal tab strip through
    KVO, delayed reconciliation, and Window-menu inspection.
  - Apple exposes no supported API that transforms AppKit window tabs into
    native sidebar rows. The Xcode 27 SDK validates `Tab`, `TabSection`,
    `.sidebarAdaptable`, sidebar-only placement, and sidebar header/footer
    composition when targeting OS 26 across macOS, iOS/iPadOS, and visionOS.
  - OS 27 placement and sidebar-availability APIs remain beta and require
    availability gates when the deployment floor is OS 26.
- Decision:
  - Represent one terminal window as one model-owned workspace containing
    native adaptive session tabs; keep any split topology inside the selected
    tab.
  - Use `.sidebarAdaptable` for Mac, iPad, and visionOS presentation while
    retaining the compact iPhone OS 26 switcher.
  - Let visionOS generate the leading root-tab ornament and the workgroup
    session sidebar. Preserve one bottom status/tools ornament per window and
    preserve independent spatial windows.
  - Route Command-T, explicit close, restoration, and Move Tab to New Window
    through authoritative workgroup/session models and value-based
    `WindowGroup` scenes.
  - Use a bounded claim-confirm-remove transaction for live tab transfers.
  - Close sessions and workgroups only through explicit model or scene
    authority; never from adaptive-tab content `onDisappear`.
  - Preserve native material chrome separately from the user-controlled
    transparent, tinted, and blurred terminal canvas; terminal glyphs and cursor
    remain fully opaque.
- Alternatives:
  - Keep AppKit-native window tabs and mirror them into a custom sidebar:
    rejected because it creates two navigation authorities and depends on
    private timing assumptions around tab-strip presentation.
  - Nest the custom Mac `NavigationSplitView` around adaptive tabs: rejected
    because nested navigation containers have independent state and toolbar
    behavior.
  - Force the same geometry on every platform: rejected because shared domain
    behavior does not require shared presentation trees.
- Consequences:
  - AppKit `NSWindowTabGroup` no longer supplies session-tab semantics
    automatically. glas.sh now preserves Command-T, multiple windows, detach,
    restoration, and close behavior through native commands over its workspace
    model.
  - The Mac custom sidebar registry, tab-bar visibility reconciliation, and
    Window-menu probing have been removed. Native SwiftUI adaptive tabs and the
    system automatic sidebar control are the only tab-navigation authority.
  - Connections and terminal scenes use matching unified compact native
    titlebars. A small AppKit window coordinator is retained only for supported
    native window policy and toolbar spacing; it does not create a second
    titlebar, tab model, sidebar, or accessory view.
  - visionOS gains correct system ornament ownership without reducing the
    independent spatial-window or full-transparency product invariant.
  - The implementation remains in the existing `codex-completions` Phase 06/07
    program; no new release is created.
- References: `Platforms/macOS/MacWorkspaceView.swift`, `Platforms/macOS/MacWorkspaceController.swift`, `Platforms/macOS/MacTerminalWindowPolicy.swift`, `glas.sh/VisionTerminalWorkgroupView.swift`, `memory-bank/releases/codex-completions/06-native-platform-foundation.md`, `memory-bank/releases/codex-completions/07-workspaces-and-shell-integration.md`, `memory-bank/systemPatterns.md#Terminal-window-adaptive-presentation-and-ornament-ownership`
