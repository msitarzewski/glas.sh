# Progress

## Latest Milestones
- Terminal in-place progress/status rendering stabilized:
  - PTY terminal mode negotiation now disables only CR->NL rewriting (`OCRNL`) while preserving expected newline behavior.
  - Terminal stream handoff from session model to SwiftTerm host now drains queued chunks per UI nonce update, avoiding chunk overwrite loss under burst output.
  - User-validated against Ubuntu progress workloads (`apt`, `wget --progress=bar:force:noscroll`).
- SSH key security and migration baseline shipped:
  - Secret store abstraction + keychain migration scaffold and status reporting.
  - Key metadata and UI badges (storage/algorithm/migration state) across Settings, server forms, and server info.
  - Secure Enclave-assisted P-256 key generation path with connection-time user-auth preflight prompt.
  - Legacy compatibility preserved for existing users (RSA + ED25519 import/auth paths).
- RSA SHA-2 interoperability fix landed:
  - Userauth algorithm/signature path aligned to RSA SHA-2 (`rsa-sha2-512`) with modern OpenSSH server behavior.
  - Connection diagnostics improved for authentication failure cases.
- SSH key management UX hardening:
  - Destructive delete confirmation dialog.
  - "Copy Public Key" action for stored keys with OpenSSH-format export.
- Connections window refactored to a native visionOS split-view/list/search/toolbar structure.
- Tag filtering moved to search-submit promotion with active chip filters under title context.
- Server form persistence hardened:
  - pending tag text now commits on Save (Add/Edit)
  - SSH key picker selection persistence stabilized in Add/Edit
- Public repository published.
- `main` branch protection enabled for PR workflow.
- Root README established for GitHub landing view.
- App identity aligned to `glas.sh` domain namespace.
- Legacy task markdown moved out of app source tree into memory bank tasks.
- Memory-bank task records normalized to neutral historical wording.
- Terminal window UX iteration converged on:
  - footer-first action model
  - in-window session settings modal with local tabs
  - terminal-pane-only tint/translucency behavior (avoids text tint washout).

- Password keychain persistence hardened:
  - Suppressed visionOS AutoFill system dialog on credential-style SecureFields.
  - Keychain save errors now logged + surfaced via alert instead of silently swallowed.
  - EditServerView pre-loads existing saved password from keychain.
  - Keychain key migration: orphaned entries cleaned up on host/port/username change or auth method switch.

## In Progress
- **Code quality overhaul + keychain fix** (branch `claude-does-glas-sh`): All code complete, build passes, 25/25 tests pass. Includes Managers.swift split, magic string elimination, structured logging, concurrency fixes, test expansion (3→25), and password keychain persistence fixes.

## Open Areas
- Ongoing terminal UX parity polish for edge-case TUIs.
- Final contrast tuning for modal/settings surfaces across varied scene lighting.
- Follow-up hardening: move generated P-256 auth to true Secure Enclave signing semantics (no app-exportable raw private key at auth time).
- Queued feature request: SSH agent auth/forwarding end-to-end support (model -> connection settings -> transport behavior).
