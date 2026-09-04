# 160826_sftp-finder-native-operations

## Objective

Bring Finder-style selection, inspection, transfer, drag-and-drop, and remote
file-operation behavior to the existing SFTP browser while preserving glas.sh's
bounded, verified, no-clobber transfer boundary. Close the related initial
terminal-sizing and Connection Library feedback work already carried by the same
approved branch.

## Outcome

- Added native multi-selection and sortable macOS table columns for Name, Size,
  Modified, and Permissions while retaining directory-first stable ordering.
- Added contextual Rename, Get Info, Copy Reference, Copy To, Move To, Download,
  and Delete actions with inline rename and a bounded remote destination browser.
- Added native Finder file promises for dragging remote files out of glas.sh and
  local file-drop upload into the active SFTP directory.
- Added a per-window transfer activity shelf covering download, upload, Finder
  promises, remote copy, and remote move with honest queued/running/succeeded/
  failed/cancelled lifecycle and bounded completed history.
- Added windowed SFTP reads: up to eight ordered in-flight requests, no more than
  2 MiB of speculative data, exact short-read recovery, and shared verification
  for folder downloads and Finder promises.
- Added bounded remote-command execution and cancellation-safe completion so
  remote copy/move manifests and digests cannot retain unbounded command output.
- Added app-default and per-connection initial terminal geometry. A newly
  authenticated session gives the visible renderer a bounded opportunity to
  report its real geometry before starting the remote PTY; macOS can fit the host
  window to an explicit opening grid without resizing surrounding chrome.
- Added native Connection Library column autosave, in-row connection progress,
  and actionable Local Network permission guidance for local/private SSH hosts.

## Reuse Analysis

- Extended `glas.sh/SFTPBrowserView.swift`, the existing authority for SFTP
  navigation, selection, remote editing, verified download/upload, resume, and
  transfer error presentation.
- Extended the vendored Citadel SFTP and Exec clients rather than introducing a
  second protocol implementation or shell transport.
- Extended `TerminalSession`, `SessionManager`, `SettingsManager`, and the shared
  server forms for initial geometry instead of creating a parallel terminal
  launch path or settings store.
- Added `Platforms/macOS/SFTPFilePromiseDragSource.swift` because Finder file
  promises require AppKit `NSFilePromiseProvider` delegate ownership that cannot
  live in the platform-neutral SFTP browser without violating the established
  `Platforms/macOS` boundary.
- Added `glas.sh/SFTPTransferActivity.swift` because transfer lifecycle is shared
  by download, upload, Finder promise, remote copy, and remote move flows; keeping
  it inside any one operation would duplicate state and obscure cancellation.
- `110826_glass-editor-sftp-m4.md` cannot be extended because it records editor
  integration and conflict resolution, not Finder-style browser operations.
- `100826_connection-experience-and-server-form-layout.md` cannot be extended
  because its accepted scope is connection forms, credential prompting, and clean
  terminal exit; it contains none of this branch's SFTP transfer work.

## Files Modified

- `glas.sh/SFTPBrowserView.swift` — native table/list behavior, selection context
  actions, file information, rename, remote destination browsing, verified copy/
  move, drag/drop integration, windowed reads, and transfer shelf presentation.
- `Platforms/macOS/SFTPFilePromiseDragSource.swift` — AppKit Finder file-promise
  drag source and cancellation registry.
- `glas.sh/SFTPTransferActivity.swift` — bounded per-window transfer lifecycle and
  summary model.
- `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift` and
  `SFTPFile.swift` — ordered request batches and pipelined file reads.
- `Packages/Citadel/Sources/Citadel/Exec/Client/ExecClient.swift` — bounded output,
  timeout, and cancellation-safe command completion.
- `glas.sh/Models.swift`, `SessionManager.swift`, `TerminalWindowView.swift`,
  `VisionTerminalWorkgroupView.swift`, `Platforms/macOS/MacWorkspaceController.swift`,
  and `Packages/RealityKitContent/.../SwiftTermHostView.swift` — configured,
  measured, and macOS-fitted initial terminal geometry.
- `glas.sh/ServerFormViews.swift`, `SettingsManager.swift`, `SettingsView.swift`,
  `Constants.swift`, `ICloudSettingsSyncService.swift`, and `ServerManager.swift`
  — terminal-size editing, persistence, sync, and server-record validation.
- `glas.sh/ConnectionManagerView.swift`, both platform plists, and
  `glas.sh/glas_shApp.swift` — native column layout, connection state, initial
  presentation routing, and Local Network guidance.
- `glas.shTests/glas_shTests.swift` and Citadel tests — SFTP policy, transfer
  lifecycle, Finder promise, read window, sorting, connection feedback, terminal
  geometry, timeout, and persistence coverage.

## Integration Points

- `glas.sh/SFTPBrowserView.swift:709` presents the transfer shelf inside the
  existing browser layout; `glas.sh/SFTPBrowserView.swift:1534` centralizes the
  selection context menu; and `glas.sh/SFTPBrowserView.swift:1764` starts verified
  remote copy/move through the existing authenticated connection.
- `glas.sh/SFTPBrowserView.swift:2612` owns bounded verified downloads used by the
  ordinary folder path and `glas.sh/SFTPBrowserView.swift:2904` Finder promises.
- `Platforms/macOS/SFTPFilePromiseDragSource.swift:14` owns active transfer
  cancellation; `Platforms/macOS/SFTPFilePromiseDragSource.swift:75` adapts the
  browser payloads to AppKit without moving SFTP credentials into platform code.
- `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift:141` batches
  requests and `Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPFile.swift:169`
  returns read results in request order.
- `glas.sh/Models.swift:550` coordinates the initial renderer measurement before
  PTY creation; `glas.sh/ServerFormViews.swift:69` edits the app-default or
  connection-specific fallback.
- `glas.sh/ConnectionManagerView.swift:1806` adds local-network recovery guidance,
  and `glas.sh/ConnectionManagerView.swift:2604` attaches AppKit split-view
  autosave without becoming a second navigation authority.

## QA Results

Fresh exact-tree verification on 2026-09-03 with Xcode 27.0 (`27A5252f`):

- glas.sh macOS unit suite: 299/299 passed, zero failures, zero skips, and zero
  runtime warnings. Foreground UI automation was intentionally not run.
- Citadel suite: 49 executed, 44 passed, five environment-gated skips, and zero
  failures.
- iOS Simulator Debug build: passed.
- visionOS Simulator Debug build: passed.
- `git diff --check`: passed.
- `memory-bank/operational-log.jsonl`: valid JSONL.
- Both application plists: passed `plutil -lint`.
- Focused diff scan found no private-key material, access tokens, TODO/FIXME
  markers, or newly introduced production traps.
- Xcode emitted known warnings in the local GlassEditorKit dependency: two
  tree-sitter narrowing conversions and one deprecated string initializer. The
  Mac test host also reported the existing non-blocking AppIntents metadata skip
  because the target has no AppIntents framework dependency.

Earlier branch checkpoints also exercised focused sorting and transfer-activity
tests and produced signed runnable Mac builds. The final transfer-shelf checkpoint
could verify signature structure but not certificate trust because the installed
development certificate had expired. No fresh signed or foreground manual UI pass
is claimed by this publication checkpoint.

## Security Review

- Remote and local basenames remain fail-closed against traversal and separators.
- Finder promise downloads retain the destination directory descriptor, use the
  same bounded SHA-256-verified transfer path as ordinary downloads, and cancel
  active work when the browser shuts down.
- Remote copy publishes through no-clobber links. Remote move verifies the copied
  destination and revalidates the retained source baseline before deletion.
- Shell command arguments use POSIX single-quote escaping; remote command output
  and execution time are bounded at the transport boundary.
- Pipelined reads cap concurrency and speculative memory, preserve request order,
  and resume at the exact consumed offset after a short read.
- Transfer history is per-window and in-memory; credentials, file contents, and
  remote paths are not added to persistent logs.
- Local Network permission text describes only user-selected SSH connections and
  does not broaden network authority.

## Remaining Work

1. Replace the local-path GlassEditorKit dependency with an exact reviewed GitHub
   pin before a release build.
2. Retain manual Finder drag-out, file-drop upload, remote move, and terminal
   opening-size smokes in the physical release matrix; no foreground UI pass is
   inferred from automated unit/build evidence.
3. Restore a trusted development/distribution certificate before claiming signed
   release or App Store evidence.

## Artifacts

- Branch: `agent/sftp-native-selection-drag-drop`
- Pull request: pending publication
- Fresh Mac result bundle:
  `/private/tmp/glas-sftp-final-mac/Logs/Test/Test-glas.sh-2026.09.03_22-38-33--0500.xcresult`
