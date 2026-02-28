# System Patterns

## Terminal Architecture
- SSH transport via Citadel and `withPTY` interactive sessions.
- Terminal rendering via SwiftTerm host view.
- Resize loop: UI geometry -> PTY rows/cols -> remote window change.
- Auth diagnostics surfaced through user-facing + raw error messaging to reduce field debugging time.
- PTY mode policy for in-place progress behavior:
  - explicitly disable CR->NL output translation (`OCRNL=0`)
  - do not force `ONLCR`/`ONLRET` overrides unless a host-specific issue requires it
  - validate against real workloads that rely on carriage-return redraw semantics.
- Stream delivery policy between SSH session and SwiftTerm host:
  - never use single-value overwrite semantics for terminal chunk handoff
  - queue/drain pending output chunks and emit by nonce to avoid dropping control-byte updates under high-frequency output bursts.

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
- Footer-first terminal action model (search/clear/preview/tools) instead of persistent side rails.
- Terminal-local settings modal for session-scoped behavior (`Terminal`, `Overrides`, `Port Forwarding`).
- Composition boundary: keep outer frame/chrome stable while applying tint/translucency at terminal display layer.

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
- **Structured logging**: Use `Logger.ssh`, `Logger.servers`, `Logger.settings`, `Logger.keychain`, `Logger.app`. No `print()` in production code.
- **Concurrency safety**: Use `OSAllocatedUnfairLock` for thread-safe caches accessed from non-actor contexts. Use `nonisolated(unsafe)` only for `deinit` access to actor-isolated task properties.

## Keychain Lifecycle Pattern
- Keychain account key format: `"\(username)@\(host):\(port)"`. Changing any component requires deleting the old entry after saving to the new key.
- Save errors must be surfaced via `Logger.keychain.error()` + user-facing alert. Never use `try?` for keychain saves — silent failures cause "no saved password" errors at connect time.
- Pre-load existing passwords in edit flows so users can see whether a password is saved and changes are intentional.
- Clean up orphaned entries when auth method switches away from password.

## visionOS Form Pattern
- SecureFields in Forms with username/host fields trigger visionOS AutoFill credential detection. Suppress with `.textContentType(.init(rawValue: ""))` on SecureFields that are app-managed credentials, not browser-style login forms.
