# 260216_terminal-carriage-return-and-stream-queue-fix

## Objective
Fix terminal in-place status/progress rendering regressions where carriage-return (`\r`) updates (for example apt/wget/curl progress) were rendering as stacked lines in the visionOS terminal window.

## Outcome
- ✅ Diagnosed newline-stacking behavior against real Ubuntu workloads (`apt upgrade`, `wget --progress=bar:force:noscroll`).
- ✅ Updated PTY terminal-mode negotiation to only disable CR->NL translation (`OCRNL=0`) and avoid breaking normal newline behavior.
- ✅ Reworked terminal host data bridge from single-chunk overwrite semantics to queued chunk drain semantics to prevent high-frequency stream chunk loss.
- ✅ Preserved existing terminal coalescing approach while ensuring no dropped control bytes between UI updates.
- ✅ Validated with user-run runtime checks that in-place progress now renders correctly instead of line stacking.

## Files Modified
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift`
  - Added `SSHConnection.preferredPTYTerminalModes()` and wired PTY request to use it.
  - Added queued terminal chunk buffering for UI handoff (`pendingTerminalInputChunks` + drain method).
- `/Users/michael/Developer/glas.sh/glas.sh/TerminalWindowView.swift`
  - Changed terminal ingest binding to drain all queued chunks and feed as one payload per nonce update.
- `/Users/michael/Developer/glas.sh/glas.shTests/glas_shTests.swift`
  - Added PTY mode regression coverage asserting `OCRNL` handling and non-forcing of `ONLCR` / `ONLRET`.

## Validation
- `xcodebuild -project /Users/michael/Developer/glas.sh/glas.sh.xcodeproj -scheme glas.sh build`
  - Result: `** BUILD SUCCEEDED **`
- `xcodebuild -project /Users/michael/Developer/glas.sh/glas.sh.xcodeproj -scheme glas.sh -destination 'platform=visionOS Simulator,id=AA41662F-0BE4-4689-8FBB-18864AB16F37' test`
  - Result: `** TEST SUCCEEDED **` in stable runs (one prior run hit simulator service-hub instability before this fix set was finalized).
- Manual runtime checks (user-confirmed):
  - `for i in {1..100}; do printf "\rProgress: %3d%%" "$i"; sleep 0.03; done; printf "\nDone\n"`
  - `wget --progress=bar:force:noscroll -O /dev/null http://speedtest.tele2.net/100MB.zip`
  - Observed: in-place progress behavior restored.

## Notes
- Remote PTY state confirmed sane during debugging (`stty` showed `-ocrnl onlcr -onlret`), which helped isolate the remaining issue to the local stream handoff path.
- This change intentionally avoids larger parser/renderer rewrites and keeps blast radius limited to PTY mode negotiation and terminal ingest transport semantics.
