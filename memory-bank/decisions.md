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
