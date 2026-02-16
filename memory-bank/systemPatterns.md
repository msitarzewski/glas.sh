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
