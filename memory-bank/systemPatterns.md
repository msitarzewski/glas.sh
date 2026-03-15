# System Patterns

## Terminal Architecture
- SSH transport via Citadel and `withPTY` interactive sessions.
- Terminal rendering via SwiftTerm host view.
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

## SSH Secret Handling Pattern
- App-facing secret API routes through a `SecretStore` abstraction (currently keychain-backed).
- Keychain entries use migration marker + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Migration state is tracked and surfaced in Settings via summary counts/status.
- `StoredSSHKey` metadata carries:
  - storage kind (`legacy`, `imported`, `secureEnclave`)
  - algorithm kind (`rsa`, `ed25519`, `ecdsa-p256`, etc.)
  - migration state (`pending`, `migrated`, etc.)
- UI pattern: every visible key selection/listing includes a key-type badge to avoid ambiguity for mixed-format fleets.

## SSH Auth Algorithm Pattern
- Keep OpenSSH key blob encoding unchanged for RSA public keys (`ssh-rsa`) while selecting modern userauth signature algorithms (`rsa-sha2-*`) in auth request framing/signing.
- Do not regress legacy users while tightening defaults; compatibility changes are validated against real OpenSSH traces.

## UI Structure
- Multi-window app model with terminal-focused windows.
- Terminal window ornament layout:
  - **Top ornament**: Connection label (server name + user@host:port) as a glass capsule — informational only, outside the window.
  - **Bottom ornament**: Status indicator + server list button + gear tools menu (search/clear/preview/duplicate/reconnect/settings) as a glass capsule.
  - Ornament buttons use standard `.buttonStyle(.borderless)` — let the system handle sizing per visionOS conventions. Do not hardcode icon frame sizes in ornaments.
- Terminal-local settings presented via system `.sheet()` (not custom modal overlays) for Liquid Glass styling, gesture dismissal, and accessibility.
- Composition boundary: keep outer frame/chrome stable while applying tint/translucency at terminal display layer.
- Liquid Glass material strategy:
  - `.glassBackgroundEffect()` for window-level chrome (SettingsView, HTMLPreviewWindow).
  - `.regularMaterial` for secondary surfaces (port forward rows, tag chip backgrounds, URL bars).
  - `.ultraThinMaterial` retained only for terminal content area (blur-behind for readability).
  - Never stack glass-on-glass.
- All interactive targets must be >= 60pt for visionOS eye-tracking accuracy. Use `.frame(minWidth:minHeight:)` + `.contentShape()` to expand hit areas beyond visual size.
- Scene management: disable restoration on ephemeral windows (terminal, html-preview); use `.defaultLaunchBehavior(.presented)` on primary window.
- Hover effects: `.hoverEffect(.highlight)` for small controls; never `.hoverEffect(.lift)` on large compound views.

## Repo Layout Pattern
- Runtime app code in `/Users/michael/Developer/glas.sh/glas.sh`.
- Reusable/shared package code in `/Users/michael/Developer/glas.sh/Packages`.

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
- Keychain account key format: `"\(username)@\(host):\(port)"`. Changing any component requires deleting the old entry after saving to the new key.
- Save errors must be surfaced via `Logger.keychain.error()` + user-facing alert. Never use `try?` for keychain saves — silent failures cause "no saved password" errors at connect time.
- Pre-load existing passwords in edit flows so users can see whether a password is saved and changes are intentional.
- Clean up orphaned entries when auth method switches away from password.

## visionOS Form Pattern
- SecureFields in Forms with username/host fields trigger visionOS AutoFill credential detection. Suppress with `.textContentType(.init(rawValue: ""))` on SecureFields that are app-managed credentials, not browser-style login forms.
- Every form view that presents text fields MUST use `@FocusState` with `.focused()` modifier and set initial focus in `.onAppear`. Without this, visionOS default keyboard presentation adds 3-5 seconds of latency before typing is accepted.
- For multi-field forms, use a `Field` enum with `@FocusState private var focusedField: Field?`. For single-field forms, use `@FocusState private var isNameFocused: Bool`.

## Terminal Focus Pattern
- Terminal keyboard focus uses `becomeFirstResponder()` retry loop (3 attempts × 50ms).
- Do not add redundant delayed focus calls — the retry loop handles transient failures.
- Single `focus()` call on `.onAppear` and `.onChange(of: scenePhase)` is sufficient.

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

## Quick Connect Pattern
- Search bar in ConnectionManagerView parses `user@host` or `user@host:port` via `quickConnectConfig` computed property.
- Matching pattern shows "Quick Connect" row above server list.
- Enter or tap triggers password prompt alert, creates transient ServerConfiguration (not saved), opens terminal window.
