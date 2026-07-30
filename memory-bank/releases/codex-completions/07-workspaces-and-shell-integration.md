# Phase 07 — Workspaces and Shell Integration

## Objective

Add semantic terminal workflows and resumable workspace behavior using shell integration and existing multiplexers before considering a custom roaming daemon.

## Included items

`WORK-001...003` and the iTerm2/WezTerm benchmark expectations in `../docs/glas.sh-results.txt:162` and `:165`.

## Current status — In progress

The layout-restoration foundation and model-owned adaptive workspace shell are
implemented and tested. Versioned session intentions create fresh authorized
sessions; native adaptive tabs now preserve local/SSH session lifetime,
selection repair, Command-T, explicit close, Move Tab to New Window, multiple
windows, focused commands, local/SSH launch choices, teardown, and bounded
restoration without an AppKit tab-group mirror. Semantic history/command blocks,
broader shell integration, and tmux/Zellij discovery remain open, so the phase
remains In progress.

## Existing architecture to reuse

- Layout presets already preserve server IDs and reconnect fresh rather than restoring dead sockets (`memory-bank/systemPatterns.md#App Lifecycle Pattern`).
- Phase 01 provides a shared authorized opening policy.
- Phase 04 exposes working-directory and semantic terminal events.
- `TerminalSession` remains the live-session model.

## Reuse strategy

- Extend layout presets into versioned workspace definitions rather than enabling opaque OS restoration of live sessions.
- Use OSC 133/shell integration signals where available.
- Discover and attach to tmux/Zellij through SSH before designing a proprietary daemon.
- Keep workspace metadata non-secret and compatible with the Phase 08 endpoint schema.

## Work packages

### 07.1 Shell integration contract

Define versioned, optional integration for:

- command start/end boundaries;
- command text only when explicitly provided by shell integration;
- working directory;
- exit status;
- prompt state;
- host/user identity;
- file references and semantic selection.

Do not infer sensitive command content from raw terminal output when a trustworthy signal is unavailable.

### 07.2 Command blocks and semantic history

- Display navigable command/output blocks without altering terminal byte flow.
- Allow selection/copy/export under explicit privacy rules.
- Bound retained semantic metadata and provide clear deletion.
- Keep passwords and hidden input out of semantic history.
- Make AI use of command history separately opt-in and size-bounded.

### 07.3 Tabs, splits, and workspace definitions

- Define workspace layouts as endpoint/session intentions, split/tab geometry, and optional attach actions.
- Restore by creating fresh authorized sessions through Phase 01.
- Report per-pane failures without discarding successful panes.
- Keep platform-native presentation: spatial groups on visionOS, tabs/splits on macOS, adaptive workspaces on iPadOS, compact switching on iOS.
- Make `SessionManager` workgroup order and selection authoritative. A selected
  identifier must resolve to a current session or be repaired atomically to
  `nil` or the next valid session during the same mutation.
- Retain terminal emulator, local PTY, and live SSH ownership outside ephemeral
  adaptive-tab content. View `onDisappear` is never a session, tab, workgroup,
  or process close command.
- Model one terminal window as one workspace containing native adaptive session
  tabs. A tab can retain the existing split topology as its content.
- Keep windows independent: visionOS spatial windows, macOS/iPadOS value-based
  `WindowGroup` windows, and compact iPhone navigation all project the same
  workgroup/session intentions without sharing presentation state.
- Move Tab to New Window uses a bounded transactional handoff:
  the source retains the live session, the destination opens and claims it, and
  only a confirmed claim removes it from the source. Failure or expiration
  leaves the source tab intact.
- Persist stable workspace, tab, endpoint, split, and optional attach
  intentions. Never serialize a live SSH socket or claim that OS restoration
  resumes transport state.

### 07.4 Persistent remote sessions and cross-device handoff

- Detect availability without mutating the remote host.
- List attachable sessions with explicit user choice.
- Create, name, attach, and detach through visible commands and predictable cleanup.
- Keep the shell and its child processes running on the remote host after glas.sh disconnects.
- Allow a session detached on Vision Pro to be discovered and resumed from glas.sh on Mac, iPad, iPhone, or another Vision Pro, and vice versa.
- Distinguish a live attached session, a detached resumable session, and a stale or unreachable session without claiming that an SSH socket itself roams between devices.
- Preserve terminal size, environment, working directory, and multiplexer session identity where the selected server-side tool supports them; report unsupported state honestly.
- Make simultaneous-attach behavior explicit: support safe shared attachment only when requested, otherwise warn before taking over or attaching to an already viewed session.
- Handle missing tools, version differences, nested sessions, and failed attach.
- Prefer tmux as the first implementation, retain Zellij as a compatible provider, and evaluate `screen` only as a legacy fallback.
- Prefer this server-side multiplexer path for resumability before a custom remote daemon.

### 07.5 File references and working-directory actions

- Validate remote paths and distinguish them from local files.
- Offer safe SFTP/open/copy actions based on session identity.
- Apply Phase 03 SFTP containment and collision rules.
- Never open arbitrary local URLs from untrusted shell metadata.

## Acceptance criteria

- Command blocks, working directory, exit status, selection, and file references derive from defined semantic signals.
- Workspace restore creates fresh authorized sessions and reports partial failures.
- Adaptive presentation changes, sidebar toggles, width-class changes, and view
  reconstruction do not close live sessions or local processes.
- Command-T, explicit tab close, workgroup close, and Move Tab to New Window are
  authoritative model operations with deterministic selection repair.
- Moving a live session between windows is lossless or rolls back to the source.
- tmux/Zellij discovery, attach, detach, and cross-device resume work without a proprietary daemon.
- Disconnecting glas.sh does not terminate a process intentionally running inside a managed persistent remote session.
- Semantic history has bounded retention and deletion and excludes secret input.
- Platform shells present workspaces natively.

## Tests

- OSC 133 and shell-integration parsing, fragmentation, malformed input, and fallback.
- Secret-input exclusion and history retention/deletion.
- Workspace serialization, migration, partial restore, and missing endpoint behavior.
- Dynamic-tab ordering, selection repair, explicit close, view disappearance,
  transfer claim/rollback/expiration, terminal-host retention, and local-process
  retention.
- tmux/Zellij availability, listing, naming, attach, detach, cross-device resume, simultaneous-attach policy, error, stale-session, and nested-session fixtures.
- Remote file-reference validation and SFTP handoff.

## Manual verification

- bash, zsh, fish, tmux, and Zellij on representative hosts.
- Long-running workspace interruption, detach, app termination, and resume from a second Apple device.
- Start a process from Vision Pro, disconnect without terminating it, resume it on Mac and iPad, then detach and resume it again on Vision Pro.
- visionOS spatial grouping plus native macOS/iPadOS presentations when available.

## Exit evidence

- Documented shell-integration protocol and privacy model.
- Green semantic/workspace regression suite.
- Demonstrated cross-device resumable workflow through tmux or Zellij with the remote process surviving client disconnection.
- Green adaptive-workspace model and UI coverage for selection repair, explicit
  close, view reconstruction, local-process retention, SSH-session retention,
  native sidebar ownership, and transactional window movement.
