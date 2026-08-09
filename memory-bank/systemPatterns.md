# System Patterns

## One Native Multiplatform Application Target

- `glas.sh` is the sole application target and shared scheme for iPhone, iPad, visionOS, and native Apple Silicon macOS. Use automatic SDK selection, platform-specific deployment settings, and `SUPPORTS_MACCATALYST = NO`; do not create a platform application target to solve a source-boundary problem.
- Keep one application `@main` in `glas.sh/glas_shApp.swift`. Compose native scenes inside that authority with compile-time platform branches so AppKit, UIKit, and visionOS each retain their native navigation, windowing, ornaments, and commands.
- Keep `Platforms/macOS` as a platform implementation boundary, not a product boundary. Complete-file `#if os(macOS)` guards allow its AppKit workspace, local PTY, focused commands, resources, plist, and entitlements to participate in the unified target without leaking into mobile/vision products. Put Mac-specific tests beneath `glas.shTests/macOS` so the public tree mirrors the single app/test target graph.
- Select plist, entitlements, icons, architectures, and embedded extensions with SDK-conditional build settings. Reuse one application bundle identifier and shared GlasSecretStore access groups across app platforms.
- The widget remains a separate extension target because it is a separate executable. Unit and UI tests remain separate test bundles, but both host the unified application target.
- Register package products, synchronized source groups, application commands, and scene identifiers once. Platform-specific presentation may branch; shared connection, credential, trust, settings, workgroup, terminal, and appearance authority must not.
- Retire duplicate targets, products, schemes, test hosts, proxies, and configuration lists only after the unified target passes every available destination and bundle inspection confirms no hidden resource or dependency authority.

## Connection Library Projection and Native Shell Boundary

- Build `ConnectionLibraryProjection` transiently from authoritative `ServerManager.servers`, `SettingsManager.layoutPresets`, and cached optional-network availability. Do not persist Library modes, scopes, normalized collections, counts, or selection-repair state.
- Normalize collections from `ServerConfiguration.tags`; an empty/whitespace-only tag creates no collection, and one profile may participate in multiple collections.
- Deduplicate by authoritative profile identity before ordering or filtering. Stable ordering uses recency followed by name, host, username, and identifier tie-breaks.
- Build the projection once per SwiftUI body evaluation and pass it into navigation/results/detail helpers. Never perform synchronous Keychain reads from a body-fed computed property; cache credential presence and refresh it when settings/lifecycle changes.
- Share mode, scope, result, selection, and action semantics across platforms while composing them natively:
  - visionOS: ornament mode -> optional real child scopes -> results -> details; modes without children begin with results;
  - macOS/iPadOS: native three-column split view;
  - iPhone: compact stack drill-down.
- Presentation may branch by platform, but saved-profile, credential, host-trust, connection, workgroup, and terminal lifecycle behavior stays in existing managers.
- Explicit connection/workgroup/local launch actions cross the scene boundary only after reusing `SessionManager`; selecting a row reveals detail and does not implicitly create a session except the approved macOS double-click shortcut.

## Glass-Family Connection and Credential Contract

- The product invariant is *define once, find everywhere, connect with minimal
  intervention*. UI presents **My Connections** consistently across glas.sh and
  glassdb; implementation details such as CloudKit, Keychain access groups,
  packages, migrations, and record versions stay out of normal onboarding and
  connection flows.
- A neutral, versioned `EndpointProfile` owns only reusable non-secret SSH facts:
  stable endpoint identity, display name, host, port, username, jump-chain
  references, tags, timestamps, deletion state, and schema version.
- Product overlays are keyed by endpoint identity. glas.sh owns terminal and
  workspace behavior; glassdb owns database and tunnel-use behavior. Neither app
  copies or reinterprets the other's settings, and shared-profile migration must
  not reset app-specific presentation or behavior.
- Endpoints reference a stable Glass-family credential identity rather than
  embedding a password, private key, passphrase, or hardware signer. GlasSecretStore
  owns credential identity, credential-kind metadata, availability, Keychain
  policy, secret material, and host trust; it does not become the endpoint-schema
  or app-overlay package.
- Treat three policies as orthogonal:
  - **App sharing** determines which Glass apps may discover an endpoint and its
    credential reference.
  - **Device mobility** determines whether eligible secret material may become
    available on another Apple device after explicit consent.
  - **Authentication kind** determines whether the connection uses a password,
    imported key, device-bound Secure Enclave signer, or another supported method.
- Synced metadata never implies usable credentials. The local app resolves an
  honest availability state before connection: ready, still syncing, sign in to
  iCloud, set up this key on this device, or review host identity. It never
  silently falls back to a weaker credential.
- Host trust and optional-network authorization remain explicit security
  boundaries. The first use of an endpoint on a device may require fingerprint
  review, local key enrollment, user presence, or network authorization; these
  are the only acceptable interruptions to the first-class flow.
- Cross-app and cross-device work must extend the existing `ServerManager`,
  `SharedDefaults`, GlasSecretStore, Keychain, and iCloud integration points.
- The completed Phase 08 reuse analysis found no suitable neutral target in
  glas.sh, glassdb, RealityKitContent, Citadel, GlassDBKit, or GlasSecretStore.
  The Foundation-only `GlassConnectionKit`, consumed at a reviewed exact revision,
  owns only versioned connection value types and pure validation/migration behavior.
  Persistence, CloudKit, Keychain, trust, transport, and UI stay outside it.

## Terminal Architecture
- SSH transport via Citadel and `withPTY` interactive sessions.
- Terminal rendering via the SwiftTerm host view behind the narrow `TerminalEngine`/`SwiftTermHostEngine` boundary in `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`.
- Resize loop: UI geometry -> PTY rows/cols -> remote window change.
- Terminal bell: SwiftTerm fires `bell(source:)` delegate -> `onBell` callback -> visual flash (white overlay) or system audio (sound 1007) based on `bellEnabled`/`visualBell` settings.
- Auth diagnostics surfaced through user-facing + raw error messaging to reduce field debugging time.
- PTY mode policy for in-place progress behavior:
  - explicitly disable CR->NL output translation (`OCRNL=0`)
  - do not force `ONLCR`/`ONLRET` overrides unless a host-specific issue requires it
  - validate against real workloads that rely on carriage-return redraw semantics.
- Stream delivery policy between SSH session and SwiftTerm host:
  - never use single-value overwrite semantics for terminal chunk handoff
  - queue/drain pending output chunks and emit by nonce to avoid dropping control-byte updates under high-frequency output bursts.
- SwiftTerm context menu workaround: the library uses deprecated `UIMenuController.shared` which gets stuck on visionOS (eye+hand input doesn't reliably dismiss it). A `UITapGestureRecognizer` with `cancelsTouchesInView=false` is added in `makeUIView` to call `hideMenu()` on every tap.
- Theme application installs foreground/background, selection, caret, and the full 16-color ANSI palette. Because SwiftTerm creates its UIKit caret during first-responder acquisition, replay the configured caret theme after focus succeeds.
- Terminal appearance keeps theme opacity and system blur as independent dimensions. `TerminalGlassAppearance(opacity:blur:)` clamps each dimension separately; opacity 0 plus blur 0 is the supported fully transparent endpoint.

## SSH Secret Handling Pattern
- App-facing secret API routes through a `SecretStore` abstraction (currently keychain-backed).
- Keychain entries use migration marker + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Migration state is tracked and surfaced in Settings via summary counts/status.
- `StoredSSHKey` metadata carries:
  - storage kind (`legacy`, `imported`, `secureEnclave`)
  - algorithm kind (`rsa`, `ed25519`, `ecdsa-p256`, etc.)
  - migration state (`pending`, `migrated`, etc.)
- UI pattern: every visible key selection/listing includes a key-type badge to avoid ambiguity for mixed-format fleets.
- Shared legacy credential migration is forward-only: atomically add a missing destination, preserve conflicts and concurrent replacement, verify readback, and never delete a source another app or downgrade may still require.
- SSH-key deletion uses a durable secret-free journal. Snapshot all generic representations, resolve a deterministic legacy Secure Enclave tag when metadata is missing, delete recoverable artifacts before hardware, verify expected absence, and restore exact bytes only when provenance is provable. A nil material snapshot on failure is recovery-required, never “restored and verified.”

## SSH Auth Algorithm Pattern
- Keep OpenSSH key blob encoding unchanged for RSA public keys (`ssh-rsa`) while selecting modern userauth signature algorithms (`rsa-sha2-*`) in auth request framing/signing.
- Do not regress legacy users while tightening defaults; compatibility changes are validated against real OpenSSH traces.

## UI Structure
- Multi-window app model with terminal-focused windows.
- Terminal window adaptive presentation and ornament ownership:
  - **Tabbed visionOS workgroup**: SwiftUI's `.sidebarAdaptable` `TabView` owns
    the system leading ornament. Selecting a workgroup `TabSection` reveals that
    same window's native session sidebar. Do not duplicate the ornament modes in
    a custom rail or first in-window column.
    The current sole top-level `TabSection` exposes the system session sidebar
    but does not provide a native destination outside that section to dismiss
    it. Resolve that composition with another native top-level destination or
    an Apple-supported tab/sidebar API; do not add a custom hide overlay or a
    second session-navigation model.
  - **Standalone visionOS terminal**: retain the informational top connection
    ornament (server name + `user@host:port`) until the session is represented
    by the shared workgroup shell.
  - **Bottom ornament**: each terminal window owns its own status and tools
    ornament. An ornament never controls multiple independent spatial windows.
  - **macOS/iPadOS**: use the same model-owned adaptive tabs with native
    platform presentation. Do not mirror AppKit tab groups into a custom
    SwiftUI sidebar or show duplicate tab interfaces.
  - **macOS ownership**: `TabView(.sidebarAdaptable)` is authoritative for
    terminal sessions, while the Connections library keeps its existing
    `NavigationSplitView`. Use Apple's automatic sidebar toolbar item in both
    surfaces; never suppress it, duplicate it, or add a second custom toggle.
  - **macOS titlebars**: Connections and terminal scenes use
    `.windowToolbarStyle(.unifiedCompact)`. Keep global actions and terminal
    tools as separate native toolbar groups; outer icon `HStack`s use six points
    of horizontal edge padding so capsule edges and inter-icon spacing remain
    visually balanced.
  - **Responsive sidebars**: at compact widths, native sidebars overlay content
    instead of clipping terminal columns. On Mac, sidebar material extends
    behind the traffic lights and uses the same system-owned toolbar control as
    Finder and Safari.
  - **AppKit boundary**: the terminal window coordinator may configure supported
    `NSWindow` material/full-size-content behavior and native toolbar
    flexible-space placement. It must not introduce a custom titlebar accessory,
    duplicate sidebar button, alternate tab registry, or presentation-lifetime
    authority.
  - Ornament buttons use standard `.buttonStyle(.borderless)` — let the system handle sizing per visionOS conventions. Do not hardcode icon frame sizes in ornaments.
- Terminal presentation is not terminal lifetime:
  - `SessionManager` and workspace models own session ordering, selection, live
    SSH/local-process lifetime, explicit close, and transactional window moves.
  - `onDisappear`, sidebar visibility, size-class transitions, and `TabView`
    reconstruction must never close sessions or workgroups.
  - Window restoration persists reconnectable intentions and stable IDs, not
    sockets or view-owned live transport state.
- Terminal-local settings presented via system `.sheet()` (not custom modal overlays) for Liquid Glass styling, gesture dismissal, and accessibility.
- Composition boundary: keep outer frame/chrome stable while applying tint/translucency at terminal display layer.
- Liquid Glass material strategy:
  - `.glassBackgroundEffect()` for window-level chrome (SettingsView, HTMLPreviewWindow).
  - `.regularMaterial` for secondary surfaces (port forward rows, tag chip backgrounds, URL bars).
  - Terminal frost is composited only when the resolved blur value is greater than zero; it must not force an opaque theme fill or eliminate the zero-blur endpoint.
  - Never stack glass-on-glass.
- All interactive targets must be >= 60pt for visionOS eye-tracking accuracy. Use `.frame(minWidth:minHeight:)` + `.contentShape()` to expand hit areas beyond visual size.
- Scene management: disable restoration on ephemeral windows (terminal, html-preview); use `.defaultLaunchBehavior(.presented)` on primary window.
- Native macOS scene commands are registered exactly once on the primary app scene. Terminal/workspace windows publish `FocusedValues`; the single `MacWorkspaceCommands` instance routes actions to the focused window and prevents duplicate application menus.
- Hover effects: `.hoverEffect(.highlight)` for small controls; never `.hoverEffect(.lift)` on large compound views.

## Repo Layout Pattern
- Runtime app code in `/Users/michael/Software/glass/glas.sh/glas.sh`.
- Reusable/shared package code in `/Users/michael/Software/glass/glas.sh/Packages`.

## File Organization (post code-quality overhaul)
- **Single-responsibility files**: Each manager/service in its own file.
  - `SecretStore.swift` — shared types, protocols, migration manager
  - `Constants.swift` — `UserDefaultsKeys`, `KeychainServiceNames` enums
  - `Logger.swift` — `os.Logger` extension (subsystem `sh.glas`)
  - `KeychainManager.swift` — keychain CRUD operations
  - `SecureEnclaveKeyManager.swift` — SE key wrap/unwrap
  - `ServerManager.swift` — server config persistence
  - `SettingsManager.swift` — app settings + SSH key management
  - `SessionManager.swift` — active terminal sessions
  - `WindowRecoveryManager.swift` — visionOS window recovery
  - `SSHConfigParser.swift` — `~/.ssh/config` parser
  - `PortForwardManager.swift` — port forwarding state
  - `Models.swift` — data models, `SSHConnection`, `TerminalSession`
- **Typed constants**: All UserDefaults keys and Keychain service names go through `UserDefaultsKeys` / `KeychainServiceNames` enums. No bare string literals.
- **Shared defaults**: `SharedDefaults` enum in `Constants.swift` manages `UserDefaults(suiteName: "group.sh.glas.shared")` for cross-app data (servers, sshKeys, trustedHostKeys). All UI/terminal settings stay on `UserDefaults.standard`.
- **Structured logging**: Use `Logger.ssh`, `Logger.servers`, `Logger.settings`, `Logger.keychain`. No `print()` in production code.
- **Concurrency safety**: Use `OSAllocatedUnfairLock` for thread-safe caches accessed from non-actor contexts. Use `nonisolated(unsafe)` only for `deinit` access to actor-isolated task properties.

## Keychain Lifecycle Pattern
- Canonical accounts are protocol/purpose/terminal-namespaced and profile-stable; use `KeychainAccountNamespace` rather than composing a bare `user@host:port` account at call sites.
- A user-authorized identity edit may remove its verified old app-owned account only after the new account and metadata commit. A shared legacy migration must retain the source and use atomic add-if-absent at the destination.
- Save errors must be surfaced via `Logger.keychain.error()` + user-facing alert. Never use `try?` for keychain saves — silent failures cause "no saved password" errors at connect time.
- Pre-load existing passwords in edit flows so users can see whether a password is saved and changes are intentional.
- Clean up orphaned entries when auth method switches away from password.

## visionOS Form Pattern
- SecureFields in Forms with username/host fields trigger visionOS AutoFill credential detection. Suppress with `.textContentType(.init(rawValue: ""))` on SecureFields that are app-managed credentials, not browser-style login forms.
- Every form view that presents text fields MUST use `@FocusState` with `.focused()` modifier and set initial focus in `.onAppear`. Without this, visionOS default keyboard presentation adds 3-5 seconds of latency before typing is accepted.
- For multi-field forms, use a `Field` enum with `@FocusState private var focusedField: Field?`. For single-field forms, use `@FocusState private var isNameFocused: Bool`.

## Terminal Focus Pattern
- Track aggregate focus ownership for search, sheets, editors, alerts, file pickers, and text composition. The terminal may request focus only when no competing owner is active and its window is key.
- Use bounded retry for transient window activation; cancel retry and explicitly resign when another control owns focus or the terminal disappears.
- Never restore the historical unconditional periodic first-responder timer; it steals focus from controls and IME composition.
- Replay the configured caret theme after `becomeFirstResponder()` succeeds.

## NIO ChannelHandler Propagation Pattern
- Every `ChannelDuplexHandler` that handles a lifecycle event (channelActive, channelInactive, channelWritabilityChanged, etc.) MUST forward the event downstream via `context.fire*()` after its own processing. Omitting this silently breaks handlers later in the pipeline.
- The NIOSSHHandler -> SSHChannelMultiplexer -> SSHChildChannel chain must propagate: readComplete, inactive, writabilityChanged. All three are now correctly wired.
- GlueHandler pairs (used for exec pipe bridging) must propagate close events bidirectionally — `partnerCloseFull()` and `partnerWriteEOF()` must actually close the partner's context.

## App Lifecycle Pattern
- `MainBootstrapView` monitors `scenePhase` — calls `sessionManager.closeAllSessions()` on `.background` to ensure SSH connections are cleanly terminated on app quit.
- Terminal session close respects `settingsManager.confirmBeforeClosing` — shows alert before disconnecting active sessions (via toolbar "Disconnect" button).

## Snippet Execution Pattern
- Snippets (CommandSnippet) are managed via SettingsManager CRUD.
- Execution: toolbar menu -> snippet picker sheet -> `session.sendCommand(snippet.command)` sends command + newline via TTY writer -> `settingsManager.useSnippet(id)` tracks usage stats.

## Auto-Reconnect Pattern
- `TerminalSession.attemptAutoReconnect(autoReconnectEnabled:)` with exponential backoff (1s/2s/4s/8s/16s, 5 attempts).
- Triggered from SSHConnection error paths (runInteractiveTTY catch-all, keepalive timeout).
- NOT triggered from: clean remote exit (handleCleanRemoteExit), channel closed errors, user-initiated disconnect.
- `userInitiatedDisconnect` flag set in `disconnect()` prevents reconnect on manual close.
- `cancelReconnect()` cancels the reconnect task and sets state to `.disconnected`.
- Reads `UserDefaults.standard.bool(forKey: .autoReconnect)` directly to avoid SettingsManager coupling.

## Port Forwarding Pattern
- Local forwarding: NIO `ServerBootstrap` binds to `127.0.0.1:localPort`, accepts connections, creates Citadel `DirectTCPIP` channel per connection, pipes data bidirectionally.
- `TunnelStatus` enum (inactive/starting/active/error/stopping) tracks tunnel state.
- `PortForwardManager` stores running `Task` per tunnel for lifecycle management.
- `SSHConnection.createDirectTCPIPChannel(targetHost:targetPort:)` wraps Citadel API.
- Bidirectional pipe pattern: `NIOAsyncChannel.executeThenClose` + `ThrowingTaskGroup` with two concurrent loops.

## Jump Host Pattern
- `ServerConfiguration.jumpHostID: UUID?` references another server config as jump host.
- `SessionManager.createSession()` resolves jumpHostID to full config, stores on `session.jumpHostConfig`.
- `SSHConnection.connect()` checks for jump host config: connects to jump host first, then calls `jumpClient.jump(to: targetSettings)`.
- Auth resolution extracted into reusable static helpers: `resolveAuthMethod()`, `resolveHostKeyValidator()`, `connectWithFallback()`.

## SFTP Browser Pattern
- `SSHConnection.openSFTPClient()` wraps `client.openSFTP()` from Citadel.
- `SFTPBrowserView` is a separate window scene ("sftp" WindowGroup, SFTPBrowserContext with sessionID).
- Opened from terminal toolbar menu. Navigates directories, download/upload files, create/rename/delete.
- `SFTPPathComponent` provides filename, longname, attributes (size, permissions, times).
- Validate remote basenames and retained-directory containment. Downloads use protected identity-bound partials with explicit collision/resume policy and atomic commit; uploads use exclusive no-clobber creation and exact-size verification.

## Quick Connect Pattern
- Search bar in ConnectionManagerView parses `user@host` or `user@host:port` via `quickConnectConfig` computed property.
- Matching pattern shows "Quick Connect" row above server list.
- Enter or tap triggers password prompt alert, creates transient ServerConfiguration (not saved), opens terminal window.
