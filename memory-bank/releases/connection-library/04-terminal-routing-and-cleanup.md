# Phase 04 — Terminal Routing and Cleanup

## Objective

Connect the new Library presentation to the existing terminal/workgroup lifecycle, then remove every displaced route and view branch.

## Routing rules

- Library `Connect` opens a new terminal window and leaves the Library open.
- Workgroup launch uses existing `LayoutPreset` and `TerminalWorkgroup` behavior.
- Local Terminal uses the existing local PTY path.
- Terminal footer `+` and Command-T add a tab within the active terminal window.
- Connection management never creates a parallel session object or bypasses existing authorization and host-trust policy.

## Cleanup work

1. Route all launch actions through the existing `SessionManager` and app scene boundary.
2. Inventory and remove the legacy terminal scene only after every caller moves to the authoritative route.
3. Delete old macOS duplicate sections, independent selection flags, obsolete two-column branches, and unused Tailscale presentation flags.
4. Remove helpers and tests made unreachable by the new projection.
5. Run symbol, production marker, and orphan-source scans.
6. Compare file and branch complexity before and after; investigate any net increase caused by duplicate UI logic.

## Tests

- Connect opens a new terminal window without dismissing the Library.
- Workgroup opens the configured command-per-tab recipe.
- Local terminal launch and clean shell exit remain correct.
- Terminal `+` and Command-T create tabs in the focused window.
- Multiple terminal windows and workgroups retain distinct state.
- Deleted or missing profiles fail through existing user-visible error policy.

## Exit gate

Every launch path uses existing authorities, all displaced implementation is removed, and terminal appearance/lifecycle regressions are absent.
