# 260315_sprint1-command-center

## Objective
Implement Sprint 1 of the "Command Center" release — 6 table-stakes features that close critical gaps vs competitors (La Terminal, Prompt 3, Termius).

## Outcome
- All 6 features build clean on visionOS Simulator
- 8 files modified, 1 new file created

## Features Implemented

### 1A. Auto-Reconnect
- `attemptAutoReconnect()` on TerminalSession with exponential backoff (1s/2s/4s/8s/16s, 5 attempts)
- Triggers on unexpected disconnect and keepalive timeout (NOT clean shell exit or user-initiated disconnect)
- `userInitiatedDisconnect` flag prevents reconnect on manual disconnect
- Connection label ornament shows spinner + "Reconnecting... (N/5)" + cancel button
- Toolbar "Disconnect" becomes "Cancel Reconnect" during reconnection
- Files: Models.swift (TerminalSession + SSHConnection), TerminalWindowView.swift

### 1B. Port Forwarding (Local -L)
- `TunnelStatus` enum (inactive/starting/active/error/stopping) replaces boolean `isActive`
- `SSHConnection.createDirectTCPIPChannel()` wraps Citadel DirectTCPIP API
- `PortForwardManager` binds `ServerBootstrap` on localhost, pipes data bidirectionally via SSH channels
- "Coming Soon" banner removed, toggle enabled for local forwards
- Status indicators: starting (spinner), active (green), error (red + message)
- Remote (-R) and dynamic (-D) remain disabled with tooltip
- Files: PortForwardManager.swift (rewritten), Models.swift, PortForwardingManagerView.swift, TerminalWindowView.swift

### 1C. Jump Host / ProxyJump
- Added `jumpHostID: UUID?` to ServerConfiguration
- SSHConnection.connect() refactored: extracted `resolveAuthMethod()`, `resolveHostKeyValidator()`, `connectWithFallback()` helpers
- When jumpHostID is set, connects to jump host first, then calls `jumpClient.jump(to: targetSettings)` via Citadel API
- "Connect via" Picker in AddServerView and EditServerView Routing section
- SessionManager.createSession resolves jumpHostID to full config before connecting
- Files: Models.swift, SessionManager.swift, ServerFormViews.swift

### 1D. SFTP File Browser
- New SFTPBrowserView.swift with full file browser UI
- Directory listing with icons (SF Symbols by extension), name, size, permissions, modified date
- Navigation into directories, back/up, path breadcrumb
- File download via `.fileExporter`, upload via `.fileImporter`
- Create folder, rename, swipe-to-delete with confirmation
- New "sftp" WindowGroup registered in glas_shApp.swift
- "SFTP Browser" button in terminal toolbar menu
- `SSHConnection.openSFTPClient()` wraps `client.openSFTP()` from Citadel
- Files: New SFTPBrowserView.swift, Models.swift, glas_shApp.swift, TerminalWindowView.swift

### 1E. Favorites Section
- Added `.favorites` case to ConnectionSection enum (heart.fill icon, pink color)
- Appears first in sidebar, returns `serverManager.favoriteServers`
- Heart indicator on favorited server rows
- Context menu "Favorite/Unfavorite" toggle on all server rows
- Files: ConnectionManagerView.swift

### 1F. Quick Connect Bar
- Search bar parses `user@host` or `user@host:port` patterns via `quickConnectConfig` computed property
- Quick Connect row appears above server list with bolt icon when pattern detected
- Enter or tap triggers password prompt alert
- Creates temporary session and opens terminal window
- Files: ConnectionManagerView.swift

## Files Modified
- `glas.sh/Models.swift` — ServerConfiguration.jumpHostID, TunnelStatus enum, PortForward refactor, SSHConnection helpers, auto-reconnect, SFTP/DirectTCPIP wrappers
- `glas.sh/TerminalWindowView.swift` — Reconnect UI, SFTP button, port forward status
- `glas.sh/ConnectionManagerView.swift` — Favorites section, quick connect bar
- `glas.sh/PortForwardManager.swift` — Full rewrite with tunnel lifecycle
- `glas.sh/PortForwardingManagerView.swift` — Removed Coming Soon, enabled local forward toggle
- `glas.sh/SessionManager.swift` — Jump host resolution before connect
- `glas.sh/ServerFormViews.swift` — "Connect via" jump host picker
- `glas.sh/glas_shApp.swift` — SFTP window scene registration
- `glas.sh/SFTPBrowserView.swift` — New file, full SFTP browser

## Patterns Applied
- `systemPatterns.md#Terminal Architecture` — auto-reconnect extends session lifecycle
- `systemPatterns.md#NIO ChannelHandler Propagation` — port forwarding uses DirectTCPIP channels
- Citadel's `SSHClient.jump(to:)` for jump host tunneling
- Citadel's `SFTPClient` for file browser operations
- NIO `ServerBootstrap` + bidirectional pipe pattern from Citadel's RemotePortForward for local port forwarding

## Architectural Decisions
- Auto-reconnect reads `UserDefaults.standard.bool(forKey: .autoReconnect)` directly in SSHConnection to avoid coupling to SettingsManager
- Port forwarding Sprint 1 scope: local only. Remote and dynamic deferred.
- Jump host support: single hop only. Multi-hop chains deferred.
- SFTP browser is a separate window (not inline in terminal) for spatial workflow flexibility
- Quick connect creates transient ServerConfiguration (not saved) with password prompt
