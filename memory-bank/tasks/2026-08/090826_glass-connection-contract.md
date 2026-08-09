# 090826_glass-connection-contract

## Objective

Establish the approved non-secret Glass-family endpoint contract before any
CloudKit synchronization work, reconcile and land the shared credential package,
publish the neutral model package, and make glassdb consume the reviewed exact
revisions.

## Outcome

- ✅ GlasSecretStore PR [#4](https://github.com/msitarzewski/GlasSecretStore/pull/4)
  merged as `75504f59c13477867c164721ac8a375d8ba01f8f`; accepted contract revision
  `9be45c91d145333252e3f5b03a5e5b6e6349e3e6` remains in `main` ancestry.
- ✅ [GlassConnectionKit](https://github.com/msitarzewski/GlassConnectionKit)
  published at `0ced944e3a9799201f6563f057f7f760e9e7b988` with the version-one
  `EndpointProfile`, stable ID types, validation, normalization, and canonical
  serialization.
- ✅ glassdb PR [#7](https://github.com/msitarzewski/glassdb.app/pull/7)
  merged as `2e40b6dcdf043484e207dc698614545bac301b86`; green head `67ef28b`
  pins both accepted package revisions and adds downstream contract coverage.
- ✅ Phase 08.1 (`SYNC-001`) and Phase 08.8 (`SYNC-008`) are complete. Endpoint
  migration, per-record persistence, credential mobility, and CloudKit sync remain
  open work; no public cross-device claim was made.

## Files Modified

- `memory-bank/releases/codex-completions/08-glassdb-metadata-sync.md` — recorded
  the schema, ownership matrix, reuse analysis, migrations, package result, and
  implementation boundary.
- `memory-bank/releases/codex-completions/README.md` — marked `SYNC-001` and
  `SYNC-008` complete without changing later sync work.
- `memory-bank/decisions.md` — recorded the GlassConnectionKit architecture
  decision and accepted revision.
- `memory-bank/systemPatterns.md` — established the neutral-model dependency
  boundary.
- `memory-bank/activeContext.md`, `memory-bank/progress.md`, and
  `memory-bank/toc.md` — reconciled current focus, milestone evidence, and task
  navigation.

## Patterns Applied

- `memory-bank/systemPatterns.md#Glass-Family-Connection-and-Credential-Contract`
- `memory-bank/decisions.md#2026-08-09-Put-the-neutral-connection-contract-in-GlassConnectionKit`
- `memory-bank/releases/codex-completions/08-glassdb-metadata-sync.md#Phase-081-discovery-outcome--version-one-contract`

## Integration Points

- GlassConnectionKit defines `EndpointID`, `CredentialID`, `WriterID`,
  `EndpointAppVisibility`, `EndpointProfile`, and `EndpointProfileCodec` without
  importing CloudKit, Security, SSH/database transports, SwiftUI, or RealityKit.
- GlasSecretStore remains the credential lifecycle, Keychain material, device
  availability, mobility-consent, Secure Enclave, and host-trust authority.
- glassdb pins `GlassConnectionKit@0ced944` and `GlasSecretStore@9be45c9` in its
  Xcode project and workspace lockfile. Its integration test proves the neutral
  payload round-trips an opaque credential reference without password, private-key,
  or host-fingerprint fields.
- glas.sh app adoption and both products' record migrations remain Phase 08.2/08.3
  work. Neither application writes CloudKit records from this task.

## Architectural Decisions

- A new Foundation-only package was required because existing candidates are app
  models, rendering, SSH transport, database transport, or Keychain/trust layers.
- Endpoint identity is an immutable random UUID, never a derivation of mutable
  `user@host:port` data.
- Credential identity is an opaque stable reference. Secret material and readiness
  remain outside endpoint metadata.
- App sharing, device mobility, and authentication kind remain independent policy
  axes.
- Endpoint deletion is a tombstone. Deleting a database overlay cannot cascade to
  a shared endpoint or credential.

## QA

- GlassConnectionKit: 11/11 package tests, release build, manifest validation,
  diff check, and hosted package CI passed.
- GlasSecretStore: 76/76 package tests, release build, diff check, and hosted
  package CI passed.
- glassdb: macOS 106/106; iPhone 104/104; iPad 104/104; Vision Pro 104/104 —
  418 target test executions total. Hosted application tests, GlassDBKit tests,
  privacy verification, secret scan, and dependency-advisory scan passed.

## Security Review

- No password, private key, passphrase, host fingerprint, or Keychain account enters
  `EndpointProfile` or its canonical payload.
- No `kSecAttrSynchronizable` policy or CloudKit implementation was added.
- Secure Enclave and user-presence material remain device-bound.
- All downstream package references use reviewed exact revisions.

## Artifacts

- GlasSecretStore PR #4: https://github.com/msitarzewski/GlasSecretStore/pull/4
- GlassConnectionKit revision: https://github.com/msitarzewski/GlassConnectionKit/commit/0ced944e3a9799201f6563f057f7f760e9e7b988
- glassdb PR #7: https://github.com/msitarzewski/glassdb.app/pull/7
- glas.sh documentation commit: `364e5287`
