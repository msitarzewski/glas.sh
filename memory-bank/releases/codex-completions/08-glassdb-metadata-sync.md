# Phase 08: glassdb Metadata Sync

## Objective

Create a shared endpoint-metadata model and a safe, conflict-aware sync path without treating credentials as ordinary synced data. This phase coordinates with glassdb while keeping glas.sh's terminal-specific behavior—including the transparent terminal canvas and its opacity and blur controls—inside glas.sh.

## Included Items

- `SYNC-001` through `SYNC-008` from the release ledger.

## Current status — Not started / external approval required

No CloudKit or shared endpoint-schema implementation is included in the current candidate, and no secret is treated as ordinary synced metadata. The glas.sh-side credential migration is forward-only and collision-safe; the sibling glassdb migration repair is present but still requires its own current test run and cross-repository acceptance. This phase remains open and has not been silently deferred.

## Scope Boundary

- This document defines the glas.sh side of the contract.
- Any change to the external glassdb repository requires its own approval and review in that repository.
- `GlasSecretStore` remains a credential-storage package, not a general endpoint-schema package.
- `RealityKitContent` is not an appropriate home for shared endpoint metadata.
- Sync is opt-in. Secrets do not enter CloudKit merely because endpoint metadata does.

## Reuse Strategy

- Extend the existing `SharedDefaults`/App Group integration for same-device exchange.
- Reuse existing server identity and jump-host concepts when defining the shared contract.
- Introduce a new shared package only if schema discovery proves that neither repository already has a suitable neutral model target.

## Work Packages

### 08.1 Shared schema discovery (`SYNC-001`)

- Inventory glas.sh and glassdb endpoint models and persistence boundaries.
- Define `EndpointProfile` with a stable UUID, host, port, username, jump-chain references, tags, and schema version.
- Keep terminal appearance, database options, secrets, and device-only authentication material out of the shared core.
- Document field ownership and migration rules before implementation.

### 08.2 Product-specific overlays (`SYNC-002`)

- Define a glas.sh overlay for terminal behavior and appearance.
- Define a glassdb overlay for database-specific configuration.
- Preserve glas.sh's 100% transparency capability and independently adjustable opacity and blur as terminal-only settings.
- Ensure shared-profile migrations cannot reset, clamp, or reinterpret those settings.

### 08.3 Atomic same-device storage (`SYNC-003`)

- Replace whole-array overwrites with per-record operations keyed by stable UUID.
- Add transactional or equivalent atomic writes for App Group exchange.
- Version records and provide explicit migrations.
- Preserve unknown fields when practical to support rolling upgrades between apps.

### 08.4 Optional CloudKit metadata sync (`SYNC-004`)

- Evaluate `CKSyncEngine` or the current supported CloudKit mechanism for non-secret metadata.
- Require explicit opt-in and a clear privacy explanation.
- Sync endpoint metadata and product overlays only after the local record model and migrations are stable.
- Treat the App Group store as a local exchange layer, not as an implicit CloudKit schema.

### 08.5 Device-bound key availability (`SYNC-005`)

- Represent credential availability separately from endpoint metadata.
- Model states such as available locally, unavailable on this device, enrollment required, and user action required.
- Never silently replace a missing hardware-backed key with a weaker credential.

### 08.6 Explicit secret-sync policy (`SYNC-006`)

- Keep secret synchronization as a separate feature decision and user consent surface.
- Define which credential types can ever be exported, which are device-bound, and how revocation works.
- Require end-to-end encryption and recovery semantics before any secret-sync implementation is proposed.

### 08.7 Conflict and deletion model (`SYNC-007`)

- Add tombstones, `updatedAt`, schema version, and source-device identity.
- Define deterministic field-level or record-level conflict rules.
- Prevent a stale peer from resurrecting deleted endpoints or overwriting newer local edits.
- Provide a user-visible resolution path for conflicts that cannot be merged safely.

### 08.8 Shared-package decision (`SYNC-008`)

- Complete the required reuse analysis across both repositories.
- If no existing neutral package can be extended, propose a small shared model package with no UI, Keychain, database, terminal, or RealityKit dependency.
- Treat package creation as a separate approval gate; do not infer approval from this roadmap.

## Acceptance Criteria

- The shared schema has stable identity, explicit versioning, and documented ownership.
- Same-device writes are per-record and cannot lose unrelated edits through stale whole-array replacement.
- Endpoint metadata can sync without credentials.
- Device-bound credential absence is explicit and actionable.
- Deletes and concurrent edits converge deterministically.
- glas.sh terminal appearance remains local to glas.sh and preserves full transparency plus opacity/blur controls.
- Any proposed new package includes the required exhaustive reuse analysis.

## Verification

- Migration tests for every supported schema version.
- Concurrent-update and stale-writer tests.
- Tombstone and delete-resurrection tests.
- Cross-app contract tests using the same serialized fixtures.
- CloudKit tests with opt-in off, account unavailable, quota/error states, and conflict delivery.
- Credential-boundary tests proving no secrets enter metadata records or CloudKit payloads.

## Evidence Required to Close

- Approved schema and ownership document.
- Cross-repository compatibility matrix.
- Migration, conflict, and privacy test results.
- Security review of every synced field.
- Separate approval record for any external-repository or new-package change.
