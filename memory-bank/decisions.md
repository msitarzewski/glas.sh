# Decisions

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
