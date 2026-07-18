# Phase 02 — Secrets, Authentication, and Host Trust

## Objective

Make credential and host-trust behavior collision-free, access-control-bound, migration-safe, explicit about cryptographic compatibility, and portable across supported Apple development and distribution configurations.

## Included items

`SEC-001...009` and `TRUST-001...003`.

## Current status — In progress

UUID/purpose Keychain namespaces, build-derived access groups, explicit macOS data-protection-Keychain configuration, real Secure Enclave P-256 signing with user-presence access control, explicit per-server legacy compatibility, and Keychain-authoritative host trust are implemented and in QA. Plaintext pins are cleared rather than resurrected; changed keys require explicit replacement and bounded history is tested. Credential migrations are forward-only, atomic-add-if-absent, and conflict-preserving. SSH-key deletion snapshots every representation, verifies absence, handles deterministic legacy hardware tags, and fails closed when an incomplete representation cannot be reconstructed. GlasSecretStore passes 75/75 tests across 13 suites. Cross-repository acceptance, remaining byte-oriented parsing work, and matching-device proof remain open.

## Existing implementation to extend

- `glas.sh/KeychainManager.swift:13` is the app-specific secret-store boundary.
- `glas.sh/SessionManager.swift` centralizes credential preparation without a detached LocalAuthentication preflight.
- `glas.sh/SettingsManager.swift:264` creates true Secure Enclave P-256 signing keys.
- `glas.sh/KeychainManager.swift:60` saves host-trust challenges.
- `glas.sh/Models.swift` reads host trust from Keychain and fails closed when trust storage is unavailable.
- GlasSecretStore already provides focused Keychain and trust models; keep that narrow boundary.

## Reuse strategy

- Extend GlasSecretStore's configuration, Keychain operations, and host-trust store rather than adding a second security package.
- Extend the current `StoredSSHKey` metadata instead of creating parallel key catalogs.
- Extend `ServerConfiguration` only for explicit per-host compatibility policy; remove trust blobs after migration.
- Reuse migration-status patterns already surfaced in Settings.

Cross-repository changes to glassdb or GlasSecretStore require their own approved plans and working branches. This phase document defines integration contracts; it does not silently authorize writes outside this repository.

## Work packages

### 02.1 Protocol- and purpose-namespaced accounts

- Define canonical accounts such as `ssh://user@host:port`, with normalized host and explicit protocol.
- Define distinct database protocol namespaces with glassdb.
- Specify collision, casing, IPv6, username, and non-default-port behavior.
- Migrate old `user@host:port` entries with a versioned sentinel.
- Verify source/destination values before deletion.
- Define deterministic handling when legacy and namespaced values both exist; never overwrite silently.
- Test upgrade, retry, partial failure, rollback, and downgrade implications.

### 02.2 Access-control-bound authentication

- Protect eligible Keychain items with `SecAccessControl` and `.userPresence`.
- For hardware keys, bind authorization to the actual signing operation or protected key reference.
- Avoid a detached `LAContext` prompt that is not connected to retrieval/signing.
- Add `NSFaceIDUsageDescription` with accurate user-facing language.
- Normalize cancellation, lockout, unavailable hardware, and system failure into typed errors.
- Verify whether one authorization may be reused within a narrowly scoped operation; default to fresh authorization for each externally initiated connection.

### 02.3 Access-group and platform correctness

- Derive the Keychain access group from entitlements/build settings matching `$(AppIdentifierPrefix)`.
- Validate local developer, CI, TestFlight, and distribution signing variants.
- Add iOS to GlasSecretStore's supported platforms.
- Use `kSecUseDataProtectionKeychain` where required on macOS.
- Add platform-specific package tests without widening GlasSecretStore into endpoint metadata or UI.

### 02.4 Hardware signing versus wrapped secrets

- Name true non-exportable Secure Enclave signing material `HardwareSigningKey` or an equivalent unambiguous type.
- Name exportable data sealed by a device key `DeviceWrappedSecret` or equivalent.
- Correct UI, README, migration status, and diagnostics so wrapped data is never described as a hardware-held private key.
- Preserve backward decoding with explicit migration and compatibility tests.

### 02.5 SecureBytes lifecycle reduction

- Add byte-oriented parser and signing inputs where dependencies permit.
- Minimize `String` and ordinary `Data` reconstruction of private material.
- Document unavoidable copies and zeroization limitations.
- Ensure logs and errors never stringify secret buffers.

### 02.6 Explicit legacy SSH compatibility

- Remove automatic retry with broad `SSHAlgorithms.all` from the normal negotiation path (`../docs/glas.sh-results.txt:64`).
- Add an explicit per-server compatibility setting with a warning and audit-visible diagnostics.
- Scope enabled algorithms to the minimum required legacy set.
- Require confirmation before enabling; do not enable from a generic connection failure.
- Add tests proving default-modern, explicit-legacy, and unrelated-failure behavior.

### 02.7 Authoritative host-trust migration

- Define a host-trust schema version and migration sentinel.
- Count and verify legacy server/global trust entries before marking migration complete.
- Make GlasSecretStore the only runtime authority.
- Remove plaintext trust blobs from shared defaults and server configurations only after successful verification.
- Preserve first-seen, last-seen, algorithm, fingerprint, and rotation history.
- Provide explicit unknown-key and changed-key approval UI.
- When a changed key is approved, supersede or delete conflicting active pins so the old key does not remain accepted.
- Allow multiple active keys only through a deliberate multi-key policy, not incidental accumulation.

## Acceptance criteria

- SSH and database credentials cannot collide at the account-key level.
- Migration is versioned, verified, idempotent, retryable, and does not silently discard either value in a conflict.
- Protected credential use is tied to Keychain retrieval or signing access control.
- Required biometric privacy metadata exists in every applicable target.
- Access groups work under local, CI, TestFlight, and distribution signing.
- Legacy algorithms are disabled by default and enabled only per host through explicit confirmation.
- Runtime host trust reads only GlasSecretStore after migration.
- Approving a rotated key does not leave the conflicting old key active.
- Hardware signing and wrapped-secret concepts are unambiguous in code and product language.

## Automated tests

- Account normalization and cross-protocol collision matrix.
- Legacy migration success, conflict, interruption, rerun, and rollback.
- Access-control query construction by platform.
- Authentication success, cancel, unavailable, lockout, and retrieval/signing failure.
- Modern negotiation failure does not trigger downgrade.
- Explicit legacy setting scopes algorithms correctly.
- Host-trust unknown, unchanged, changed, rotation, multiple-algorithm, migration-count, and old-pin-revocation cases.
- Backward decoding for key-kind terminology migrations.

## Security review

- No credential, passphrase, key bytes, access-control context, or host-key raw data in logs.
- No destructive deletion before verified migration.
- No fail-open behavior on Keychain or trust-store errors.
- No broad algorithm set enabled after generic failure.

## Exit evidence

- Cross-repository migration contract approved by glas.sh, glassdb, and GlasSecretStore owners.
- Green security and migration tests.
- Physical-device proof for protected retrieval/signing.
- Review proving changed-key approval revokes the old active trust path.
