//
//  MIGRATION_GUIDE.md
//  From ContentView.swift to Complete Architecture
//

# Migration Guide: ContentView.swift → New Architecture

This guide explains the transformation from your original single-file app to the complete visionOS-first architecture.

---

## Overview of Changes

### What Was Removed

1. **`ContentView.swift`** - The monolithic single view
2. **iOS/iPadOS patterns** - NavigationSplitView without ornaments
3. **Swipe gestures** - Not natural on visionOS
4. **@AppStorage for passwords** - Insecure
5. **Single window model** - Limited functionality

### What Was Added

1. **Multi-window architecture** - Proper visionOS app structure
2. **Liquid Glass everywhere** - Platform-appropriate design
3. **Spatial ornaments** - visionOS-specific UI
4. **Secure Keychain storage** - Production-ready security
5. **Advanced features** - Port forwarding, HTML preview
6. **Complete settings system** - Professional customization
7. **Snippet library** - Developer productivity
8. **Theme system** - Visual customization

---

## Data Migration

### Server Configuration

**Old:**
```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    let authMethod: AuthenticationMethod
    var password: String?  // ❌ Stored in AppStorage - insecure!
    let sshKeyPath: String?
    var isFavorite: Bool
    let dateAdded: Date
    var lastConnected: Date?
}
```

**New:**
```swift
struct ServerConfiguration: Identifiable, Codable {
    // Same basic fields, plus:
    var colorTag: ServerColorTag  // Visual identity
    var tags: [String]  // Organization
    
    // Advanced SSH options
    var compression: Bool
    var keepAliveInterval: Int
    var serverAliveCountMax: Int
    var forwardAgent: Bool
    var requestPTY: Bool
    var terminalType: String
    var environmentVariables: [String: String]
    
    // No password field! Use Keychain instead
}
```

**Migration Function:**
```swift
func migrateOldServers() {
    // Read old data
    @AppStorage("servers") var oldServersData: Data = Data()
    
    guard let oldServers = try? JSONDecoder().decode([OldServer].self, 
                                                      from: oldServersData) else {
        return
    }
    
    let serverManager = ServerManager()
    
    for oldServer in oldServers {
        // Create new server config
        let newServer = ServerConfiguration(
            id: oldServer.id,
            name: oldServer.name,
            host: oldServer.host,
            port: oldServer.port,
            username: oldServer.username,
            authMethod: oldServer.authMethod,
            sshKeyPath: oldServer.sshKeyPath,
            isFavorite: oldServer.isFavorite,
            colorTag: .blue,  // Default color
            tags: []  // No tags yet
        )
        
        // Save to new system
        serverManager.addServer(newServer)
        
        // Migrate password to Keychain if present
        if let password = oldServer.password, !password.isEmpty {
            try? KeychainManager.savePassword(password, for: newServer)
        }
    }
    
    // Clear old data
    oldServersData = Data()
}
```

---

## View Architecture Changes

### Old App Structure

```
WindowGroup
└── ContentView (everything in one file!)
    ├── NavigationSplitView
    │   ├── Sidebar
    │   └── Detail
    └── Various sheets and forms
```

### New App Structure

```
App
├── WindowGroup(id: "terminal", for: UUID.self)
│   └── TerminalWindowView (one per session)
│       ├── Terminal output with glass effect
│       ├── Ornament: Toolbar (top)
│       ├── Ornament: Sidebar (left)
│       └── Ornament: Info Panel (right)
│
├── Window(id: "connections")
│   └── ConnectionManagerView
│       └── NavigationSplitView
│           ├── Sidebar (sections)
│           └── Server grid
│
├── WindowGroup(id: "html-preview", for: HTMLPreviewContext.self)
│   └── HTMLPreviewWindow
│       └── WebView with dev tools
│
├── Window(id: "port-forwarding")
│   └── PortForwardingManagerView
│
└── Settings
    └── SettingsView (4 tabs)
```

---

## UI Component Mapping

### Old → New Component Mapping

| Old Component | New Component | Changes |
|--------------|---------------|---------|
| `SidebarView` | ConnectionManagerView sidebar | Now uses proper sections |
| `AllServersView` | ConnectionManagerView detail | Grid layout with search |
| `ServerRowView` | ServerCard | Card-based, no swipe gestures |
| `FavoriteServerCard` | ServerCard (same) | Used in both contexts |
| `AddServerWizardView` | AddServerView | Multi-step with progress |
| `EditServerView` | EditServerView | More comprehensive options |
| `EmptyStateView` | ContentUnavailableView | System component |
| `SettingsView` | SettingsView | Full settings system |

---

## Feature Additions

### 1. Terminal Session Window

**What it does:**
- Displays live terminal output
- Handles command input
- Shows connection status
- Provides spatial ornaments for tools

**Key files:**
- `TerminalWindowView.swift`
- `Models.swift` (TerminalSession class)

**Usage:**
```swift
// Open new terminal window
openWindow(id: "terminal", value: session.id)
```

### 2. Port Forwarding

**What it does:**
- Create SSH tunnels (local, remote, dynamic)
- Manage multiple forwards per session
- Toggle active/inactive state

**Key files:**
- `PortForwardingManagerView.swift`
- `Models.swift` (PortForward struct)
- `Managers.swift` (PortForwardManager)

**Usage:**
```swift
// Add a local port forward
let forward = PortForward(
    type: .local,
    localPort: 8080,
    remoteHost: "localhost",
    remotePort: 80
)
portForwardManager.addForward(forward, to: sessionID)
```

### 3. HTML Preview

**What it does:**
- Live web preview with auto-reload
- Developer tools (view source, inspect, screenshot, PDF)
- Perfect for web development workflows

**Key files:**
- `HTMLPreviewWindow.swift`

**Usage:**
```swift
let context = HTMLPreviewContext(
    sessionID: session.id,
    url: "http://localhost:3000",
    autoReload: true,
    reloadInterval: 2.0
)
openWindow(id: "html-preview", value: context)
```

### 4. Command Snippets

**What it does:**
- Save frequently used commands
- Quick execution from sidebar
- Usage tracking and statistics

**Key files:**
- `Models.swift` (CommandSnippet)
- `Managers.swift` (SettingsManager)
- `SettingsView.swift` (Snippets tab)

**Usage:**
```swift
let snippet = CommandSnippet(
    name: "Update System",
    command: "sudo apt update && sudo apt upgrade -y",
    description: "Full system update",
    tags: ["system", "maintenance"]
)
settingsManager.addSnippet(snippet)
```

### 5. Theme System

**What it does:**
- Complete terminal color customization
- ANSI color palette
- Font and appearance settings

**Key files:**
- `Models.swift` (TerminalTheme)
- `Managers.swift` (SettingsManager)
- `SettingsView.swift` (Appearance tab)

**Usage:**
```swift
var theme = TerminalTheme.default
theme.background = CodableColor(color: .black.opacity(0.5))
theme.foreground = CodableColor(color: .white)
settingsManager.saveTheme(theme)
```

---

## State Management Changes

### Old Pattern
```swift
// Everything in @State at ContentView level
@State private var servers: [Server] = []
@State private var showingAddServerForm = false
@State private var editingServer: Server?
```

### New Pattern
```swift
// Centralized managers with @ObservableObject
@StateObject private var sessionManager = SessionManager()
@StateObject private var settingsManager = SettingsManager()

// Injected via environment
ContentView()
    .environmentObject(sessionManager)
    .environmentObject(settingsManager)
```

**Benefits:**
- Shared state across windows
- Persistence handled automatically
- Clear separation of concerns
- Testable business logic

---

## Security Improvements

### Password Storage

**Old (Insecure):**
```swift
@AppStorage("servers") private var serversData: Data = Data()
// Servers stored with plain-text passwords in UserDefaults
```

**New (Secure):**
```swift
// Configuration stored without passwords
@AppStorage("servers") private var serversData: Data = Data()

// Passwords in Keychain
try KeychainManager.savePassword(password, for: server)
let password = try KeychainManager.retrievePassword(for: server)
```

### Migration Script
```swift
func secureExistingPasswords() {
    // Load old servers with passwords
    guard let servers = loadOldServers() else { return }
    
    for server in servers {
        // Move password to Keychain
        if let password = server.password, !password.isEmpty {
            try? KeychainManager.savePassword(password, for: server)
        }
        
        // Save config without password
        var secureServer = server
        secureServer.password = nil
        saveServer(secureServer)
    }
}
```

---

## Glass Design Integration

### Old Approach
```swift
// Basic materials
.background(.ultraThinMaterial)
```

### New Approach
```swift
// Liquid Glass everywhere
.glassEffect(.regular, in: .rect(cornerRadius: 24))

// Grouped glass effects
GlassEffectContainer(spacing: 8) {
    HStack {
        Button("Action 1") { }
            .buttonStyle(.glass)
            .glassEffectID("btn1", in: namespace)
        
        Button("Action 2") { }
            .buttonStyle(.glass)
            .glassEffectID("btn2", in: namespace)
    }
}

// Interactive glass
.glassEffect(.regular.interactive())
```

### Converting Components

**Before:**
```swift
VStack {
    Text("Hello")
}
.padding()
.background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
```

**After:**
```swift
VStack {
    Text("Hello")
}
.padding()
.glassEffect(.regular, in: .rect(cornerRadius: 16))
```

---

## Ornament Usage

### What are Ornaments?

Ornaments are visionOS-specific UI elements that float around the main window, providing contextual controls without obscuring content.

### Adding Ornaments

```swift
WindowView()
    .ornament(attachmentAnchor: .scene(.top)) {
        // Toolbar ornament
        toolbarContent
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
    .ornament(attachmentAnchor: .scene(.leading)) {
        // Left sidebar ornament
        sidebarContent
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
    .ornament(attachmentAnchor: .scene(.trailing)) {
        // Right panel ornament
        infoPanelContent
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
```

### Ornament Best Practices

1. **Keep them contextual** - Only show relevant tools
2. **Make them toggleable** - Users should control visibility
3. **Use glass effects** - Maintain visual consistency
4. **Size appropriately** - Don't overwhelm the main view
5. **Animate transitions** - Smooth show/hide

---

## Window Management

### Opening Windows

```swift
@Environment(\.openWindow) private var openWindow

// Open a specific window
openWindow(id: "connections")

// Open a window with context
openWindow(id: "terminal", value: sessionID)

// Open HTML preview with context
let context = HTMLPreviewContext(sessionID: sessionID, url: "http://localhost:8080")
openWindow(id: "html-preview", value: context)
```

### Window Coordination

```swift
// In glas_shApp.swift
@StateObject private var sessionManager = SessionManager()

var body: some Scene {
    // Terminal windows - multiple instances
    WindowGroup(id: "terminal", for: UUID.self) { $sessionID in
        if let sessionID = sessionID,
           let session = sessionManager.session(for: sessionID) {
            TerminalWindowView(session: session)
                .environmentObject(sessionManager)
        }
    }
    
    // Connection manager - single instance
    Window("Connections", id: "connections") {
        ConnectionManagerView()
            .environmentObject(sessionManager)
    }
}
```

---

## Testing Your Migration

### Checklist

- [ ] Old server data migrated to new format
- [ ] Passwords moved from AppStorage to Keychain
- [ ] Can open multiple terminal windows
- [ ] Connection manager accessible via ⌘0
- [ ] Glass effects rendering correctly
- [ ] Ornaments showing/hiding properly
- [ ] Settings persisting correctly
- [ ] Favorites and recents working
- [ ] Search functionality operational
- [ ] Port forwarding UI functional
- [ ] HTML preview windows opening
- [ ] All windows can be positioned in 3D space

### Migration Verification

```swift
func verifyMigration() {
    // Check server count matches
    let oldCount = UserDefaults.standard.data(forKey: "old_servers")?.count ?? 0
    let newCount = serverManager.servers.count
    assert(oldCount == newCount, "Server count mismatch")
    
    // Check passwords in Keychain
    for server in serverManager.servers {
        if server.authMethod == .password {
            do {
                let _ = try KeychainManager.retrievePassword(for: server)
                print("✅ Password migrated for \(server.name)")
            } catch {
                print("❌ Password missing for \(server.name)")
            }
        }
    }
    
    // Check settings migrated
    assert(settingsManager.currentTheme != nil, "Theme not loaded")
    
    print("✅ Migration verified!")
}
```

---

## Common Issues & Solutions

### Issue: "Sessions not persisting"
**Solution:** Ensure SessionManager is a StateObject at the App level and injected via environmentObject.

### Issue: "Passwords not found"
**Solution:** Check Keychain entitlements are enabled and KeychainManager is using correct service name.

### Issue: "Glass effects not showing"
**Solution:** Ensure you're running on visionOS, not iOS simulator. Glass effects require actual visionOS runtime.

### Issue: "Ornaments not appearing"
**Solution:** Check ornament visibility state variables and ensure glass effects are applied to ornament content.

### Issue: "Multiple windows not opening"
**Solution:** Verify WindowGroup has correct `for:` parameter type and you're passing correct value to openWindow.

---

## Next Steps

1. **Implement SSH connection** - Use Citadel or SwiftNIO SSH
2. **Add terminal emulation** - Parse ANSI codes, handle PTY
3. **Complete port forwarding** - Implement actual tunnel creation
4. **Build SFTP browser** - File tree navigation and operations
5. **Add testing** - Unit tests for all managers and models
6. **Polish animations** - Smooth transitions everywhere
7. **Performance optimization** - Profile and optimize rendering

---

## Resources

- [visionOS Developer Docs](https://developer.apple.com/visionos/)
- [Ornament Documentation](https://developer.apple.com/documentation/swiftui/view/ornament(visibility:attachmentanchor:contentshape:content:))
- [Glass Effect Guide](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Multi-window Apps](https://developer.apple.com/documentation/swiftui/scenes)

---

## Questions?

Refer to:
- `README.md` - Complete project overview
- Source code comments - Detailed implementation notes
- Apple documentation - Platform-specific guidance

Happy coding! 🎉
