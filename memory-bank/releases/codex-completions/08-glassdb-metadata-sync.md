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

## Current status — Schema/package foundation complete / migration and sync gated

Phase 08.1 and the Phase 08.8 reuse decision were completed on 2026-08-09.
They define the version-one wire contract, field ownership, migration invariants,
and the required neutral package boundary below. The separately approved
`GlassConnectionKit` package is published at exact revision
`0ced944e3a9799201f6563f057f7f760e9e7b988`. No CloudKit synchronization,
app-record migration, or secret mobility implementation is included in the current
candidate, and no secret is treated as ordinary synced metadata. This phase remains
open and has not been silently deferred.

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

## Phase 08.1 discovery outcome — version-one contract

`EndpointProfile` is a versioned, non-secret wire record. Its identity is never
derived from mutable endpoint fields. The serialized version-one contract is:

| Field | Type | Owner and invariant |
|---|---|---|
| `schemaVersion` | `UInt16` | `GlassConnectionKit`; version one on initial publication |
| `id` | `EndpointID` | Immutable random UUID minted once and preserved by every migration |
| `displayName` | `String` | Shared user-facing endpoint name; trimmed and non-empty |
| `host` | `String` | Shared SSH host; trimmed and non-empty, never used as record identity |
| `port` | `UInt16` | Shared SSH port in `1...65535` |
| `username` | `String` | Shared SSH username; trimmed and non-empty |
| `credentialID` | `CredentialID?` | Opaque stable reference only; never secret material or a Keychain account name |
| `jumpEndpointIDs` | `[EndpointID]` | Ordered, unique endpoint references; no self-reference; graph cycles rejected by the repository layer |
| `tags` | `[String]` | Shared normalized organization labels; ordered deterministically and deduplicated |
| `appVisibility` | `EndpointAppVisibility` | App-sharing policy, independent of device mobility and authentication kind |
| `createdAt` | `Date` | Immutable creation timestamp |
| `updatedAt` | `Date` | Last semantic record update; not connection recency |
| `deletedAt` | `Date?` | Tombstone timestamp; deletion is not absence |
| `lastWriterID` | `WriterID` | Random installation-scoped writer identity; never an Apple hardware identifier |

The shared model package defines the serialized value representations for
`EndpointID`, `CredentialID`, `WriterID`, `EndpointAppVisibility`, and
`EndpointProfile`. GlasSecretStore remains the only authority allowed to mint,
resolve, rotate, revoke, or report availability for a `CredentialID`.
`EndpointAppVisibility` version one has three stable raw values:
`glasShOnly`, `glassdbOnly`, and `glassFamily`. Existing records migrate to their
originating app's value until the user explicitly enables **My Connections**;
new records created while that feature is enabled use `glassFamily`.

### Field ownership

| Layer | Owns | Explicitly does not own |
|---|---|---|
| `GlassConnectionKit` | Neutral IDs, `EndpointProfile`, schema validation, normalization, version migration, and deterministic value comparison | Persistence, CloudKit, Keychain, host trust, SSH transport, UI, terminal behavior, or database behavior |
| GlasSecretStore | Credential lifecycle, authentication kind, device availability, mobility consent, Keychain policy/material, Secure Enclave enrollment, and host trust | Endpoint fields, app overlays, CloudKit endpoint records, or product UI |
| glas.sh overlay | Advanced SSH/PTY options, terminal/workspace behavior and appearance, favorite/color/recency presentation, and provenance | Database configuration or credential material |
| glassdb overlay | Database engine/host/port/user/database/TLS, database credential reference, favorite/color/recency presentation, and `tunnelEndpointID` | Duplicated SSH endpoint fields, terminal settings, or SSH credential material |
| Phase 08.3/08.4 repositories | Per-record local persistence, one logical CloudKit namespace, conflict application, and sync status | Schema invention or secret synchronization |

Metadata sync consent is a store/account setting, not an `EndpointProfile` field.
Credential mobility consent is a separate GlasSecretStore policy. `lastConnected`,
favorite state, colors, database options, terminal appearance, host fingerprints,
passwords, private keys, and passphrases never enter the shared endpoint record.

### Migration invariants

- glas.sh preserves `ServerConfiguration.id` as `EndpointID`; reusable endpoint
  fields move to `EndpointProfile` and terminal-only fields remain in its overlay.
- Existing key-backed credentials may preserve a collision-checked SSH key UUID as
  `CredentialID`. Password-backed records receive a new random `CredentialID` and
  are copied through GlasSecretStore's atomic migration path before references
  change.
- glassdb preserves `DatabaseConnectionConfig.id` as the database-overlay identity.
  Its embedded SSH fields either link to an explicitly matched existing endpoint or
  create a new random `EndpointID`; mutable `user@host:port` data is never hashed
  into identity. The overlay then stores only `tunnelEndpointID`.
- Existing records begin with origin-app-only visibility. Migration never opts a
  user into cross-app or cross-device sharing; the approved onboarding action does.
- Migrations persist their endpoint/credential mapping before removing duplicate
  fields, retain a rollback source through cross-app acceptance, and are idempotent.
- Deleting a database overlay never deletes its endpoint or credential. Endpoint
  deletion writes a tombstone. Credential deletion is a separate, reference-aware,
  explicit action owned by GlasSecretStore.

## Phase 08.8 discovery outcome — shared-package decision

The required reuse analysis found no existing neutral target that can be extended
without reversing an established dependency boundary or importing unrelated UI,
transport, database, or security behavior:

| Candidate analyzed | Why it cannot own the shared contract |
|---|---|
| glas.sh `ServerConfiguration` | Internal app model mixing reusable endpoint fields with credentials, trust, terminal, PTY, appearance, and provenance behavior |
| glassdb `DatabaseConnectionConfig` | Internal app model mixing database fields with embedded SSH tunnel and credential-policy fields |
| `RealityKitContent` | Rendering/terminal package with SwiftTerm and RealityKit assets; the wrong dependency direction for glassdb and non-UI models |
| `Citadel` | SSH transport package coupled to NIO, Crypto, BigInt, and logging |
| `GlassDBKit` | Database transport package coupled to MySQL, PostgreSQL, TLS, SQLite, and Citadel |
| GlasSecretStore | Security/Keychain and host-trust boundary; making it own endpoints would conflate discoverable metadata with secret lifecycle and force Security into the neutral layer |

Decision: create a new repository and Swift package named
`GlassConnectionKit`, with one dependency-free Foundation target and a matching
test target. Downstream integrations must consume reviewed exact revisions;
glassdb is the first consumer at `0ced944`. The package contains only the
versioned values and pure validation/migration behavior above. It contains no
CloudKit adapter, App Group store, Keychain call, SSH/database transport, SwiftUI,
or RealityKit code.

The separate package gate was approved and completed at exact revision
`0ced944e3a9799201f6563f057f7f760e9e7b988`; its 11 contract tests, release build,
and hosted CI pass. Phase 08.3 and 08.4 must subsequently assign one logical local-
record and CloudKit namespace before either app writes synchronization code.

## Work Packages

### 08.1 Shared schema discovery (`SYNC-001`)

**Status: Complete (2026-08-09); app migration is owned by 08.2/08.3.**

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

**Status: Complete (2026-08-09); package published at `0ced944`.**

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
