# 260216_secure-enclave-migration-and-key-badging-plan

## Objective
Define and begin execution of a Secure Enclave migration strategy for secret storage while preserving backward compatibility for legacy SSH key users and exposing key-type badges anywhere users choose keys.

## Scope (Approved)
- Cover both password and SSH key secret handling.
- Keep full backward compatibility for legacy keys (no forced migration cutoff).
- Show badges with source + algorithm:
  - `Legacy RSA`
  - `Imported ED25519`
  - `Secure Enclave P-256`
- Show badges in all key-visible surfaces (settings list and add/edit server selectors).

## Current State Snapshot
- Secrets are stored in Keychain generic-password items, with no Secure Enclave key path yet.
- Runtime SSH auth currently supports ED25519 and blocks RSA auth with explicit messaging.
- Existing users may still have legacy key formats that must continue to work during rollout.

## Implementation Plan
1. Storage abstraction and migration scaffold
   - Add `SecretStore` interface to centralize secret reads/writes.
   - Add default `KeychainSecretStore` implementation to preserve current behavior.
   - Add `SecretStoreMigrationManager` scaffold with versioning/reporting hooks.
2. Key metadata and badge plumbing
   - Extend `StoredSSHKey` with storage/source and algorithm metadata.
   - Preserve compatibility with older persisted key metadata through tolerant decoding.
   - Add `keyTypeBadge` computed display string.
3. UI surface updates
   - Display key badge in settings key list.
   - Display key badge in Add Server and Edit Server SSH key pickers.
4. Secure Enclave implementation phases (next)
   - Phase A: hardened at-rest secret wrapping and migration execution.
   - Phase B: Secure Enclave P-256 key generation/signing path and runtime SSH integration.

## Risks and Mitigations
- Risk: key compatibility regressions for existing users.
  - Mitigation: backward-compatible decoding and no forced migration cutoff.
- Risk: runtime SSH algorithm support mismatch on some servers.
  - Mitigation: preserve existing key path during rollout, add capability checks and clear errors.
- Risk: simulator vs device behavioral differences for enclave flows.
  - Mitigation: validate on physical visionOS-capable hardware before shipping enclave path.

## Acceptance Criteria
- Secret store abstraction is in place and used by current call sites.
- Migration scaffold is versioned and invocable at startup.
- SSH key metadata supports source + algorithm badges.
- Key badges are visible in all currently supported key-selection/display surfaces.
- No regression to existing ED25519 key path behavior.

## Progress Update
- Implemented legacy RSA compatibility in key import and runtime SSH authentication.
- Added secret migration status UI in Settings with legacy-only item counting.
- Added marker-based migration pass for existing Keychain secret items and ensured new writes are marker-tagged.
- Added Secure Enclave-assisted P-256 key generation flow:
  - generated P-256 key material is wrapped using a device-bound Secure Enclave key
  - wrapped payload and key tag are persisted in Keychain
  - runtime auth resolves wrapped payload and uses `.p256` SSH auth path
- Added explicit "Generate Secure Enclave Key" entry point in Settings.
