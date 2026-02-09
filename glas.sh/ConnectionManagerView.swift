//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI

struct ConnectionManagerView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @State private var serverManager = ServerManager(loadImmediately: false)
    
    @State private var selectedSection: ConnectionSection = .favorites
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfiguration?
    @State private var searchQuery: String = ""
    @State private var pendingTrustSession: TerminalSession?
    @State private var pendingTrustChallenge: HostKeyTrustChallenge?
    @State private var pendingConnectPassword: String?
    @State private var connectionFailureMessage: String?
    
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle("Connections")
        .sheet(isPresented: $showingAddServer) {
            AddServerView(serverManager: serverManager)
        }
        .sheet(item: $editingServer) { server in
            EditServerView(server: server, serverManager: serverManager)
        }
        .alert(
            "Trust SSH Host Key?",
            isPresented: trustPromptBinding,
            presenting: pendingTrustChallenge
        ) { challenge in
            Button("Trust and Connect") {
                settingsManager.trustHostKey(challenge)
                retryPendingConnection()
            }
            Button("Cancel", role: .cancel) {
                clearPendingTrustPrompt()
            }
        } message: { challenge in
            Text(
                "\(challenge.summary)\n\nAlgorithm: \(challenge.algorithm)\nFingerprint (SHA-256): \(challenge.fingerprintSHA256)"
            )
        }
        .alert("Connection Failed", isPresented: connectionFailureAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionFailureMessage ?? "Unable to connect.")
        }
        .task {
            serverManager.loadServersIfNeeded()
        }
    }
    
    // MARK: - Sidebar
    
    private var sidebar: some View {
        List {
            Section {
                ForEach(ConnectionSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.icon)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(section.color)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Section("Tags") {
                ForEach(availableTags, id: \.self) { tag in
                    Button {
                        selectedSection = .tag(tag)
                    } label: {
                        Label {
                            Text(tag)
                        } icon: {
                            Image(systemName: "tag")
                                .foregroundStyle(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Connections")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()

                HStack {
                    Button {
                        openWindow(id: "settings")
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                            .font(.headline)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Label("Add Server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    private var availableTags: [String] {
        Array(Set(serverManager.servers.flatMap { $0.tags })).sorted()
    }
    
    // MARK: - Detail View
    
    private var detailView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search servers...", text: $searchQuery)
                    .textFieldStyle(.plain)
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            .padding()
            
            // Server grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 320, maximum: 400), spacing: 20)
                ], spacing: 20) {
                    ForEach(filteredServers) { server in
                        ServerCard(
                            server: server,
                            session: sessionForServer(server),
                            onConnect: {
                                connectToServer(server)
                            },
                            onEdit: {
                                editingServer = server
                            },
                            onToggleFavorite: {
                                serverManager.toggleFavorite(server)
                            },
                            onDelete: {
                                serverManager.deleteServer(server)
                            }
                        )
                    }
                }
                .padding()
            }
        }
        .background(Color.clear)
    }
    
    private var filteredServers: [ServerConfiguration] {
        let servers: [ServerConfiguration]
        
        switch selectedSection {
        case .all:
            servers = serverManager.servers
        case .favorites:
            servers = serverManager.favoriteServers
        case .recent:
            servers = serverManager.recentServers
        case .tag(let tag):
            servers = serverManager.servers.filter { $0.tags.contains(tag) }
        }
        
        if searchQuery.isEmpty {
            return servers
        } else {
            return servers.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.host.localizedCaseInsensitiveContains(searchQuery) ||
                $0.username.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    private func sessionForServer(_ server: ServerConfiguration) -> TerminalSession? {
        sessionManager.sessions.first(where: { $0.server.id == server.id })
    }
    
    // MARK: - Actions
    
    private func connectToServer(_ server: ServerConfiguration) {
        Task {
            // Get password from keychain or prompt
            let password: String?
            if server.authMethod == .password {
                do {
                    password = try KeychainManager.retrievePassword(for: server)
                } catch {
                    connectionFailureMessage =
                        "No saved password found for \(server.username)@\(server.host):\(server.port).\n\nOpen Edit Server and save the password in Keychain, then try again."
                    return
                }
            } else {
                password = nil
            }
            
            let session = await sessionManager.createSession(for: server, password: password)
            if let challenge = session.pendingHostKeyChallenge,
               settingsManager.hostKeyVerificationMode == HostKeyVerificationMode.ask.rawValue {
                pendingTrustSession = session
                pendingTrustChallenge = challenge
                pendingConnectPassword = password
                return
            }

            if session.state == .connected {
                openWindow(id: "terminal", value: session.id)
                dismissWindow(id: "main")
                return
            }

            if case .error(let message) = session.state {
                if let diagnostics = session.lastConnectionDiagnostics, !diagnostics.isEmpty {
                    connectionFailureMessage = "\(message)\n\n\(diagnostics)"
                } else {
                    connectionFailureMessage = message
                }
                sessionManager.closeSession(session)
            }
        }
    }

    private var trustPromptBinding: Binding<Bool> {
        Binding(
            get: { pendingTrustChallenge != nil },
            set: { isPresented in
                if !isPresented {
                    clearPendingTrustPrompt()
                }
            }
        )
    }

    private var connectionFailureAlertBinding: Binding<Bool> {
        Binding(
            get: { connectionFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    connectionFailureMessage = nil
                }
            }
        )
    }

    private func retryPendingConnection() {
        guard let session = pendingTrustSession else { return }
        let password = pendingConnectPassword

        Task {
            session.pendingHostKeyChallenge = nil
            await session.connect(password: password)
            if session.state == .connected {
                openWindow(id: "terminal", value: session.id)
                dismissWindow(id: "main")
                clearPendingTrustPrompt()
            } else if session.pendingHostKeyChallenge == nil {
                clearPendingTrustPrompt()
            }
        }
    }

    private func clearPendingTrustPrompt() {
        pendingTrustSession = nil
        pendingTrustChallenge = nil
        pendingConnectPassword = nil
    }
}

// MARK: - Connection Section

enum ConnectionSection: Hashable, Identifiable, CaseIterable {
    case all
    case favorites
    case recent
    case tag(String)
    
    var id: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .recent: return "recent"
        case .tag(let tag): return "tag-\(tag)"
        }
    }
    
    var title: String {
        switch self {
        case .all: return "All Servers"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .tag(let tag): return tag
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "server.rack"
        case .favorites: return "heart.fill"
        case .recent: return "clock.fill"
        case .tag: return "tag.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .all: return .blue
        case .favorites: return .pink
        case .recent: return .purple
        case .tag: return .orange
        }
    }
    
    static var allCases: [ConnectionSection] {
        [.all, .favorites, .recent]
    }
}

// MARK: - Server Card

struct ServerCard: View {
    let server: ServerConfiguration
    let session: TerminalSession?
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovering = false
    @State private var pulsePhase = false

    private var isConnecting: Bool {
        guard let state = session?.state else { return false }
        switch state {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(server.colorTag.color)
                    .frame(width: 12, height: 12)
                
                Text(server.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Spacer()
                
                if server.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                }
            }
            .padding()
            
            Divider()
            
            // Body
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(server.username)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text(server.host)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(":\(server.port)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: server.authMethod.icon)
                        .foregroundStyle(.secondary)
                    Text(server.authMethod.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isConnecting, let progress = session?.connectionProgress {
                    ConnectionTicker(stage: progress, port: server.port)
                }
                
                if let lastConnected = server.lastConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(.tertiary)
                        Text("Last: \(lastConnected, formatter: relativeDateFormatter)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                if !server.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(server.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: .capsule)
                            }
                        }
                    }
                }
            }
            .padding()
            
            Divider()
            
            // Actions
            HStack(spacing: 8) {
                Button(action: onConnect) {
                    HStack {
                        Image(systemName: isConnecting ? "arrow.triangle.2.circlepath.circle.fill" : "bolt.fill")
                        Text(isConnecting ? "Connecting…" : "Connect")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isConnecting)
                
                Menu {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    
                    Button(action: onToggleFavorite) {
                        Label(
                            server.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: server.isFavorite ? "heart.slash" : "heart"
                        )
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isConnecting ? server.colorTag.color.opacity(0.75) : server.colorTag.color.opacity(0.3),
                    lineWidth: isConnecting ? 2.6 : 2
                )
        }
        .hoverEffect(.lift)
        .scaleEffect(isConnecting && pulsePhase ? 1.012 : 1.0)
        .shadow(
            color: isConnecting ? server.colorTag.color.opacity(0.25) : .black.opacity(0.1),
            radius: isConnecting ? 14 : 10,
            x: 0,
            y: isConnecting ? 8 : 5
        )
        .onAppear {
            updatePulseAnimation()
        }
        .onChange(of: isConnecting) { _, _ in
            updatePulseAnimation()
        }
    }

    private func updatePulseAnimation() {
        if isConnecting {
            pulsePhase = false
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        } else {
            pulsePhase = false
        }
    }
}

private struct ConnectionTicker: View {
    let stage: ConnectionProgressStage
    let port: Int

    private var labels: [String] {
        ["DNS", "Connecting:\(port)", "Negotiating", "Auth", "Shell"]
    }

    var body: some View {
        let active = stage.flowIndex
        VStack(alignment: .leading, spacing: 6) {
            Text(stage.tickerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(index <= active ? .primary : .tertiary)
                    if index < labels.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(index < active ? .primary : .tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

#Preview {
    ConnectionManagerView()
        .environment(SessionManager())
        .environment(SettingsManager())
}
