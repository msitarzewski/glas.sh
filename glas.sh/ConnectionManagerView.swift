//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI
import LocalAuthentication
import GlasSecretStore

struct ConnectionManagerView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @State private var serverManager = ServerManager(loadImmediately: false)
    
    @State private var selectedSection: ConnectionSection = .all
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfiguration?
    @State private var viewingServer: ServerConfiguration?
    @State private var searchQuery: String = ""
    @State private var activeTagFilters: [String] = []
    @State private var pendingTrustSession: TerminalSession?
    @State private var pendingTrustChallenge: HostKeyTrustChallenge?
    @State private var pendingConnectPassword: String?
    @State private var connectionFailureMessage: String?
    
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        NavigationSplitView {
            List {
                Section("Connections") {
                    ForEach(sortedSections) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            HStack {
                                Label(section.title, systemImage: section.icon)
                                    .foregroundStyle(section.color)
                                Spacer()
                                if selectedSection == section {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connections")
        } detail: {
            detailView
                .navigationTitle(selectedSection.title)
                .searchable(text: $searchQuery, prompt: "Search servers...")
                .onSubmit(of: .search) {
                    applySearchAsTagFilterIfPossible()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showingAddServer = true
                        } label: {
                            Image(systemName: "plus")
                        }

                        Button {
                            openWindow(id: "settings")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(serverManager: serverManager)
        }
        .sheet(item: $editingServer) { server in
            EditServerView(server: server, serverManager: serverManager)
        }
        .sheet(item: $viewingServer) { server in
            ServerInfoView(
                server: server,
                session: sessionForServer(server)
            )
        }
        .alert(
            "Trust SSH Host Key?",
            isPresented: trustPromptBinding,
            presenting: pendingTrustChallenge
        ) { challenge in
            Button("Trust and Connect") {
                settingsManager.trustHostKey(challenge)
                if let session = pendingTrustSession {
                    serverManager.trustHostKey(challenge, for: session.server.id)
                }
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
    
    private var availableTags: [String] {
        Array(Set(serverManager.servers.flatMap { $0.tags })).sorted()
    }
    
    // MARK: - Detail View
    
    private var detailView: some View {
        VStack(spacing: 0) {
            if !activeTagFilters.isEmpty {
                activeTagFilterBar
            }

            List(filteredServers) { server in
                ServerListRow(
                    server: server,
                    session: sessionForServer(server),
                    onView: {
                        viewingServer = server
                    },
                    onEdit: {
                        editingServer = server
                    },
                    onDelete: {
                        serverManager.deleteServer(server)
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    connectToServer(server)
                }
            }
        }
    }

    private var activeTagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeTagFilters, id: \.self) { tag in
                    HStack(spacing: 6) {
                        Text(tag)
                        Button {
                            activeTagFilters.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                }

                Button("Clear") {
                    activeTagFilters.removeAll()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var filteredServers: [ServerConfiguration] {
        let servers: [ServerConfiguration]
        
        switch selectedSection {
        case .all:
            servers = serverManager.servers
        case .tags:
            servers = serverManager.servers.filter { !$0.tags.isEmpty }
        case .recent:
            servers = serverManager.recentServers
        case .tag(let tag):
            servers = serverManager.servers.filter { $0.tags.contains(tag) }
        }

        var result = servers

        if !activeTagFilters.isEmpty {
            let active = Set(activeTagFilters.map { $0.lowercased() })
            result = result.filter { server in
                !active.isDisjoint(with: Set(server.tags.map { $0.lowercased() }))
            }
        }

        if !searchQuery.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.host.localizedCaseInsensitiveContains(searchQuery) ||
                $0.username.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        return result
    }

    private var sortedSections: [ConnectionSection] {
        ConnectionSection.allCases.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func applySearchAsTagFilterIfPossible() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let matchedTag = availableTags.first(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) else {
            return
        }
        if !activeTagFilters.contains(where: { $0.caseInsensitiveCompare(matchedTag) == .orderedSame }) {
            activeTagFilters.append(matchedTag)
        }
        searchQuery = ""
    }

    private func sessionForServer(_ server: ServerConfiguration) -> TerminalSession? {
        sessionManager.sessions.first(where: { $0.server.id == server.id })
    }
    
    // MARK: - Actions
    
    private func connectToServer(_ server: ServerConfiguration) {
        Task { @MainActor in
            if !(await ensureUserPresenceIfRequired(for: server)) {
                return
            }

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

    private func selectedSSHKey(for server: ServerConfiguration) -> StoredSSHKey? {
        guard let keyID = server.sshKeyID else { return nil }
        return settingsManager.sshKeys.first(where: { $0.id == keyID })
    }

    @MainActor
    private func ensureUserPresenceIfRequired(for server: ServerConfiguration) async -> Bool {
        guard server.authMethod == .sshKey else { return true }
        guard let key = selectedSSHKey(for: server), key.storageKind == .secureEnclave else { return true }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            connectionFailureMessage = "Secure Enclave authentication unavailable: \(error?.localizedDescription ?? "Unknown error")."
            return false
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to use Secure Enclave key '\(key.name)'."
            )
            return ok
        } catch {
            connectionFailureMessage = "Authentication canceled or failed for Secure Enclave key '\(key.name)'."
            return false
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

        Task { @MainActor in
            if let updatedServer = serverManager.server(for: session.server.id) {
                session.server = updatedServer
            }
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

private struct ServerListRow: View {
    let server: ServerConfiguration
    let session: TerminalSession?
    let onView: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var rawConnection: String {
        "\(server.username)@\(server.host):\(server.port)"
    }

    private var shouldTruncateConnection: Bool {
        rawConnection.count > 128
    }

    private var displayConnection: String {
        let raw = rawConnection
        guard raw.count > 128 else { return raw }
        return String(raw.prefix(127)) + "…"
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(server.colorTag.color)
                    .frame(width: 10, height: 10)

                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Text(displayConnection)
                .font(.subheadline.monospaced())
                .lineLimit(shouldTruncateConnection ? 1 : 2)
                .truncationMode(.tail)
                .minimumScaleFactor(shouldTruncateConnection ? 0.82 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: server.authMethod.icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
                .accessibilityLabel(server.authMethod.displayName)

            Group {
                if let lastConnected = server.lastConnected {
                    Text(lastConnected, formatter: relativeDateFormatter)
                } else {
                    Text("Never")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 90, alignment: .leading)

            Menu {
                Button {
                    onView()
                } label: {
                    Label("View", systemImage: "eye")
                }

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .frame(width: 32, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

private struct ServerInfoView: View {
    let server: ServerConfiguration
    let session: TerminalSession?
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    infoRow("Name", server.name)
                    infoRow("Host", "\(server.host):\(server.port)")
                    infoRow("User", server.username)
                    infoRow("Auth", server.authMethod.displayName)
                    if server.authMethod == .sshKey {
                        infoRow("Key Type", selectedSSHKeyBadge)
                        infoRow("Key Storage", selectedSSHKeyStorage)
                        infoRow("Key Migration", selectedSSHKeyMigrationState)
                    }
                }

                Section("Session") {
                    infoRow("State", session?.state.displayName ?? "Disconnected")
                    infoRow("Progress", session?.connectionProgress?.tickerLabel ?? "Idle")
                    infoRow(
                        "Last Connected",
                        server.lastConnected.map {
                            relativeDateFormatter.localizedString(for: $0, relativeTo: Date())
                        } ?? "Never"
                    )
                }

                Section("Advanced") {
                    infoRow("TERM", server.terminalType)
                    infoRow("Compression", server.compression ? "On" : "Off")
                    infoRow("Keep Alive", "\(server.keepAliveInterval)s")
                    infoRow("PTY Requested", server.requestPTY ? "Yes" : "No")
                    infoRow("Forward Agent", server.forwardAgent ? "Yes" : "No")
                }

                if !server.tags.isEmpty {
                    Section("Tags") {
                        Text(server.tags.joined(separator: ", "))
                    }
                }
            }
            .navigationTitle("Server Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var selectedSSHKeyBadge: String {
        guard let key = selectedSSHKey else {
            return "Not selected"
        }
        return key.keyTypeBadge
    }

    private var selectedSSHKeyStorage: String {
        guard let key = selectedSSHKey else { return "Unknown" }
        switch key.storageKind {
        case .legacy:
            return "Legacy Keychain"
        case .imported:
            return "Imported Keychain"
        case .secureEnclave:
            return "Secure Enclave Wrapped"
        }
    }

    private var selectedSSHKeyMigrationState: String {
        guard let key = selectedSSHKey else { return "Unknown" }
        switch key.migrationState {
        case .notNeeded:
            return "Not needed"
        case .pending:
            return "Pending"
        case .migrated:
            return "Migrated"
        case .failed:
            return "Failed"
        }
    }

    private var selectedSSHKey: StoredSSHKey? {
        guard let keyID = server.sshKeyID else { return nil }
        return settingsManager.sshKeys.first(where: { $0.id == keyID })
    }
}

// MARK: - Connection Section

enum ConnectionSection: Hashable, Identifiable, CaseIterable {
    case all
    case tags
    case recent
    case tag(String)
    
    var id: String {
        switch self {
        case .all: return "all"
        case .tags: return "tags"
        case .recent: return "recent"
        case .tag(let tag): return "tag-\(tag)"
        }
    }
    
    var title: String {
        switch self {
        case .all: return "All Servers"
        case .tags: return "Tags"
        case .recent: return "Recent"
        case .tag(let tag): return tag
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "server.rack"
        case .tags: return "tag"
        case .recent: return "clock.fill"
        case .tag: return "tag.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .all: return .blue
        case .tags: return .orange
        case .recent: return .purple
        case .tag: return .orange
        }
    }
    
    static var allCases: [ConnectionSection] {
        [.all, .tags, .recent]
    }

    var isTag: Bool {
        if case .tag = self { return true }
        return false
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
