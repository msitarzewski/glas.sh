//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI
import LocalAuthentication
import GlasSecretStore
import os

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
    @State private var quickConnectPasswordPrompt: ServerConfiguration?
    @State private var quickConnectPassword: String = ""
    @State private var quickConnectUsername: String = ""
    @State private var quickConnectPort: String = "22"
    @State private var tailscaleClient = TailscaleClient()
    @State private var tailscaleUsernamePromptDevice: TailscaleDevice?
    
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
                    if let config = quickConnectConfig {
                        quickConnectPasswordPrompt = config
                    } else {
                        applySearchAsTagFilterIfPossible()
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button("Save Current Layout") {
                                saveCurrentLayout()
                            }
                            .disabled(sessionManager.sessions.isEmpty)

                            if !settingsManager.layoutPresets.isEmpty {
                                Divider()

                                ForEach(settingsManager.layoutPresets) { preset in
                                    Button(preset.name) {
                                        openLayout(preset)
                                    }
                                }

                                Divider()

                                Menu("Delete Layout") {
                                    ForEach(settingsManager.layoutPresets) { preset in
                                        Button(preset.name, role: .destructive) {
                                            settingsManager.deleteLayoutPreset(preset)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "rectangle.3.group")
                        }
                        .accessibilityLabel("Layouts")

                        Button {
                            showingAddServer = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add server")

                        Button {
                            openWindow(id: "settings")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
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
        .alert("Enter Password", isPresented: quickConnectPasswordPromptBinding) {
            SecureField("Password", text: $quickConnectPassword)
            Button("Connect") {
                if let config = quickConnectPasswordPrompt {
                    let password = quickConnectPassword
                    quickConnectPassword = ""
                    Task { @MainActor in
                        let session = await sessionManager.createSession(for: config, password: password)
                        if session.state == .connected {
                            openWindow(id: "terminal", value: session.id)
                            dismissWindow(id: "main")
                        } else if case .error(let message) = session.state {
                            connectionFailureMessage = message
                            sessionManager.closeSession(session)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                quickConnectPassword = ""
            }
        } message: {
            if let config = quickConnectPasswordPrompt {
                Text("Enter password for \(config.username)@\(config.host):\(config.port)")
            }
        }
        .task {
            serverManager.loadServersIfNeeded()
        }
    }
    
    private var availableTags: [String] {
        Array(Set(serverManager.servers.flatMap { $0.tags })).sorted()
    }

    private var quickConnectConfig: ServerConfiguration? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.contains("@") else { return nil }
        let parts = query.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let username = String(parts[0])
        let hostPart = String(parts[1])

        let host: String
        let port: Int
        if hostPart.contains(":"), let colonIndex = hostPart.lastIndex(of: ":") {
            host = String(hostPart[hostPart.startIndex..<colonIndex])
            port = Int(hostPart[hostPart.index(after: colonIndex)...]) ?? 22
        } else {
            host = hostPart
            port = 22
        }

        guard !username.isEmpty, !host.isEmpty else { return nil }

        return ServerConfiguration(
            name: "\(username)@\(host)",
            host: host,
            port: port,
            username: username,
            authMethod: .password
        )
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if selectedSection == .tailscale {
            tailscaleDetailView
        } else {
            serverListDetailView
        }
    }

    private var serverListDetailView: some View {
        VStack(spacing: 0) {
            if !activeTagFilters.isEmpty {
                activeTagFilterBar
            }

            List {
                if let config = quickConnectConfig {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quick Connect")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(config.username)@\(config.host):\(config.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            quickConnectPasswordPrompt = config
                        }
                    }
                }

                ForEach(filteredServers) { server in
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
                        },
                        onToggleFavorite: {
                            serverManager.toggleFavorite(server)
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        connectToServer(server)
                    }
                }
            }
        }
    }

    private var tailscaleDetailView: some View {
        List {
            if tailscaleClient.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading Tailscale devices...")
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error = tailscaleClient.errorMessage {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            loadTailscaleDevices()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else if tailscaleClient.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "network")
                } description: {
                    Text("No Tailscale devices found. Configure your API key or OAuth credentials in Settings.")
                }
            } else {
                Section("Devices (\(tailscaleClient.devices.count))") {
                    ForEach(tailscaleClient.devices) { device in
                        TailscaleDeviceRow(device: device)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                tailscaleUsernamePromptDevice = device
                            }
                            .contextMenu {
                                Button {
                                    importTailscaleDevice(device)
                                } label: {
                                    Label("Import as Server", systemImage: "square.and.arrow.down")
                                }
                            }
                    }
                }
            }
        }
        .task {
            // Use .task instead of .onAppear — async context lets the load complete
            await tailscaleClient.loadDevices(
                tailnet: settingsManager.tailscaleTailnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "-"
                    : settingsManager.tailscaleTailnet.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .alert("SSH Login", isPresented: tailscaleUsernamePromptBinding) {
            TextField("Username", text: $quickConnectUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $quickConnectPassword)
            TextField("Port", text: $quickConnectPort)
                .keyboardType(.numberPad)
            Button("Connect") {
                if let device = tailscaleUsernamePromptDevice {
                    let port = Int(quickConnectPort) ?? 22
                    let config = ServerConfiguration(
                        name: device.hostname,
                        host: device.sshAddress,
                        port: port,
                        username: quickConnectUsername
                    )
                    let password = quickConnectPassword
                    quickConnectUsername = ""
                    quickConnectPassword = ""
                    quickConnectPort = "22"
                    tailscaleUsernamePromptDevice = nil
                    Task { @MainActor in
                        let session = await sessionManager.createSession(for: config, password: password)
                        if session.state == .connected {
                            openWindow(id: "terminal", value: session.id)
                            dismissWindow(id: "main")
                        } else if case .error(let message) = session.state {
                            connectionFailureMessage = message
                            sessionManager.closeSession(session)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                quickConnectUsername = ""
                quickConnectPassword = ""
                quickConnectPort = "22"
                tailscaleUsernamePromptDevice = nil
            }
        } message: {
            if let device = tailscaleUsernamePromptDevice {
                Text("Enter SSH credentials for \(device.hostname) (\(device.sshAddress))")
            }
        }
    }

    private var tailscaleUsernamePromptBinding: Binding<Bool> {
        Binding(
            get: { tailscaleUsernamePromptDevice != nil },
            set: { isPresented in
                if !isPresented {
                    tailscaleUsernamePromptDevice = nil
                    quickConnectUsername = ""
                    quickConnectPassword = ""
                    quickConnectPort = "22"
                }
            }
        )
    }

    private func loadTailscaleDevices() {
        let tailnet = settingsManager.tailscaleTailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        if tailnet.isEmpty {
            // Use "-" wildcard — works for any authenticated user
            Logger.tailscale.info("No tailnet configured, using '-' wildcard")
        }
        let effectiveTailnet = tailnet.isEmpty ? "-" : tailnet
        Logger.tailscale.info("Loading Tailscale devices for tailnet: '\(effectiveTailnet)'")
        Task {
            await tailscaleClient.loadDevices(tailnet: effectiveTailnet)
        }
    }

    private func importTailscaleDevice(_ device: TailscaleDevice) {
        let config = ServerConfiguration(
            name: device.hostname,
            host: device.sshAddress,
            port: 22,
            username: "",
            tags: ["tailscale"]
        )
        serverManager.addServer(config)
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                        .accessibilityLabel("Remove \(tag) filter")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Tag filter: \(tag)")
                    .accessibilityAddTraits(.isButton)
                }

                Button("Clear") {
                    activeTagFilters.removeAll()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Clear all tag filters")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var filteredServers: [ServerConfiguration] {
        let servers: [ServerConfiguration]
        
        switch selectedSection {
        case .favorites:
            servers = serverManager.favoriteServers
        case .all:
            servers = serverManager.servers
        case .tags:
            servers = serverManager.servers.filter { !$0.tags.isEmpty }
        case .recent:
            servers = serverManager.recentServers
        case .tailscale:
            servers = []
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

    private var quickConnectPasswordPromptBinding: Binding<Bool> {
        Binding(
            get: { quickConnectPasswordPrompt != nil },
            set: { isPresented in
                if !isPresented {
                    quickConnectPasswordPrompt = nil
                    quickConnectPassword = ""
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

    // MARK: - Layout Presets

    private func saveCurrentLayout() {
        let serverIDs = sessionManager.sessions.map { $0.server.id }
        guard !serverIDs.isEmpty else { return }
        let name = "Layout (\(serverIDs.count) servers)"
        let preset = LayoutPreset(name: name, serverIDs: serverIDs)
        settingsManager.addLayoutPreset(preset)
    }

    private func openLayout(_ preset: LayoutPreset) {
        settingsManager.updateLayoutPresetLastUsed(preset.id)
        Task { @MainActor in
            for serverID in preset.serverIDs {
                guard let server = serverManager.server(for: serverID) else { continue }
                let session = await sessionManager.createSession(for: server)
                if session.state == .connected {
                    openWindow(id: "terminal", value: session.id)
                }
            }
        }
    }
}

private struct ServerListRow: View {
    let server: ServerConfiguration
    let session: TerminalSession?
    let onView: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void

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

                if server.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .accessibilityLabel("Favorite")
                }
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
            .accessibilityLabel("Actions for \(server.name)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name), \(server.username) at \(server.host), \(server.authMethod.displayName)")
        .accessibilityHint("Double tap to connect")
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                Label(
                    server.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: server.isFavorite ? "heart.slash" : "heart"
                )
            }

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
        }
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
                    infoRow("Compression", "Coming Soon")
                    infoRow("Keep Alive", "\(server.keepAliveInterval)s")
                    infoRow("PTY Requested", server.requestPTY ? "Yes" : "No")
                    infoRow("Forward Agent", "Coming Soon")
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
    case favorites
    case all
    case tags
    case recent
    case tailscale
    case tag(String)

    var id: String {
        switch self {
        case .favorites: return "favorites"
        case .all: return "all"
        case .tags: return "tags"
        case .recent: return "recent"
        case .tailscale: return "tailscale"
        case .tag(let tag): return "tag-\(tag)"
        }
    }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .all: return "All Servers"
        case .tags: return "Tags"
        case .recent: return "Recent"
        case .tailscale: return "Tailscale"
        case .tag(let tag): return tag
        }
    }

    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .all: return "server.rack"
        case .tags: return "tag"
        case .recent: return "clock.fill"
        case .tailscale: return "network"
        case .tag: return "tag.fill"
        }
    }

    var color: Color {
        switch self {
        case .favorites: return .pink
        case .all: return .blue
        case .tags: return .orange
        case .recent: return .purple
        case .tailscale: return .cyan
        case .tag: return .orange
        }
    }

    static var allCases: [ConnectionSection] {
        [.favorites, .all, .tags, .recent, .tailscale]
    }

}

// MARK: - Tailscale Device Row

private struct TailscaleDeviceRow: View {
    let device: TailscaleDevice

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)

                Text(device.hostname)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Text(device.sshAddress)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(device.os)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)

            Text(device.user)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.hostname), \(device.os), \(device.user)")
        .accessibilityHint("Double tap to connect via SSH")
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
