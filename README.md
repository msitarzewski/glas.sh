# glas.sh

A native visionOS SSH terminal built for spatial computing. Glass-first UI, multi-window workflow, on-device AI, and zero cloud dependencies.

**[glas.sh](https://glas.sh)** &nbsp;|&nbsp; **[Sponsor](https://github.com/sponsors/msitarzewski)**

---

## Why glas.sh

Every SSH client on visionOS is a port from iPad. glas.sh is built from scratch for spatial computing — terminal windows float in your space, AI runs privately on-device, and the UI is designed for eye-and-hand interaction from the ground up.

| Capability | glas.sh | La Terminal | Prompt 3 | Termius |
|-----------|---------|-------------|----------|---------|
| Native visionOS | Yes | Yes | No | No |
| On-device AI | Foundation Models | Cloud API | No | No |
| Spatial audio | Yes | No | No | No |
| Spatial widgets | Yes | No | No | No |
| Immersive focus mode | Yes | No | No | No |
| SharePlay terminal sharing | Yes | No | No | No |
| SFTP with batch operations | Yes | Basic | No | Yes |
| Tailscale auto-discovery | Yes | No | No | No |
| Session recording + AI summary | Yes | No | No | No |
| Open source | MIT | No | No | No |

---

## Features

### Terminal
- Full PTY interactive sessions via Citadel SSH + SwiftTerm rendering
- ANSI/truecolor support, dynamic resize, cursor styles
- Spatial audio terminal bell (VT100 hardware bell sound)
- Keyboard focus maintenance — no input dropout after idle
- Per-session window appearance overrides (opacity, material, tint)
- In-terminal search overlay
- Command snippets with usage tracking

### AI (On-Device, Private)
- **Command Assistant**: Describe what you want in natural language, get a shell command with risk assessment (safe/moderate/destructive)
- **Error Explainer**: Automatically detects errors in terminal output and explains what went wrong with a suggested fix
- **Session Summary**: AI-generated highlights of recorded terminal sessions
- Powered by Foundation Models — runs entirely on-device, no data leaves your Vision Pro

### Connections
- Server management with favorites, tags, search, recent connections
- Quick connect bar — type `user@host:port` and go
- Host key verification (Ask / Strict / Accept Any) with fingerprint display
- SSH key authentication (RSA, Ed25519, Secure Enclave P-256)
- Password storage in Keychain with shared access group
- Tailscale auto-discovery — OAuth2 device list, tap to SSH connect
- Layout presets — save and restore multi-server window arrangements

### Port Forwarding
- **Local (-L)**: Bind local port, tunnel through SSH to remote target
- **Remote (-R)**: Server listens on remote port, forwards back through tunnel
- **Dynamic/SOCKS (-D)**: Full SOCKS5 proxy with IPv4, domain, and IPv6 support
- Per-session forward management with status indicators

### Jump Hosts
- Single-hop ProxyJump via Citadel's `SSHClient.jump(to:)`
- Multi-hop chains — configure A → B → C with reorderable hop list
- Cycle detection prevents infinite loops
- Backward compatible with single-hop configurations

### SFTP File Browser
- Full directory browsing with breadcrumb navigation
- Tap-to-select files with checkboxes, select all/none
- Batch download and delete operations
- Download flow: pick destination folder first, then stream with progress (256KB chunks)
- File info sheet (permissions, uid/gid, timestamps, raw listing)
- Show/hide hidden files toggle
- Client-side filter + remote `find` via SSH for deep search
- Upload files from device

### Security
- **True Secure Enclave signing** — P-256 keys generated inside hardware, private key never leaves the chip
- Biometric authentication (Optic ID) before Secure Enclave key use
- Keychain storage with shared access group for cross-app credential sharing
- Host key trust with per-server fingerprint tracking
- Legacy key support (RSA SHA-2, Ed25519, wrapped SE keys)

### Spatial Features
- **Immersive Focus Mode** — dims passthrough for distraction-free terminal work, Digital Crown controls depth
- **Spatial Widgets** — server health widget (small + medium) with tap-to-connect deep links
- **SharePlay** — share terminal sessions over FaceTime with participant tracking
- **Notification Overlays** — in-window banners for connection events (auto-dismiss, max 3 visible)
- Glass material picker — ultraThin, thin, regular, thick
- Color tint with preset swatches + full color picker

### Session Recording
- Asciicast v2 format (NDJSON) — compatible with asciinema
- Records terminal input and output with timestamps
- Storage in Documents/recordings/ — typically 50KB–5MB per hour
- AI-powered session summaries via Foundation Models
- Auto-record option per settings

### Auto-Reconnect
- Exponential backoff (1s/2s/4s/8s/16s, up to 5 attempts)
- Cancel button in connection label ornament
- Keepalive timer with failure-based timeout detection

---

## Architecture

```
glas.sh/                         Main app (visionOS 26)
├── Models.swift                 SSH sessions, connections, server config
├── TerminalWindowView.swift     Terminal UI with ornaments
├── ConnectionManagerView.swift  Server list, Tailscale, layouts
├── AIAssistant.swift            Foundation Models integration
├── SessionRecorder.swift        Asciicast v2 recording
├── TailscaleClient.swift        OAuth2 + REST API v2
├── TerminalAudioManager.swift   Spatial audio bell
├── SharePlayManager.swift       GroupActivity terminal sharing
├── FocusEnvironmentView.swift   Immersive focus environment
├── NotificationOverlay.swift    In-window notification banners
├── SFTPBrowserView.swift        File browser with batch ops
├── PortForwardManager.swift     Local/Remote/Dynamic tunnels
├── SettingsManager.swift        App settings persistence
├── ServerManager.swift          Server CRUD + shared defaults
├── SessionManager.swift         Session lifecycle
└── KeychainManager.swift        Secure credential storage

glasWidgets/                     Widget extension
├── ServerHealthWidget.swift     Timeline provider + views
└── glasWidgets.swift            Widget bundle entry point

Packages/
├── RealityKitContent/           SwiftTerm host wrapper
├── Citadel/                     SSH client library
└── swift-nio-ssh/               Vendored NIO SSH (patched)
```

### Terminal Stack

- **Network/SSH**: Citadel + vendored swift-nio-ssh
- **Terminal rendering**: SwiftTerm `TerminalView` hosted in SwiftUI via `UIViewRepresentable`
- **Input**: SwiftTerm delegate → raw bytes → SSH channel
- **Output**: SSH channel → buffered chunks → SwiftTerm `feed(byteArray:)`
- **Resize**: SwiftTerm callback → `TerminalSession` → remote PTY resize

### Key Patterns

- `@Observable` + `@MainActor` for all managers and models
- `PBXFileSystemSynchronizedRootGroup` — Xcode auto-includes directory contents
- `.restorationBehavior(.disabled)` on all windows (SSH sessions are ephemeral)
- `Window` (singleton) for Connections, `WindowGroup` for terminal instances
- 2-second periodic focus maintenance timer (visionOS RTI workaround)
- `AVAudioSession.ambient` for bell sounds (mixes with other audio)
- `#if canImport(FoundationModels)` gates for AI features
- Shared App Group `group.sh.glas.shared` for cross-app data

---

## Requirements

- **Xcode 26 beta** (for Foundation Models + WidgetKit visionOS 26 APIs)
- **visionOS 26 SDK**
- Apple Vision Pro (Secure Enclave features require hardware)

## Build & Run

```bash
open glas.sh.xcodeproj
# Select scheme: glas.sh
# Select destination: Apple Vision Pro (simulator or device)
# Build and run (⌘R)
```

## Project Site

A lightweight project site lives in `docs/` for GitHub Pages.

- Source: `docs/index.html`, `docs/styles.css`
- URL: [msitarzewski.github.io/glas.sh](https://msitarzewski.github.io/glas.sh/)

---

## Known Limitations

- SSH Agent auth path is present in UI but not yet wired to agent-based authentication
- visionOS does not provide an API for custom passthrough blur — only system Materials
- Secure Enclave keys are device-bound and cannot be transferred to another device
- SharePlay viewer mode is currently read-only (no remote input yet)
- `SecureEnclave.isAvailable` returns false in the visionOS Simulator

## License

MIT License. Copyright 2026 Michael Sitarzewski.
