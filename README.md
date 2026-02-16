# glas.sh (visionOS)

`glas.sh` is a native visionOS SSH terminal app with a glass-first UI and multi-window workflow.

This README documents the **current implementation** in this repository.

## Links

- Website: [glas.sh](https://glas.sh)
- GitHub Sponsors / donations: [github.com/sponsors/msitarzewski](https://github.com/sponsors/msitarzewski)

## Live Now

- Native SSH connection flow using Citadel (`SSHClient.withPTY`)
- SSH negotiation compatibility retry (`SSHAlgorithms()` first, then `.all` on key-exchange failure)
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
- Connection manager with favorites/recent sections, tag filters, and server search
- Host key trust flow:
  - host key verification mode (Ask / Strict / Insecure Accept Any)
  - trust prompt with fingerprint details
- Terminal window UX:
  - footer-first status/actions
  - in-window search overlay
  - terminal-local settings modal (`Terminal`, `Overrides`, `Port Forwarding`)
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

## GitHub Pages

A lightweight project site now lives in `docs/` for GitHub Pages.

- Source files:
  - `docs/index.html`
  - `docs/styles.css`
- Suggested Pages URL (once enabled):
  - `https://msitarzewski.github.io/glas.sh/`

To publish from this repository:

1. Push this branch and merge to `main`.
2. In GitHub: **Settings -> Pages**.
3. Set **Source** to **Deploy from a branch**.
4. Select branch `main` and folder `/docs`.
5. Save and wait for the first Pages deployment.

## Notable Behavior

- Typing `exit` in remote shell is treated as clean session termination.
- Terminal display background opacity/blur/tint applies to the terminal pane, with per-session overrides.
- Settings can be opened from the Connections window and in a dedicated Settings window.

## Known Limitations

- `SSH Key` and `SSH Agent` auth paths are present in UI, but connection auth still falls back to password-based auth.
- Port forwarding UI/state management exists, but start/stop forwarding is not yet wired to active SSH forwarding.

## Aspirational / In Progress

These are not fully shipped yet:

- System close affordance interception/warning for active remote processes (only in-app close flows can currently be fully controlled).
- Full SSH key-based and SSH agent-based authentication execution path.
- Active SSH port forwarding lifecycle (start/stop backing tunnel operations).
- Additional terminal parity work (selection semantics, advanced key mapping, and edge-case TUI behavior).

## Notes On Local Artifacts

Local Xcode/SwiftPM state is intentionally gitignored (for cleaner diffs and fewer merge conflicts):

- `xcuserdata`
- `.swiftpm`
- derived/build output

See `.gitignore`.
