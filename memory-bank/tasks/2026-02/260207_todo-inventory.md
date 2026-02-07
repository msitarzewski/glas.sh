# TODO Inventory (2026-02-07)

## Purpose
Consolidated inventory of `TODO`/`FIXME`/`XXX`/`HACK` markers found in the repository, grouped by ownership and relevance.

## Summary
- App/shared code markers: 21
- Vendored dependency markers: 21
- Docs/memory-bank markers: 0 (excluding this inventory document)

## App and Shared Package Backlog (Actionable)

### `/Users/michael/Developer/glas.sh/glas.sh`
- `/Users/michael/Developer/glas.sh/glas.sh/ConnectionManagerView.swift:184` - show password prompt flow.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:66` - implement back navigation when WebPage API supports it.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:71` - enable back/forward controls when implemented.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:74` - implement forward navigation when WebPage API supports it.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:79` - enable back/forward controls when implemented.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:222` - open dev tools when API supports it.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:227` - implement JavaScript API action when available.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:232` - implement snapshot API action when available.
- `/Users/michael/Developer/glas.sh/glas.sh/HTMLPreviewWindow.swift:237` - implement PDF export when available.
- `/Users/michael/Developer/glas.sh/glas.sh/Managers.swift:385` - wire real port-forward start/stop transport.
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift:593` - implement SSH key authentication path.
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift:605` - implement SSH agent authentication path.
- `/Users/michael/Developer/glas.sh/glas.sh/ServerFormViews.swift:189` - add file picker for SSH key selection.
- `/Users/michael/Developer/glas.sh/glas.sh/TerminalWindowView.swift:250` - open SFTP browser action.
- `/Users/michael/Developer/glas.sh/glas.sh/TerminalWindowView.swift:262` - show snippets panel action.
- `/Users/michael/Developer/glas.sh/glas.sh/TerminalWindowView.swift:322` - split terminal behavior.

### `/Users/michael/Developer/glas.sh/Packages/RealityKitContent`
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/SSHConnection.swift:44` - implement SSH key authentication.
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/SSHConnection.swift:55` - implement SSH agent authentication.
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/SSHConnection.swift:67` - replace permissive host key validation.
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/SSHConnection.swift:115` - complete ANSI escape parsing path.
- `/Users/michael/Developer/glas.sh/Packages/RealityKitContent/SSHConnection.swift:167` - implement window-size change signaling.

## Vendored Dependency Markers (Reference Only)
These are in third-party vendored packages and should generally not be treated as immediate app backlog unless we intentionally maintain a fork.

### `Packages/Citadel`
- `/Users/michael/Developer/glas.sh/Packages/Citadel/README.md:365`
- `/Users/michael/Developer/glas.sh/Packages/Citadel/Sources/Citadel/SFTP/SFTPFileFlags.swift:133`
- `/Users/michael/Developer/glas.sh/Packages/Citadel/Sources/Citadel/SFTP/Client/SFTPFile.swift:289`
- `/Users/michael/Developer/glas.sh/Packages/Citadel/Sources/CitadelServerExample/EchoShell/EchoShell.swift:106`
- `/Users/michael/Developer/glas.sh/Packages/Citadel/Tests/CitadelTests/RemotePortForwardTests.swift:86`

### `Packages/swift-nio-ssh`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:198`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:250`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:448`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:566`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:593`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:682`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Connection State Machine/SSHConnectionStateMachine.swift:730`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Child Channels/SSHChannelData.swift:111`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/Child Channels/SSHChannelMultiplexer.swift:190`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/NIOSSHHandler.swift:204`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:23`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:76`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:136`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:250`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:352`
- `/Users/michael/Developer/glas.sh/Packages/swift-nio-ssh/Sources/NIOSSH/User Authentication/UserAuthenticationStateMachine.swift:370`

## Tracking Guidance
- Use this file as the canonical TODO index for this phase.
- Prioritize actionable items under app/shared code.
- Treat vendored markers as upstream/fork-maintenance concerns.
