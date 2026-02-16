# 2026-02 Tasks

## 2026-02-16: Terminal carriage-return rendering + stream queue handoff fix
- Fixed in-place progress rendering regressions where carriage-return status updates were stacking on new lines.
- Adjusted PTY mode negotiation to disable only CR->NL translation (`OCRNL`) without breaking standard newline behavior.
- Reworked terminal ingest handoff from single chunk overwrite semantics to queued chunk drain semantics to prevent dropped control-byte updates under burst output.
- Validated against real Ubuntu progress workloads (`apt`, `wget`) with user-confirmed in-place behavior.
- See: [260216_terminal-carriage-return-and-stream-queue-fix.md](./260216_terminal-carriage-return-and-stream-queue-fix.md)

## 2026-02-16: Secure Enclave migration plan + key-type badging kickoff
- Defined approved migration strategy for Secure Enclave adoption across password and SSH key handling.
- Started implementation with a secret storage abstraction and migration scaffold entrypoint.
- Added backward-compatible SSH key metadata model for source/algorithm badge rendering.
- Added key-type badges to visible SSH key selection/management surfaces.
- See: [260216_secure-enclave-migration-and-key-badging-plan.md](./260216_secure-enclave-migration-and-key-badging-plan.md)

## 2026-02-15: Connections native UI + tag search filters + form persistence
- Reworked Connections to use native visionOS split-view/list/search/toolbar patterns with reduced custom ornament behavior.
- Added alphabetical left-nav section ordering and promoted tag filtering into search submit flow.
- Added active tag filter chips under the title area and removed bottom pill strip.
- Fixed tag entry persistence on Save in both Add and Edit server forms.
- Fixed SSH key picker persistence reliability in Add/Edit flows.
- See: [260215_connections-native-ui-tag-search-filters-and-form-persistence.md](./260215_connections-native-ui-tag-search-filters-and-form-persistence.md)

## 2026-02-09: Connections recovery + terminal footer actions
- Removed beacon-window experiment and returned to Connections as the single recovery target.
- Added app-level window-presence recovery watcher to reopen Connections when all windows are closed.
- Switched Connections scene to a single-instance `Window` to prevent duplicate Connections windows.
- Consolidated terminal actions into one gear menu and added centered footer Connections quick-open button.
- See: [260209_connections-window-recovery-and-terminal-footer-actions.md](./260209_connections-window-recovery-and-terminal-footer-actions.md)
## 2026-02-09: Terminal performance redraw and stream coalescing
- Reduced redraw pressure in SwiftTerm host integration by removing forced full-view invalidation and avoiding repeated unchanged theme application.
- Removed duplicate terminal-emulator parsing path in `TerminalSession`.
- Added terminal output coalescing to reduce per-frame `onChange(UInt64)` update pressure under high-frequency output.
- User-validated improvement on device during enlarged full-screen `htop` scenario.
- See: [260209_terminal-performance-redraw-and-stream-coalescing.md](./260209_terminal-performance-redraw-and-stream-coalescing.md)

## 2026-02-08: SSH key management + config import + trust scoping
- Added settings-level SSH key CRUD with Keychain-backed private key storage.
- Added pasted OpenSSH config import (safe subset parser and sanitization warnings).
- Scoped host-key trust persistence to server configurations and wired trust acceptance into server updates.
- Added explicit RSA messaging: support coming soon, ED25519 supported now.
- See: [260208_ssh-key-management-config-import-and-trust-scoping.md](./260208_ssh-key-management-config-import-and-trust-scoping.md)

## 2026-02-08: Terminal window UX polish + in-window session settings
- Replaced toolbar/rail experiments with compact footer action controls.
- Added in-terminal search overlay and centered terminal session settings modal.
- Moved session-specific controls out of global settings into terminal-local tabs.
- Added inline terminal-session port forwarding management.
- Scoped tint/transparency behavior to terminal display background to avoid tinting text output.
- See: [260208_terminal-window-ux-polish-and-session-settings.md](./260208_terminal-window-ux-polish-and-session-settings.md)

## 2026-02-08: Settings UX + session management + SSH handshake fixes
- Implemented sticky settings access in Connections and refined visionOS-style settings UX.
- Wired settings/session persistence and host-key trust workflows.
- Fixed SSH negotiation failures with compatibility retry and improved connection diagnostics.
- Added live connection card activity ticker and pulse animation during connect.
- See: [260208_settings-ux-session-management-and-ssh-handshake.md](./260208_settings-ux-session-management-and-ssh-handshake.md)

## 2026-02-07: Repository and docs cleanup
- Moved app-folder markdown task docs into memory bank task records.
- Added core `memory-bank/` structure per AGENTS guidelines.
- Consolidated project documentation flow around root README + memory bank.

Task records:
- [260207_critical-actions-required.md](./260207_critical-actions-required.md)
- [260207_final-build-fixes.md](./260207_final-build-fixes.md)
- [260207_fixes-applied.md](./260207_fixes-applied.md)
- [260207_migration-guide.md](./260207_migration-guide.md)
- [260207_ssh-implementation.md](./260207_ssh-implementation.md)
- [260207_todo-inventory.md](./260207_todo-inventory.md)
- [260208_settings-ux-session-management-and-ssh-handshake.md](./260208_settings-ux-session-management-and-ssh-handshake.md)
- [260208_ssh-key-management-config-import-and-trust-scoping.md](./260208_ssh-key-management-config-import-and-trust-scoping.md)
- [260208_terminal-window-ux-polish-and-session-settings.md](./260208_terminal-window-ux-polish-and-session-settings.md)
- [260209_connections-window-recovery-and-terminal-footer-actions.md](./260209_connections-window-recovery-and-terminal-footer-actions.md)
- [260209_terminal-performance-redraw-and-stream-coalescing.md](./260209_terminal-performance-redraw-and-stream-coalescing.md)
- [260215_connections-native-ui-tag-search-filters-and-form-persistence.md](./260215_connections-native-ui-tag-search-filters-and-form-persistence.md)
