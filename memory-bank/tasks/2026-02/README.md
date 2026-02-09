# 2026-02 Tasks

## 2026-02-09: Terminal performance redraw and stream coalescing
- Reduced redraw pressure in SwiftTerm host integration by removing forced full-view invalidation and avoiding repeated unchanged theme application.
- Removed duplicate terminal-emulator parsing path in `TerminalSession`.
- Added terminal output coalescing to reduce per-frame `onChange(UInt64)` update pressure under high-frequency output.
- User-validated improvement on device during enlarged full-screen `htop` scenario.
- See: [260209_terminal-performance-redraw-and-stream-coalescing.md](./260209_terminal-performance-redraw-and-stream-coalescing.md)

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
- [260208_terminal-window-ux-polish-and-session-settings.md](./260208_terminal-window-ux-polish-and-session-settings.md)
- [260209_terminal-performance-redraw-and-stream-coalescing.md](./260209_terminal-performance-redraw-and-stream-coalescing.md)
