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
    
    @Environment(\.openWindow) private var openWindow
    
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
    
    // MARK: - Actions
    
    private func connectToServer(_ server: ServerConfiguration) {
        Task {
            // Get password from keychain or prompt
            let password: String?
            if server.authMethod == .password {
                do {
                    password = try KeychainManager.retrievePassword(for: server)
                } catch {
                    // TODO: Show password prompt
                    password = nil
                    return
                }
            } else {
                password = nil
            }
            
            let session = await sessionManager.createSession(for: server, password: password)
            openWindow(id: "terminal", value: session.id)
        }
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
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovering = false
    
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
                        Image(systemName: "bolt.fill")
                        Text("Connect")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
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
                .strokeBorder(server.colorTag.color.opacity(0.3), lineWidth: 2)
        }
        .hoverEffect(.lift)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
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
