# Phase 08: Glass-Family Connection Sync

## Objective

Deliver the *Magic / First Class* Glass-family connection experience: define an
SSH connection once, find it in glas.sh and glassdb across supported Apple
devices, and connect with the least intervention compatible with honest security.
The implementation must provide safe, conflict-aware endpoint and credential
mobility without treating credentials as ordinary synced metadata. glas.sh keeps
terminal behavior—including its transparent canvas and independent opacity and
blur controls—while glassdb consumes the same endpoint and credential identity
for SSH tunneling.

## Included Items

- `SYNC-001` through `SYNC-008` from the release ledger.

## Current status — Not started / external approval required

No CloudKit or shared endpoint-schema implementation is included in the current candidate, and no secret is treated as ordinary synced metadata. The glas.sh-side credential migration is forward-only and collision-safe; the sibling glassdb migration repair is present but still requires its own current test run and cross-repository acceptance. This phase remains open and has not been silently deferred.

## Product Invariant and Canonical Journey

- The user model is **My Connections**, not a CloudKit database, Keychain access
  group, shared package, or migration.
- The experience requires no proprietary Glass account. It uses the user's Apple
  iCloud/Keychain services, with explicit consent for eligible credential
  mobility.
- Canonical journey: create a password- or imported-key-backed SSH connection in
  glas.sh on iPhone; open glassdb on Vision Pro; choose that same connection as
  the SSH tunnel for a database; satisfy only required local host-trust or user-
  presence actions; connect without re-entering eligible endpoint or credential
  data.
- Secure Enclave is intentionally different: its endpoint and credential
  identity may appear everywhere, but a new device asks the user to enroll a
  local key rather than silently substituting weaker authentication.
- Normal UI uses outcome-oriented states: **Ready**, **Still Syncing**, **Sign In
  to iCloud**, **Set Up This Key**, and **Review Fingerprint**.

## Scope Boundary

- This document defines the glas.sh side of the contract.
- Any change to the external glassdb repository requires its own approval and review in that repository.
- Any change to the external GlasSecretStore repository requires its own approval,
  review, migration analysis, and package QA.
- `GlasSecretStore` owns credential identity, kind, availability, Keychain policy,
  secret material, and host trust. It remains a credential/trust package, not a
  general endpoint-schema or product-overlay package.
- `RealityKitContent` is not an appropriate home for shared endpoint metadata.
- Metadata sync and eligible credential mobility are separately opt-in. Secrets
  do not enter CloudKit merely because endpoint metadata does.
- App sharing, device mobility, and authentication kind are independent policy
  axes; one must never be inferred from another.

## Reuse Strategy

- Extend the existing `SharedDefaults`/App Group integration for same-device exchange.
- Reuse existing server identity, jump-host, credential-reference, Keychain,
  host-trust, and iCloud integration before adding another authority.
- Extend GlasSecretStore for shared credential identity and availability instead
  of creating an app-specific secret-sync implementation.
- Introduce a new shared package only if schema discovery proves that neither repository already has a suitable neutral model target.

## Work Packages

### 08.1 Shared schema discovery (`SYNC-001`)

- Inventory glas.sh and glassdb endpoint models and persistence boundaries.
- Define `EndpointProfile` with a stable `EndpointID`, display name, host, port,
  username, jump-chain references, tags, timestamps, deletion state, and schema
  version.
- Reference a stable Glass-family `CredentialID` without embedding secret
  material or deriving identity from mutable `user@host:port` fields.
- Keep terminal appearance, database options, secrets, and device-only authentication material out of the shared core.
- Document field ownership and migration rules before implementation.

### 08.2 Product-specific overlays (`SYNC-002`)

- Define a glas.sh overlay for terminal behavior and appearance.
- Define a glassdb overlay for database-specific configuration and selection of a
  shared endpoint as an SSH tunnel.
- Preserve glas.sh's 100% transparency capability and independently adjustable opacity and blur as terminal-only settings.
- Ensure shared-profile migrations cannot reset, clamp, or reinterpret those settings.

### 08.3 Atomic same-device storage (`SYNC-003`)

- Replace whole-array overwrites with per-record operations keyed by stable UUID.
- Add transactional or equivalent atomic writes for App Group exchange.
- Version records and provide explicit migrations.
- Preserve unknown fields when practical to support rolling upgrades between apps.
- Define the signed/native Mac exchange boundary explicitly; do not assume that
  the current mobile/vision App Group behavior is uniform on every platform.

### 08.4 Optional CloudKit metadata sync (`SYNC-004`)

- Evaluate `CKSyncEngine` or the current supported CloudKit mechanism for non-secret metadata.
- Require explicit opt-in and a clear privacy explanation.
- Sync endpoint metadata and product overlays only after the local record model and migrations are stable.
- Treat the App Group store as a local exchange layer, not as an implicit CloudKit schema.
- Provide first-run onboarding and a Settings summary for sync consent, current
  iCloud availability, last successful synchronization, retry, and account
  change without exposing implementation vocabulary.

### 08.5 Device-bound key availability (`SYNC-005`)

- Represent credential availability separately from endpoint metadata.
- Model internal states such as available locally, pending mobility, unavailable
  on this device, enrollment required, account action required, and host-trust
  review required; map them to the outcome-oriented product states above.
- Never silently replace a missing hardware-backed key with a weaker credential.
- Allow connection selection before a credential arrives, but block connection
  honestly with a resumable **Still Syncing** or **Set Up This Key** action.

### 08.6 Explicit secret-sync policy (`SYNC-006`)

- Keep secret synchronization as a separate feature decision and user consent surface.
- Define which password and imported-key representations are eligible for Apple-
  protected device mobility, which are device-bound, and how consent, revocation,
  rotation, and recovery work.
- Keep Secure Enclave private keys non-exportable and device-bound. Synchronize
  only their identity and enrollment requirement.
- Require end-to-end protection and recovery semantics before any credential-
  mobility implementation is proposed.
- Keep host trust and optional-network authorization explicit; endpoint or secret
  availability must not imply that a fingerprint or network grant was approved.

### 08.7 Conflict and deletion model (`SYNC-007`)

- Add tombstones, `updatedAt`, schema version, and source-device identity.
- Define deterministic field-level or record-level conflict rules.
- Prevent a stale peer from resurrecting deleted endpoints or overwriting newer local edits.
- Provide a user-visible resolution path for conflicts that cannot be merged safely.
- Cover delayed credential arrival, offline edits, iCloud sign-out/account switch,
  credential rotation/revocation, and app-version skew without creating phantom
  readiness or deleting the last recoverable local secret.

### 08.8 Shared-package decision (`SYNC-008`)

- Complete the required reuse analysis across both repositories.
- Include GlasSecretStore in the contract analysis while preserving its narrow
  credential/trust ownership.
- If no existing neutral package can be extended, propose a small shared model
  package with no UI, Keychain, database, terminal, or RealityKit dependency.
- Treat package creation as a separate approval gate; do not infer approval from this roadmap.

## Acceptance Criteria

- The shared schema has stable identity, explicit versioning, and documented ownership.
- Same-device writes are per-record and cannot lose unrelated edits through stale whole-array replacement.
- Endpoint metadata can sync without credentials.
- Device-bound credential absence is explicit and actionable.
- An eligible password/imported-key connection created in glas.sh on iPhone
  becomes selectable and usable as a glassdb SSH tunnel on Vision Pro without
  re-entering endpoint or credential data.
- The reverse glassdb-to-glas.sh journey and supported Mac/iPad combinations obey
  the same contract.
- A Secure Enclave-backed endpoint appears on a second device with a local
  enrollment action and never falls back silently.
- Onboarding and Settings use **My Connections** and outcome-oriented states;
  normal users do not need CloudKit, Keychain-group, package, or migration terms.
- Deletes and concurrent edits converge deterministically.
- glas.sh terminal appearance remains local to glas.sh and preserves full transparency plus opacity/blur controls.
- Any proposed new package includes the required exhaustive reuse analysis.

## Verification

- Migration tests for every supported schema version.
- Concurrent-update and stale-writer tests.
- Tombstone and delete-resurrection tests.
- Cross-app contract tests using the same serialized fixtures.
- CloudKit tests with opt-in off, account unavailable, quota/error states, and conflict delivery.
- GlasSecretStore tests for credential identity, availability, mobility consent,
  revocation, delayed arrival, and device-bound enrollment.
- Credential-boundary tests proving no secrets enter endpoint metadata or
  CloudKit metadata payloads.
- Fresh-install and upgrade tests across representative iPhone, iPad, Mac, and
  Vision Pro combinations.
- Canonical physical flow: glas.sh/iPhone creation -> glassdb/Vision Pro tunnel
  selection -> required local trust action -> database connection.
- Account-sign-out/switch, offline recovery, deletion, credential rotation, and
  Secure Enclave enrollment tests.

## Evidence Required to Close

- Approved schema and ownership document.
- Cross-repository compatibility matrix.
- Recorded canonical cross-app/device journey and reverse-direction results.
- Onboarding, sync-management, delayed-secret, account-change, and local-key-
  enrollment results.
- Migration, conflict, and privacy test results.
- Security review of every synced field.
- Separate approval record for any external-repository or new-package change.
