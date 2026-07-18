# Phase 07 — Workspaces and Shell Integration

## Objective

Add semantic terminal workflows and resumable workspace behavior using shell integration and existing multiplexers before considering a custom roaming daemon.

## Included items

`WORK-001...003` and the iTerm2/WezTerm benchmark expectations in `../docs/glas.sh-results.txt:162` and `:165`.

## Current status — In progress

The layout-restoration foundation is implemented and tested: versioned `SessionIntent` records migrate legacy server IDs, preserve repeated intentions and unsupported restoration values, create fresh authorized sessions, and aggregate per-session failures without discarding valid targets. Those cases pass in the current 164-test app suite. Tabs/splits, semantic history and command blocks, broader shell integration, and tmux/Zellij discovery remain open; this phase has not been deferred or declared complete.

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

### 07.4 tmux and Zellij discovery

- Detect availability without mutating the remote host.
- List attachable sessions with explicit user choice.
- Create/attach/detach through visible commands and predictable cleanup.
- Handle missing tools, version differences, nested sessions, and failed attach.
- Prefer this path for resumability before a custom remote daemon.

### 07.5 File references and working-directory actions

- Validate remote paths and distinguish them from local files.
- Offer safe SFTP/open/copy actions based on session identity.
- Apply Phase 03 SFTP containment and collision rules.
- Never open arbitrary local URLs from untrusted shell metadata.

## Acceptance criteria

- Command blocks, working directory, exit status, selection, and file references derive from defined semantic signals.
- Workspace restore creates fresh authorized sessions and reports partial failures.
- tmux/Zellij discovery and attach work without a proprietary daemon.
- Semantic history has bounded retention and deletion and excludes secret input.
- Platform shells present workspaces natively.

## Tests

- OSC 133 and shell-integration parsing, fragmentation, malformed input, and fallback.
- Secret-input exclusion and history retention/deletion.
- Workspace serialization, migration, partial restore, and missing endpoint behavior.
- tmux/Zellij availability, listing, attach, detach, error, and nested-session fixtures.
- Remote file-reference validation and SFTP handoff.

## Manual verification

- bash, zsh, fish, tmux, and Zellij on representative hosts.
- Long-running workspace interruption and reconnect.
- visionOS spatial grouping plus native macOS/iPadOS presentations when available.

## Exit evidence

- Documented shell-integration protocol and privacy model.
- Green semantic/workspace regression suite.
- Demonstrated resumable workflow through tmux or Zellij.
