# 2026-08 Tasks

## Tasks Completed

### 2026-08-11: GlassEditorKit remote SFTP editing (M4)

- Integrated GlassEditorKit as a local-path co-development dependency while
  keeping all remote bytes inside glas.sh's verified SFTP transport.
- Added explicit remote-file editing, bounded verified reads, atomic replacement
  saves, two-tier conflict detection, and user-owned conflict resolution.
- Preserved the existing no-clobber upload/import path and row multi-select
  behavior.
- Passed 278/278 glas.sh tests, Citadel coverage, macOS and visionOS builds, and
  signed manual open/edit/save plus forced-conflict acceptance.
- See: [110826_glass-editor-sftp-m4.md](./110826_glass-editor-sftp-m4.md)

### 2026-08-11: Connection experience and native server-form layout

- Completed the native trailing-aligned Add/Edit connection forms while preserving
  the existing transactional persistence and credential boundaries.
- Added the saved-profile password prompt, isolated Localhost test data from shared
  app defaults, restored the asset-catalog Mac icon, and made clean SSH exit close
  its pane/tab/window.
- Repaired a stale-pane lifecycle crash found during the first manual exit smoke;
  276/276 Mac tests and the rebuilt user-controlled retest pass.
- Verified iOS and visionOS simulator builds plus a valid signed arm64 Mac Release.
- Recorded local foreground GUI automation as explicit opt-in.
- Published through PR [#31](https://github.com/msitarzewski/glas.sh/pull/31) as
  squash commit `9de9ef15`; the merge tree exactly matches reviewed head `4790fd82`.
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
