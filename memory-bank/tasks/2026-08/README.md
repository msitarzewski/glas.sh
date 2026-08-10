# 2026-08 Tasks

## Tasks Completed

### 2026-08-10: Connection experience and native server-form layout

- Recorded glassdb PR #8 as merged downstream connection-library and unified-workspace evidence without upgrading glas.sh synchronization status.
- Consolidated Add/Edit Server appearance controls and introduced a compact grouped macOS form while retaining touch/spatial target sizing on iPhone, iPad, and Vision Pro.
- Built and launched a signed Mac candidate; 274/274 Mac unit tests pass.
- Preserved the exact visual boundary: the grouped direction is accepted, but a true trailing-aligned value column remains open before final approval.
- Recorded that local foreground GUI automation requires explicit approval; simulator testing remains allowed.
- See: [100826_connection-experience-and-server-form-layout.md](./100826_connection-experience-and-server-form-layout.md)

### 2026-08-09: Glass-family connection contract

- Reconciled and merged GlasSecretStore PR #4 while preserving the exact accepted
  credential-contract revision.
- Published GlassConnectionKit as the Foundation-only version-one endpoint contract.
- Pinned glassdb to the reviewed GlassConnectionKit and GlasSecretStore revisions,
  added downstream contract coverage, and merged glassdb PR #7.
- Completed Phase 08.1/08.8 schema, ownership, migration, and reuse/package decisions
  without starting CloudKit or credential-mobility implementation.
- See: [090826_glass-connection-contract.md](./090826_glass-connection-contract.md)

### 2026-08-02: Public README and release-ledger reconciliation

- Updated the public architecture and build narrative for the unified Mac, iPhone, iPad, and Vision Pro application target.
- Documented the current native Mac boundary, shared scheme, terminal host, requirements, and destination-specific build commands.
- Preserved the approved post-release adaptive-workspace and physical Vision Pro evidence in the Codex Completions, Connection Library, and One Base ledgers.
- Verified documented paths, project facts, shared schemes, Markdown structure, ledger checkpoints, and diff whitespace.
- See: [020826_readme-release-ledger-reconciliation.md](./020826_readme-release-ledger-reconciliation.md)
