# 260315_comprehensive-audit-fix

## Objective
Fix 19 instances of code that exists but isn't wired correctly, discovered via comprehensive audit of the NIOSSH, Citadel, and app layers.

## Outcome
- 7 package-level wiring fixes (NIOSSH + Citadel)
- 6 app-layer feature wiring fixes
- 7 dead code removals across 4 files
- All changes build clean on visionOS simulator

## Phase A: Package Wiring Fixes

### A1. channelInactive not forwarded (NIOSSHHandler.swift:159)
Added `context.fireChannelInactive()` — downstream handlers now learn when connection dies.

### A2. remoteAddress0 copy-paste bug (SSHChildChannel.swift:178)
Changed `localAddress0()` to `remoteAddress0()` — was returning local address for remote address queries.

### A3. GlueHandler partner close methods (NIOGlueHandler.swift:48-54)
Uncommented `partnerWriteEOF()` and `partnerCloseFull()` — partner channels now close when one side dies/errors.

### A4. channelHandlers silently discarded (ClientSession.swift:185)
Added loop to insert `settings.channelHandlers` into pipeline before NIOSSHHandler.

### A5. inboundChannelHandler parameter ignored (ClientSession.swift:152)
Changed `SSHClientInboundChannelHandler()` to `inboundChannelHandler` — caller's handler now passed through.

### A6. ExecOutputHandler.onExit never invoked (ExecHandler.swift:178)
Added `handler.onExit?(ExecExitContext())` before `channel.close` on success path.

### A7. SFTPServerInboundHandler.initialized never succeeded (SFTPServerInboundHandler.swift:31-47)
Added `initialized.succeed(())` after version handshake, `initialized.fail()` on version mismatch.

## Phase B: App Feature Wiring

### B1. confirmBeforeClosing (TerminalWindowView.swift)
Added "Disconnect" button to toolbar menu with confirmation alert when setting is enabled and session is connected.

### B2. closeAllSessions (glas_shApp.swift)
Added `scenePhase` monitoring to `MainBootstrapView` — calls `sessionManager.closeAllSessions()` when app enters background.

### B3. bellEnabled/visualBell (SwiftTermHostView.swift + TerminalWindowView.swift)
Wired `onBell` callback through SwiftTermHostView. Visual bell flashes white overlay; audio bell plays system sound 1007.

### B4. forwardAgent/compression (Models.swift + ConnectionManagerView.swift)
Changed defaults from `true` to `false` for new servers. Info panel now shows "Coming Soon" instead of On/Off.

### B5. Snippet execution (TerminalWindowView.swift)
Added snippet picker sheet accessible from toolbar menu. On selection calls `session.sendCommand()` + `settingsManager.useSnippet()`.

### B6. Port forwarding Coming Soon (PortForwardingManagerView.swift)
Added info banner explaining feature is coming. Disabled active/inactive toggle. Config add/remove still works.

## Phase C: Dead Code Cleanup

Removed from `Models.swift`: `systemInfo` property, `SystemInfo` struct, `sendKeyPress()`, `feedTerminalText()`
Removed from `TerminalWindowView.swift`: `TerminalLineView`, `FooterGlassIconButton` (legacy pre-SwiftTerm views)
Removed from `Logger.swift`: `Logger.app` (unused category)
Removed from `ConnectionManagerView.swift`: `ConnectionSection.isTag` (dead helper)

Kept (active scaffolding): `favoriteServers`, `toggleFavorite()`, `ConnectionProgressStage.orderedFlow/.flowIndex`, `KeychainManager.retrieveSecureEnclaveWrappedP256()`

## Files Modified
- `Packages/swift-nio-ssh/Sources/NIOSSH/NIOSSHHandler.swift`
- `Packages/swift-nio-ssh/Sources/NIOSSH/Child Channels/SSHChildChannel.swift`
- `Packages/swift-nio-ssh/Sources/NIOSSH/Child Channels/SSHChannelMultiplexer.swift`
- `Packages/Citadel/Sources/Citadel/NIOGlueHandler.swift`
- `Packages/Citadel/Sources/Citadel/ClientSession.swift`
- `Packages/Citadel/Sources/Citadel/Exec/Server/ExecHandler.swift`
- `Packages/Citadel/Sources/Citadel/SFTP/Server/SFTPServerInboundHandler.swift`
- `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`
- `glas.sh/TerminalWindowView.swift`
- `glas.sh/glas_shApp.swift`
- `glas.sh/Models.swift`
- `glas.sh/ConnectionManagerView.swift`
- `glas.sh/PortForwardingManagerView.swift`
- `glas.sh/Logger.swift`
