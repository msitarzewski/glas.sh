# glas.sh (visionOS)

`glas.sh` is a native visionOS SSH terminal app with a glass-first UI and multi-window workflow.

This README documents the **current implementation** in this repository.

## Links

- Website: [glas.sh](https://glas.sh)
- GitHub Sponsors / donations: [github.com/sponsors/msitarzewski](https://github.com/sponsors/msitarzewski)

## Live Now

- Native SSH connection flow using Citadel (`SSHClient.withPTY`)
- PTY interactive terminal sessions (not command-by-command exec)
- Dynamic PTY resize via `WindowChangeRequest` (rows/cols update as terminal size changes)
- SwiftTerm-backed terminal rendering (real terminal widget, not a text-log approximation)
- ANSI/truecolor-capable rendering through SwiftTerm
- Multi-window architecture:
  - Connection manager
  - Terminal windows (per session)
  - HTML preview window
  - Port forwarding manager window
  - Settings window
- VisionOS ornament-based UI:
  - Top server ornament
  - Left tools rail (compact/expanded)
  - Right info ornament
  - Bottom session/status bar
- Session close on clean remote exit
- Secure password retrieval via Keychain helper

## Current Terminal Stack

- Network/SSH: `Citadel` + vendored `swift-nio-ssh` compatibility patch
- Terminal view: `SwiftTerm` `TerminalView` hosted in SwiftUI
- Input path: SwiftTerm -> delegate callback -> raw bytes -> SSH channel
- Output path: SSH channel stdout/stderr -> SwiftTerm `feed(byteArray:)`
- Resize path: SwiftTerm size change callback -> `TerminalSession.updateTerminalGeometry(...)` -> remote PTY resize

Primary files:

- `glas.sh/Models.swift`
- `glas.sh/TerminalWindowView.swift`
- `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`
- `Packages/RealityKitContent/Package.swift`

## Project Structure

- `glas.sh/`
  - App entry + UI windows + models/managers
- `Packages/RealityKitContent/`
  - App-shared package used by the main target
  - SwiftTerm host wrapper and terminal helpers
- `Packages/Citadel/`
  - Vendored SSH client package
- `Packages/swift-nio-ssh/`
  - Vendored patched dependency for toolchain compatibility

## Run (Xcode)

1. Open `glas.sh.xcodeproj`
2. Select scheme: `glas.sh`
3. Select a visionOS Simulator destination
4. Build and run

## Notable Behavior

- Typing `exit` in remote shell is treated as clean session termination.
- Terminal background defaults to transparent so the glass scene shows through unless host output explicitly paints backgrounds.
- Left tools rail supports compact/expanded interaction and ornament placement separate from the terminal pane.

## Aspirational / In Progress

These are not fully shipped yet:

- System close affordance interception/warning for active remote processes (only in-app close flows can currently be fully controlled).
- Final polish for rail gaze/hover behavior across all input/runtime combinations.
- Additional terminal parity work (selection semantics, advanced key mapping, and edge-case TUI behavior).

## Notes On Local Artifacts

Local Xcode/SwiftPM state is intentionally gitignored (for cleaner diffs and fewer merge conflicts):

- `xcuserdata`
- `.swiftpm`
- derived/build output

See `.gitignore`.
