# 110826_glass-editor-sftp-m4

## Objective

Integrate the shared GlassEditorKit editor into the existing glas.sh SFTP browser
so a user can open a bounded remote file, edit it, save it through glas.sh's
verified transfer layer, and make an explicit decision when the remote file
changes concurrently.

## Outcome

- Added explicit remote-file Edit affordances without changing the existing
  file-row tap/multi-select behavior.
- Loaded remote bytes through the existing SFTP client, captured the opened
  SHA-256 plus size and modification time, and constructed the editor through
  `DocumentLoader`, `GlassEditorModel`, and `GlassEditorView`.
- Kept GlassEditorKit out of the wire path. glas.sh owns every SFTP read, write,
  digest, verification, resume, commit, and error translation operation; the
  package owns editor UI and remote-conflict decisions only.
- Added two-tier conflict classification. Stat changes trigger a verified reread
  and digest comparison, and dirty/indeterminate conflicts always require a user
  choice instead of last-write-wins behavior.
- Added verified atomic replacement for editor saves through OpenSSH
  `posix-rename@openssh.com`; the proven exclusive no-clobber import path remains
  behavior-identical.
- Passed the manual M4 definition of done: open, edit, save, change the same file
  from a shell, and confirm glas.sh surfaces Overwrite Remote, Discard Local
  Changes and Reload, Save Local Copy, and Keep Editing.

## Reuse Analysis

- Extended `glas.sh/SFTPBrowserView.swift`, which already owns authenticated SFTP
  browsing, bounded streaming, SHA-256 verification, resume identity, upload
  commit, and `SFTPTransferError` translation.
- Extended `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift` with the
  server-advertised POSIX rename operation instead of implementing another SFTP
  client or bypassing Citadel.
- Reused GlassEditorKit's `RemoteDocumentSession`, `ConflictDetector`,
  `ConflictPrompt`, and `GlassEditorView`; no provider, transport, or duplicate
  editor engine was introduced.
- `090826_glass-connection-contract.md` cannot be extended because it records the
  Glass-family endpoint/credential contract, not remote file editing.
- `100826_connection-experience-and-server-form-layout.md` cannot be extended
  because it records connection forms, password prompting, and terminal lifecycle
  behavior. A separate dated task record is required for M4 implementation and
  acceptance evidence.

## Files Modified

- `glas.sh/SFTPBrowserView.swift` — Edit affordances, bounded verified remote
  reads, editor construction, conflict classification, replacement-save routing,
  baseline advancement, and surface mapping.
- `glas.sh/SFTPRemoteEditorView.swift` — consumer-owned editor sheet, Save/Done
  controls, conflict choices, status/error presentation, and local-copy export.
- `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift` — public,
  version-checked OpenSSH POSIX rename extension request.
- `Packages/Citadel/Tests/CitadelTests/Citadel2Tests.swift` — POSIX rename
  extension behavior and unsupported-extension coverage.
- `glas.shTests/glas_shTests.swift` — shared 8 MiB editor/streaming ceiling check.
- `glas.sh.xcodeproj/project.pbxproj` and `Package.resolved` — local-path
  GlassEditorKit product integration for co-development.

## Patterns Applied

- `memory-bank/systemPatterns.md#SFTP-Browser-Pattern`
- `memory-bank/systemPatterns.md#Remote-Editor-Decision-and-Transport-Boundary`
- `memory-bank/projectRules.md#Code-and-Structure`
- `memory-bank/projectRules.md#Keychain-Handling`

## Integration Points

- `glas.sh/SFTPBrowserView.swift:525` adds a pencil action while preserving the
  existing row tap selection path.
- `glas.sh/SFTPBrowserView.swift:795` opens the editor from verified SFTP bytes;
  `glas.sh/SFTPBrowserView.swift:848` classifies remote changes; and
  `glas.sh/SFTPBrowserView.swift:890` saves only after conflict authorization.
- `glas.sh/SFTPBrowserView.swift:1709` preserves the original upload wrapper;
  `glas.sh/SFTPBrowserView.swift:1762` contains the shared verified transfer core;
  and `glas.sh/SFTPBrowserView.swift:2023` performs the replacement commit.
- `glas.sh/SFTPRemoteEditorView.swift:68` owns the application presentation around
  `GlassEditorView`; GlassEditorKit receives resolved opacity/material state but
  reads no application settings directly.
- `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift:545` exposes the
  negotiated atomic rename primitive used by the replacement-save path.

## QA Results

- glas.sh macOS unit suite: 278/278 passed, zero failures, zero skips.
- Citadel suite: 45 executed, 40 passed, five environment-gated skips, zero
  failures.
- GlassEditorKit: 102 UI tests passed; 297 core tests passed with one existing
  known ReDoS issue reported by the package suite.
- macOS Debug build: passed.
- visionOS Simulator build: passed.
- `git diff --check`: passed.
- Signed manual acceptance: remote file opened, edited, saved, and reloaded.
- Signed forced-conflict acceptance: passed; no silent overwrite occurred.
- Local foreground GUI automation was not run.

## Security Review

- The editor package receives document snapshots and conflict metadata, never an
  SFTP client, credential, host-key authority, or direct write capability.
- The streaming reader and `GlassEditorConfiguration` share the same 8 MiB limit,
  so a file cannot pass one ceiling and fail a different later ceiling.
- Remote content is SHA-256 verified on read and write. Replacement saves validate
  the target immediately before atomic rename and reconcile unknown commit results
  by rereading the destination.
- Coarse SFTP modification timestamps retain unknown nanoseconds rather than
  inventing precision. Indeterminate state requires a user decision.
- No credential, file content, or remote path content was added to logs.

## Remaining Work

1. Replace the local-path GlassEditorKit dependency with a pinned GitHub URL before
   cutting a release.
2. Preserve the forced-conflict acceptance path when GlassEditorKit or Citadel is
   upgraded.
3. Integrate the shared editor into glassdb's SQL/file surfaces as a separate
   downstream phase; this milestone makes no glassdb implementation claim.

## Artifacts

- glas.sh branch: `agent/glass-editor-sftp-m4`
- GlassEditorKit repository: https://github.com/msitarzewski/GlassEditorKit
- Integration authority: `../GlassEditorKit/INTEGRATION.md#Part-B`
