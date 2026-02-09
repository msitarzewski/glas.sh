# 260209_terminal-performance-redraw-and-stream-coalescing

## Objective
Reduce terminal rendering overhead and frame churn when running high-frequency full-screen TUIs (for example, `htop` in a larger terminal window on device).

## Outcome
- ✅ Reduced forced redraw pressure in SwiftTerm host integration.
- ✅ Removed duplicate terminal parsing work in `TerminalSession`.
- ✅ Added output coalescing so SwiftUI is not driven once per packet/frame.
- ✅ On-device user validation reported noticeably improved behavior ("Much better!").

## Files Modified
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`
  - Made host attachment idempotent for the same `TerminalView`.
  - Avoided repeated theme application when values are unchanged.
  - Removed explicit full-bounds redraw trigger in `rangeChanged`.
  - Disabled `clearsContextBeforeDrawing` to reduce redraw overhead.
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift`
  - Removed duplicate local terminal-emulator parsing/snapshot path.
  - Added buffered terminal output flush scheduling (`~8ms`) to coalesce packet bursts into fewer UI updates.
  - Preserved clear-screen behavior while cancelling pending buffered output before emitting clear control sequence.
- `/Users/michael/Developer/glas.sh/memory-bank/tasks/2026-02/README.md`
  - Added task summary entry for this work.

## Integration Points
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift:429` `feedTerminalData(_:)` now buffers and schedules flushes instead of incrementing nonce for every packet.
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift:468` flush path emits a single `terminalInputNonce` update per coalesced chunk.
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift:204` no longer forces full-view redraw on `rangeChanged`.

## Validation
- Build passed earlier in branch for the same target during first optimization pass.
- Later local build verification in this environment became blocked by CoreSimulator/DerivedData permission failures.
- Functional validation for this change set is user-confirmed on device under the target scenario.

## Notes
- Runtime/system logs such as `nw_socket_copy_info ... TCP_INFO`, audio session warnings, and persona sandbox warnings were observed but are not primary terminal-render-loop signals for this issue.
