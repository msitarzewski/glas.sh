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
