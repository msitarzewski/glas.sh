# 260209_connections-window-recovery-and-terminal-footer-actions

## Objective
Prevent the “no windows left” dead-end, simplify terminal actions, and stabilize Connections window behavior so recovery is predictable.

## Outcome
- ✅ Removed experimental beacon window flow and restored Connections as the canonical recovery surface.
- ✅ Added app-level window recovery watcher that re-activates Connections when all tracked windows disappear.
- ✅ Ensured Connections is a single-instance scene to avoid duplicate windows from repeated reopen calls.
- ✅ Consolidated terminal actions into a single footer gear menu for cleaner UI.
- ✅ Added a footer-center Connections button in terminal windows to quickly reopen the Connections window.

## Files Modified
- `/Users/michael/Developer/glas.sh/glas.sh/glas_shApp.swift`
  - Switched `main` scene to single-instance `Window("Connections", id: "main")`.
  - Removed beacon scene and related view code.
  - Added shared window-presence tracking for scene roots.
- `/Users/michael/Developer/glas.sh/glas.sh/Managers.swift`
  - Added `WindowRecoveryManager` for app-level empty-window detection and recovery.
  - Simplified recovery target to `main`.
- `/Users/michael/Developer/glas.sh/glas.sh/ConnectionManagerView.swift`
  - On successful connect, opens terminal and closes `main` via `dismissWindow(id: "main")`.
  - Removed beacon-open calls.
- `/Users/michael/Developer/glas.sh/glas.sh/TerminalWindowView.swift`
  - Removed ornament rail experiments.
  - Restored single gear menu with Search/Clear/HTML Preview/Duplicate/Reconnect/Settings.
  - Added centered footer Connections button that opens `main`.
  - Updated close-time recovery calls to open `main`.

## Validation
- `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Debug -destination "platform=visionOS Simulator,id=AA41662F-0BE4-4689-8FBB-18864AB16F37" build`
- Result: `** BUILD SUCCEEDED **`

## Notes
- Recovery now relies on app-level scene presence tracking, not only terminal view lifecycle callbacks.
- Connections reopen now targets a single window instance, reducing stacked duplicate windows during recovery and manual reopen.
