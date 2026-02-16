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
