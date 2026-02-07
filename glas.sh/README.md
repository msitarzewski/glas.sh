# glas.sh - visionOS Terminal App

A first-class, glass-first SSH terminal experience for visionOS, designed to leverage spatial computing and Apple's Liquid Glass design system.

## 🎯 Project Overview

**glas.sh** is a complete reimagining of SSH terminal access for visionOS. It combines the power of traditional terminal emulation with modern spatial computing paradigms, multiple window management, and Apple's beautiful Liquid Glass aesthetic.

---

## 🏗️ Architecture

### Multi-Window Design

The app uses visionOS's powerful window management to provide:

1. **Terminal Windows** (`WindowGroup` for UUID)
   - Each SSH session gets its own window
   - Can open multiple terminals simultaneously
   - Independent positioning in 3D space
   - Full terminal emulation with scrollback

2. **Connection Manager** (Single `Window`)
   - Central hub for managing all server configurations
   - Browse, search, and organize connections
   - Quick connect to favorites and recent servers
   - ⌘0 keyboard shortcut

3. **HTML Preview Windows** (`WindowGroup` for context)
   - Live web preview with auto-reload
   - Perfect for web development workflows
   - Independent window per preview context
   - Developer tools integration

4. **Port Forwarding Manager** (Single `Window`)
   - Manage SSH tunnels across all sessions
   - Local, remote, and dynamic (SOCKS) forwarding
   - Real-time status monitoring

5. **Settings** (Settings scene)
   - System-standard settings window
   - Theme customization
   - Snippet management
   - Terminal behavior configuration

### Core Components

#### Models (`Models.swift`)

- **`ServerConfiguration`**: Complete server connection details
  - Authentication methods (password, SSH key, agent)
  - Advanced SSH options (compression, keep-alive, PTY)
  - Color tagging and organization
  - Environment variables

- **`TerminalSession`**: Active SSH session state
  - Connection lifecycle management
  - Terminal output buffer with scrollback
  - Port forwarding state
  - System information

- **`PortForward`**: SSH tunnel configuration
  - Local, remote, and dynamic forwarding
  - Active/inactive state tracking

- **`CommandSnippet`**: Saved command templates
  - Quick command execution
  - Usage statistics and favorites

- **`TerminalTheme`**: Complete terminal color scheme
  - ANSI color palette
  - Font configuration
  - Opacity and effects

#### Managers (`Managers.swift`)

- **`SessionManager`**: Central session coordination
  - Create and manage terminal sessions
  - Multi-session support
  - Session lifecycle

- **`ServerManager`**: Server configuration persistence
  - CRUD operations for servers
  - Favorites and recents
  - Tag-based organization

- **`SettingsManager`**: App-wide settings
  - Theme management
  - Snippet library
  - User preferences

- **`KeychainManager`**: Secure credential storage
  - Password encryption in system Keychain
  - Per-server credential management
  - Secure retrieval and deletion

- **`PortForwardManager`**: SSH tunnel management
  - Per-session forward tracking
  - Start/stop tunnel lifecycle

#### Views

##### Terminal Window (`TerminalWindowView.swift`)

The main terminal interface featuring:

- **Glass-backed terminal output** with Liquid Glass effects
- **Spatial ornaments**:
  - **Top**: Toolbar with server info and quick actions
  - **Left**: Sidebar with tools (port forward, HTML preview, SFTP, snippets)
  - **Right**: Info panel (system stats, active forwards)
- **Interactive elements** with `GlassEffectContainer` for smooth morphing
- **Live command input** with auto-scrolling output
- **Status indicators** for connection state

##### Connection Manager (`ConnectionManagerView.swift`)

- **Split view navigation**:
  - Sidebar: All/Favorites/Recent/Tags
  - Detail: Server grid with search
- **Server cards** with:
  - Color-coded visual identity
  - Connection details and authentication info
  - Last connected timestamp
  - Quick connect button
  - Context menu for edit/favorite/delete
- **Glass aesthetic** throughout

##### Server Forms (`ServerFormViews.swift`)

- **Multi-step wizard** for adding servers:
  1. Connection details (host, port, username)
  2. Authentication (password/SSH key/agent)
  3. Options (color tag, tags, favorite)
- **Progress indicator** with completion states
- **Real-time validation**
- **Edit view** with full configuration access
- **Tag management** with FlowLayout

##### Port Forwarding (`PortForwardingManagerView.swift`)

- **Session-based organization**
- **Forward type selection** (local/remote/dynamic)
- **Live preview** of tunnel configuration
- **Toggle active state** per forward
- **Visual status indicators**

##### HTML Preview (`HTMLPreviewWindow.swift`)

- **Native WebView integration** using new SwiftUI WebKit APIs
- **Auto-reload** with configurable interval
- **Navigation controls** (back/forward/reload)
- **Developer tools**:
  - View source
  - Inspect element
  - Take screenshot
  - Export PDF
- **Live URL editing**
- **Glass toolbar** with unified controls

##### Settings (`SettingsView.swift`)

Four tabs of comprehensive settings:

1. **General**: Connection behavior, scrollback, notifications
2. **Terminal**: Theme editor, font selection, cursor style
3. **Appearance**: Glass effects, window opacity, layout
4. **Snippets**: Command library management

---

## 🎨 Liquid Glass Design

The entire app embraces visionOS's Liquid Glass material:

### Glass Effects

- **`.glassEffect()`** on all major UI elements
- **`GlassEffectContainer`** for related controls that morph together
- **`.glassEffectID()`** for animated transitions
- **Interactive glass** (`.interactive()`) on hover-sensitive elements

### Spatial Design

- **Ornaments** for contextual tools and information
  - Positioned around main window using attachment anchors
  - Independent of scroll state
  - Glass-backed for consistency

- **Multiple windows** in 3D space
  - Each terminal session floats independently
  - Connection manager as central hub
  - Preview windows positioned by user

### Visual Hierarchy

- **Color tagging** for server identity
- **Status indicators** with animated symbols
- **Depth through materials** (ultra thin, regular, thick)
- **Hover effects** (`.hoverEffect(.lift)`)

---

## 🔐 Security

### Keychain Integration

- **Passwords never in UserDefaults**
- System Keychain storage per server
- Secure retrieval on connection
- Automatic cleanup on server deletion

### SSH Best Practices

- SSH agent support
- Key-based authentication
- Configurable keep-alive
- Forward agent option
- Per-server environment isolation

---

## 🚀 Features Implemented

### ✅ Core Terminal

- [x] Multi-window terminal sessions
- [x] Terminal output with scrollback
- [x] Command input and execution
- [x] Connection state management
- [x] Session persistence
- [ ] Full terminal emulation (xterm-256color)
- [ ] ANSI escape code parsing
- [ ] Cursor positioning and control
- [ ] Copy/paste support

### ✅ Connection Management

- [x] Server configuration CRUD
- [x] Multiple authentication methods
- [x] Favorites and recents
- [x] Tag-based organization
- [x] Color coding
- [x] Search and filter
- [x] Keychain integration

### ✅ Advanced Features

- [x] Port forwarding UI
- [x] HTML preview windows with auto-reload
- [x] WebView developer tools
- [ ] Port forwarding implementation
- [ ] SFTP file browser
- [ ] File upload/download
- [ ] Session multiplexing

### ✅ UI/UX

- [x] Liquid Glass throughout
- [x] Spatial ornaments
- [x] Multi-window coordination
- [x] Keyboard shortcuts
- [x] Context menus
- [x] Empty states
- [x] Loading indicators
- [x] Error handling UI

### ✅ Customization

- [x] Theme system
- [x] Command snippets
- [x] Comprehensive settings
- [ ] Theme import/export
- [ ] Snippet sharing
- [ ] Custom key bindings

---

## 🔧 Implementation Roadmap

### Phase 1: SSH Connection (Next Priority)

You need to implement the actual SSH functionality. Recommended approach:

1. **Use a Swift SSH library**:
   - [Citadel](https://github.com/Bouke/Citadel) - Pure Swift SSH client
   - [NMSSH](https://github.com/NMSSH/NMSSH) - Objective-C wrapper around libssh2
   - Roll your own with Network framework + libssh2

2. **Terminal emulation**:
   - Parse ANSI escape sequences
   - Implement xterm-256color terminal type
   - Handle cursor control codes
   - Process SGR (color/style) codes

3. **PTY management**:
   - Request pseudo-terminal from server
   - Handle window size changes (SIGWINCH)
   - Process control characters (Ctrl+C, Ctrl+D, etc.)

### Phase 2: Port Forwarding

1. **Local forwarding** (-L):
   - Listen on local port
   - Forward connections through SSH to remote host:port

2. **Remote forwarding** (-R):
   - Request server to listen on remote port
   - Forward connections back through SSH to local host:port

3. **Dynamic forwarding** (-D):
   - SOCKS proxy on local port
   - Route traffic through SSH tunnel

### Phase 3: File Operations

1. **SFTP integration**:
   - Browse remote filesystem
   - Upload/download files
   - File permission management
   - Drag-and-drop support

2. **SCP support**:
   - Quick file transfers
   - Progress indication

### Phase 4: Advanced Terminal

1. **Search**:
   - In-session search with highlighting
   - Regular expression support
   - Search history

2. **Selection and copy/paste**:
   - Text selection in terminal
   - Copy with formatting preservation
   - Paste with bracketed paste mode

3. **Split panes**:
   - Horizontal/vertical splits
   - Multiple sessions per window
   - Synchronized input

---

## 📁 File Structure

```
glas.sh/
├── glas_shApp.swift          # App entry point with window definitions
├── Models.swift               # Data models and core types
├── Managers.swift             # Business logic and state management
├── TerminalWindowView.swift  # Main terminal interface
├── ConnectionManagerView.swift # Server browser and manager
├── ServerFormViews.swift      # Add/edit server forms
├── PortForwardingManagerView.swift # Port forwarding UI
├── HTMLPreviewWindow.swift    # Web preview window
├── SettingsView.swift         # App settings
└── Package.swift              # Swift package for RealityKit content
```

---

## 🎯 Design Principles

### 1. **visionOS-First**

Every design decision considers spatial computing:
- Windows in 3D space, not tabs
- Ornaments for contextual tools
- Depth through glass materials
- Spatial audio for notifications (future)

### 2. **Glass Aesthetic**

Liquid Glass is the primary design language:
- Transparent, blurred backgrounds
- Fluid animations and morphing
- Interactive hover states
- Consistent material hierarchy

### 3. **Professional Power**

Despite beautiful design, this is a tool for developers:
- Multiple concurrent sessions
- Port forwarding for development workflows
- HTML preview for web developers
- Snippet library for efficiency
- Full terminal features

### 4. **Secure by Default**

Security is never compromised:
- Keychain for credentials
- No plain-text password storage
- SSH best practices
- Certificate validation
- Secure defaults

---

## 🎨 Missing Features & Future Ideas

### High Priority

1. **Actual SSH Implementation**
   - Terminal emulation engine
   - PTY handling
   - Connection management

2. **Port Forwarding Backend**
   - Tunnel creation and management
   - Connection proxying

3. **SFTP Browser**
   - File tree navigation
   - Upload/download with progress
   - File editing

### Medium Priority

4. **Session Persistence**
   - Save/restore sessions
   - Auto-reconnect
   - Session recovery

5. **Advanced Terminal Features**
   - Split panes
   - Tabs within windows
   - Tmux/screen integration

6. **Monitoring & Logs**
   - Session logs
   - Connection history
   - Error tracking

### Nice to Have

7. **Collaboration**
   - Shared sessions
   - Screen sharing
   - Session recording/playback

8. **Cloud Sync**
   - iCloud sync for servers
   - Snippet sync
   - Theme sync

9. **Shortcuts Integration**
   - App Shortcuts for connections
   - Siri integration

10. **Activity Widgets**
    - Connection status widget
    - Quick connect widget

11. **Jump Host / Bastion Support**
    - ProxyJump configuration
    - Multi-hop connections

12. **Mosh Support**
    - Mobile shell protocol
    - Better latency handling

---

## 🛠️ Development Notes

### Dependencies Needed

Add these to your Xcode project:

1. **SSH Library** (choose one):
   ```swift
   .package(url: "https://github.com/Bouke/Citadel.git", from: "0.7.0")
   ```

2. **Terminal Emulation** (if not building custom):
   - Consider porting from existing terminal emulator
   - Or build from scratch using ANSI specs

### Build Settings

- **Minimum visionOS**: 1.0 (update Package.swift to reflect actual minimum)
- **Swift version**: 6.2 as specified
- **Capabilities needed**:
  - Network entitlement
  - Keychain access
  - File system access (for SSH keys)

### Testing Strategy

1. **Unit tests** for:
   - ANSI parser
   - Connection state machine
   - Keychain operations
   - Data persistence

2. **Integration tests** for:
   - SSH connection flow
   - Port forwarding
   - SFTP operations

3. **UI tests** for:
   - Window management
   - Multi-session scenarios
   - Connection workflows

---

## 📚 Resources

### visionOS Development

- [visionOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/visionos)
- [Designing for visionOS](https://developer.apple.com/videos/play/wwdc2023/10072/)
- [SwiftUI ornaments](https://developer.apple.com/documentation/swiftui/view/ornament(visibility:attachmentanchor:contentshape:content:))

### SSH/Terminal

- [RFC 4254 - SSH Connection Protocol](https://datatracker.ietf.org/doc/html/rfc4254)
- [ANSI/VT100 Terminal Control Escape Sequences](https://www2.ccs.neu.edu/research/gpc/VonaUtils/vona/terminal/vtansi.htm)
- [xterm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

### Swift Libraries

- [Citadel - Swift SSH](https://github.com/Bouke/Citadel)
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)
- [NMSSH - Objective-C SSH](https://github.com/NMSSH/NMSSH)

---

## 🤝 Contributing

Areas that need work:

1. **SSH Implementation** - Core functionality
2. **Terminal Emulator** - ANSI parsing and rendering
3. **Port Forwarding** - Network tunneling
4. **SFTP Browser** - File operations UI/logic
5. **Testing** - Comprehensive test coverage
6. **Documentation** - User guides and API docs

---

## 📄 License

[Your License Here]

---

## ✨ Credits

Built with love for the visionOS platform, leveraging Apple's incredible spatial computing capabilities and design system.

**Author**: Michael Sitarzewski  
**Date**: February 2026  
**Platform**: visionOS 2.6+

---

## 🎬 Quick Start

1. **Clone the repository**
2. **Open in Xcode 16+**
3. **Build for visionOS Simulator or Device**
4. **Add your first server** in the Connection Manager
5. **Connect and enjoy** a beautiful terminal experience

Note: Full SSH functionality requires implementing the SSH connection layer as described in the Implementation Roadmap above.
