//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI
import GlasSecretStore
import os

struct ConnectionManagerView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager

    private var serverManager: ServerManager { sessionManager.serverManager }
    
    @State private var selectedSection: ConnectionSection = .all
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfiguration?
    @State private var viewingServer: ServerConfiguration?
    @State private var searchQuery: String = ""
    @State private var activeTagFilters: [String] = []
    @State private var pendingTrustSession: TerminalSession?
    @State private var pendingTrustChallenge: HostKeyTrustChallenge?
    @State private var connectionFailureMessage: String?
    @State private var pendingLegacyAlgorithmServer: ServerConfiguration?
    @State private var quickConnectPasswordPrompt: ServerConfiguration?
    @State private var quickConnectPassword: String = ""
    @State private var quickConnectUsername: String = ""
    @State private var quickConnectPort: String = "22"
    @State private var tailscaleClient = TailscaleClient()
    @State private var tailscaleUsernamePromptDevice: TailscaleDevice?
    @State private var serverPendingDeletion: ServerConfiguration?
    @State private var workgroupEditorContext: WorkgroupEditorContext?
    #if os(macOS)
    @State private var macSelectedServerID: UUID?
    @State private var macShowsTailscale = false
    #endif
    
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    
    var body: some View {
        NavigationSplitView {
            #if os(macOS)
            macConnectionSidebar
            #else
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
            #endif
        } detail: {
            #if os(macOS)
            macConnectionDetail
                .navigationTitle(macSelectedServer?.name ?? selectedSection.title)
                .searchable(text: $searchQuery, prompt: "Search connections...")
                .onSubmit(of: .search) {
                    handleSearchSubmission()
                }
            #else
            detailView
                .navigationTitle(selectedSection.title)
                .searchable(text: $searchQuery, prompt: "Search servers...")
                .onSubmit(of: .search) {
                    handleSearchSubmission()
                }
                .toolbar {
                    connectionToolbar
                }
            #endif
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
        .sheet(item: $workgroupEditorContext) { context in
            WorkgroupEditorView(
                context: context,
                servers: serverManager.servers
            ) { preset in
                settingsManager.upsertLayoutPreset(preset)
            }
        }
        .alert(
            trustPromptTitle,
            isPresented: trustPromptBinding,
            presenting: pendingTrustChallenge
        ) { challenge in
            Button(trustPromptConfirmTitle, role: challenge.reason == .changed ? .destructive : nil) {
                guard let session = pendingTrustSession else {
                    clearPendingTrustPrompt()
                    return
                }
                guard interactiveHostKeyTrustIsAllowed else {
                    rejectStrictHostKeyChallenge(challenge, for: session)
                    return
                }
                do {
                    try sessionManager.trustHostKey(challenge, for: session)
                    retryPendingConnection()
                } catch {
                    connectionFailureMessage = error.localizedDescription
                    sessionManager.closePendingHostTrustSession(session)
                    clearPendingTrustPrompt()
                }
            }
            Button("Cancel", role: .cancel) {
                closePendingTrustSessionAndClearPrompt()
            }
        } message: { challenge in
            Text(trustPromptMessage(for: challenge))
        }
        .alert("Connection Failed", isPresented: connectionFailureAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionFailureMessage ?? "Unable to connect.")
        }
        .confirmationDialog(
            "Delete Server?",
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: serverPendingDeletion
        ) { server in
            Button("Delete \(server.name)", role: .destructive) {
                do {
                    try serverManager.deleteServer(server)
                    serverPendingDeletion = nil
                } catch {
                    connectionFailureMessage = "The server was not deleted because its saved credential could not be removed: \(error.localizedDescription)"
                    serverPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                serverPendingDeletion = nil
            }
        } message: { server in
            Text("This removes '\(server.name)' and its terminal-specific saved password. SSH keys shared by other servers are kept.")
        }
        .alert(
            "Use Legacy SSH Algorithms?",
            isPresented: legacyAlgorithmPromptBinding,
            presenting: pendingLegacyAlgorithmServer
        ) { server in
            Button("Connect with Legacy Algorithms", role: .destructive) {
                pendingLegacyAlgorithmServer = nil
                connectToServer(server, legacyAlgorithmsConfirmed: true)
            }
            Button("Cancel", role: .cancel) {
                pendingLegacyAlgorithmServer = nil
            }
        } message: { server in
            Text("\(server.name) permits obsolete SSH algorithms. They provide weaker protection and should only be used for a server you control when upgrading it is not currently possible.")
        }
        .alert("Enter Password", isPresented: quickConnectPasswordPromptBinding) {
            SecureField("Password", text: $quickConnectPassword)
            Button("Connect") {
                if let config = quickConnectPasswordPrompt {
                    let password = quickConnectPassword
                    quickConnectPassword = ""
                    Task { @MainActor in
                        do {
                            let launch = try await sessionManager.createTransientAuthorizedSession(
                                for: config,
                                settingsManager: settingsManager,
                                password: password
                            )
                            if launch.session.state == .connected {
                                presentTerminalWindow(for: launch.session)
                            } else if let challenge = launch.session.pendingHostKeyChallenge {
                                stageHostKeyChallenge(
                                    challenge,
                                    for: launch.session
                                )
                            } else if case .error(let message) = launch.session.state {
                                connectionFailureMessage = message
                                sessionManager.closeSession(launch.session)
                            }
                        } catch {
                            connectionFailureMessage = error.localizedDescription
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

    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                layoutMenuItems
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .accessibilityLabel("Workgroups")

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

    @ViewBuilder
    private var layoutMenuItems: some View {
        Button("New Workgroup…") {
            workgroupEditorContext = .new()
        }

        Button("Save Current SSH Sessions…") {
            editCurrentSessionsAsWorkgroup()
        }
        .disabled(currentSavedSessionIntents.isEmpty)

        if !settingsManager.layoutPresets.isEmpty {
            Divider()

            ForEach(settingsManager.layoutPresets) { preset in
                Menu {
                    Button("Open", systemImage: "rectangle.stack") {
                        openWorkgroup(preset)
                    }
                    Button("Edit…", systemImage: "pencil") {
                        workgroupEditorContext = .edit(preset)
                    }
                    Button("Duplicate…", systemImage: "plus.square.on.square") {
                        workgroupEditorContext = .duplicate(preset)
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        settingsManager.deleteLayoutPreset(preset)
                    }
                } label: {
                    Label {
                        Text(preset.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(preset.colorTag.color)
                    }
                }
            }
        }
    }

    #if os(macOS)
    private var macConnectionSidebar: some View {
        List(selection: $macSelectedServerID) {
            if serverManager.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "server.rack")
                } description: {
                    Text("Add a saved host to begin.")
                }
                .listRowBackground(Color.clear)
            } else if macFilteredServers(serverManager.servers).isEmpty,
                      quickConnectConfig == nil {
                ContentUnavailableView.search(text: searchQuery)
                    .listRowBackground(Color.clear)
            }

            if let config = quickConnectConfig {
                Section("Quick Connect") {
                    Button {
                        quickConnectPasswordPrompt = config
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect")
                                Text("\(config.username)@\(config.host):\(config.port)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            let favoriteServers = macFilteredServers(serverManager.favoriteServers)
            if !favoriteServers.isEmpty {
                Section("Favorites") {
                    ForEach(favoriteServers) { server in
                        macSavedHostSidebarItem(server)
                    }
                }
            }

            let recentServers = macFilteredServers(serverManager.recentServers)
            if !recentServers.isEmpty {
                Section("Recent") {
                    ForEach(recentServers) { server in
                        macSavedHostSidebarItem(server)
                    }
                }
            }

            let allServers = macFilteredServers(serverManager.servers)
            if !allServers.isEmpty {
                Section("All Connections") {
                    ForEach(allServers) { server in
                        macSavedHostSidebarItem(server)
                    }
                }
            }

            if !activeTagFilters.isEmpty {
                Section("Filters") {
                    ForEach(activeTagFilters, id: \.self) { tag in
                        Button {
                            activeTagFilters.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                        } label: {
                            Label(tag, systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Network") {
                Button {
                    macSelectedServerID = nil
                    macShowsTailscale = true
                    selectedSection = .tailscale
                } label: {
                    Label("Tailscale", systemImage: "network")
                        .foregroundStyle(ConnectionSection.tailscale.color)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Connections")
        .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        .onChange(of: macSelectedServerID) { _, serverID in
            if serverID != nil {
                macShowsTailscale = false
                selectedSection = .all
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Button("Add Server", systemImage: "plus") {
                    showingAddServer = true
                }

                Menu {
                    layoutMenuItems
                } label: {
                    Label("Workgroups", systemImage: "rectangle.3.group")
                }

                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(8)
            .background(.bar)
        }
    }

    private var macConnectionDetail: some View {
        Group {
            if macShowsTailscale {
                tailscaleDetailView
            } else if let server = macSelectedServer {
                VStack(spacing: 0) {
                    Form {
                        Section("Connection") {
                            LabeledContent("Host", value: "\(server.host):\(server.port)")
                            LabeledContent("User", value: server.username)
                            LabeledContent("Authentication", value: server.authMethod.displayName)
                        }

                        Section("Activity") {
                            LabeledContent(
                                "Status",
                                value: sessionForServer(server)?.state.displayName ?? "Disconnected"
                            )
                            LabeledContent(
                                "Last Connected",
                                value: server.lastConnected.map {
                                    relativeDateFormatter.localizedString(for: $0, relativeTo: Date())
                                } ?? "Never"
                            )
                        }

                        if !server.tags.isEmpty {
                            Section("Tags") {
                                Text(server.tags.joined(separator: ", "))
                            }
                        }
                    }
                    .formStyle(.grouped)

                    HStack {
                        Button("Details", systemImage: "info.circle") {
                            viewingServer = server
                        }
                        Button("Edit", systemImage: "pencil") {
                            editingServer = server
                        }
                        Spacer()
                        Button("Connect", systemImage: "terminal") {
                            connectToServer(server)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                    .background(.bar)
                }
            } else {
                ContentUnavailableView {
                    Label("Select a Connection", systemImage: "server.rack")
                } description: {
                    Text("Choose a saved host in the sidebar, or add a new connection.")
                } actions: {
                    Button("Local Terminal", systemImage: "apple.terminal") {
                        openLocalTerminal()
                    }
                    Button("Add Server", systemImage: "plus") {
                        showingAddServer = true
                    }
                }
            }
        }
    }

    private var macSelectedServer: ServerConfiguration? {
        guard let macSelectedServerID else { return nil }
        return serverManager.server(for: macSelectedServerID)
    }

    @ViewBuilder
    private func macSavedHostSidebarItem(_ server: ServerConfiguration) -> some View {
        macSavedHostRow(server)
            .tag(server.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                macSelectedServerID = server.id
                connectToServer(server)
            }
            .contextMenu {
                Button("Connect", systemImage: "terminal") {
                    connectToServer(server)
                }
                Button("Details", systemImage: "info.circle") {
                    viewingServer = server
                }
                Button("Edit", systemImage: "pencil") {
                    editingServer = server
                }
                Button(
                    server.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: server.isFavorite ? "heart.slash" : "heart"
                ) {
                    serverManager.toggleFavorite(server)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    serverPendingDeletion = server
                }
            }
    }

    private func macFilteredServers(_ servers: [ServerConfiguration]) -> [ServerConfiguration] {
        var result = servers
        if !activeTagFilters.isEmpty {
            let active = Set(activeTagFilters.map { $0.lowercased() })
            result = result.filter { server in
                !active.isDisjoint(with: Set(server.tags.map { $0.lowercased() }))
            }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.host.localizedCaseInsensitiveContains(query)
                    || $0.username.localizedCaseInsensitiveContains(query)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        return result
    }

    private func macSavedHostRow(_ server: ServerConfiguration) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(server.colorTag.color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if server.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                }
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let session = sessionForServer(server) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(session.state.displayName)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name), \(server.username) at \(server.host)")
        .accessibilityHint("Double-click to connect")
    }
    #endif
    
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
            guard let parsedPort = Int(hostPart[hostPart.index(after: colonIndex)...]),
                  (1...65_535).contains(parsedPort) else { return nil }
            port = parsedPort
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
                            serverPendingDeletion = server
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
                .terminalTextInputDefaults()
            SecureField("Password", text: $quickConnectPassword)
            TextField("Port", text: $quickConnectPort)
                .terminalNumericInput()
            Button("Connect") {
                if let device = tailscaleUsernamePromptDevice {
                    guard let port = Int(quickConnectPort), (1...65_535).contains(port) else {
                        connectionFailureMessage = "Enter an SSH port from 1 through 65535."
                        return
                    }
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
                        do {
                            let launch = try await sessionManager.createTransientAuthorizedSession(
                                for: config,
                                settingsManager: settingsManager,
                                password: password
                            )
                            if launch.session.state == .connected {
                                presentTerminalWindow(for: launch.session)
                            } else if let challenge = launch.session.pendingHostKeyChallenge {
                                stageHostKeyChallenge(
                                    challenge,
                                    for: launch.session
                                )
                            } else if case .error(let message) = launch.session.state {
                                connectionFailureMessage = message
                                sessionManager.closeSession(launch.session)
                            }
                        } catch {
                            connectionFailureMessage = error.localizedDescription
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

    private func handleSearchSubmission() {
        if let config = quickConnectConfig {
            quickConnectPasswordPrompt = config
        } else {
            applySearchAsTagFilterIfPossible()
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

    #if os(macOS)
    private func openLocalTerminal() {
        openWindow(id: "workspace", value: MacWorkspaceLaunchRequest())
    }
    #endif

    private func presentTerminalWindow(for session: TerminalSession) {
        #if os(visionOS)
        let workgroupID = sessionManager.createWorkgroup(
            name: session.server.name,
            colorTag: session.server.colorTag
        )
        guard sessionManager.appendSession(session, toWorkgroup: workgroupID) else {
            sessionManager.discardWorkgroupIfEmpty(workgroupID)
            connectionFailureMessage = "The terminal could not be added to its workgroup."
            return
        }
        openWindow(id: "terminal", value: workgroupID)
        dismissWindow(id: "main")
        #else
        openWindow(id: "terminal", value: session.id)
        #endif
    }
    
    private func connectToServer(
        _ server: ServerConfiguration,
        legacyAlgorithmsConfirmed: Bool = false
    ) {
        if server.legacyAlgorithmsEnabled && !legacyAlgorithmsConfirmed {
            pendingLegacyAlgorithmServer = server
            return
        }

        Task { @MainActor in
            let launch: AuthorizedSessionLaunch
            do {
                launch = try await sessionManager.createAuthorizedSession(for: server, settingsManager: settingsManager)
            } catch {
                connectionFailureMessage = error.localizedDescription
                return
            }

            let session = launch.session
            if let challenge = session.pendingHostKeyChallenge,
               settingsManager.hostKeyVerificationMode == HostKeyVerificationMode.ask.rawValue {
                pendingTrustSession = session
                pendingTrustChallenge = challenge
                return
            }

            if session.state == .connected {
                presentTerminalWindow(for: session)
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
            get: { interactiveHostKeyTrustIsAllowed && pendingTrustChallenge != nil },
            set: { isPresented in
                if !isPresented {
                    if !interactiveHostKeyTrustIsAllowed,
                       let challenge = pendingTrustChallenge,
                       let session = pendingTrustSession {
                        rejectStrictHostKeyChallenge(challenge, for: session)
                    } else {
                        closePendingTrustSessionAndClearPrompt()
                    }
                }
            }
        )
    }

    private var interactiveHostKeyTrustIsAllowed: Bool {
        settingsManager.hostKeyVerificationMode == HostKeyVerificationMode.ask.rawValue
    }

    private var trustPromptTitle: String {
        pendingTrustChallenge?.reason == .changed ? "SSH Host Key Changed" : "Trust SSH Host Key?"
    }

    private var trustPromptConfirmTitle: String {
        pendingTrustChallenge?.reason == .changed ? "Trust Changed Key" : "Trust and Connect"
    }

    private func trustPromptMessage(for challenge: HostKeyTrustChallenge) -> String {
        switch challenge.reason {
        case .unknown:
            return "\(challenge.summary)\n\nAlgorithm: \(challenge.algorithm)\nFingerprint (SHA-256): \(challenge.fingerprintSHA256)"
        case .changed:
            return "The saved host key for \(challenge.host):\(challenge.port) no longer matches the server. This can happen after a legitimate server rebuild, but it can also indicate a security risk.\n\nNew algorithm: \(challenge.algorithm)\nNew fingerprint (SHA-256): \(challenge.fingerprintSHA256)"
        }
    }

    private func stageHostKeyChallenge(
        _ challenge: HostKeyTrustChallenge,
        for session: TerminalSession
    ) {
        guard interactiveHostKeyTrustIsAllowed else {
            rejectStrictHostKeyChallenge(challenge, for: session)
            return
        }
        pendingTrustSession = session
        pendingTrustChallenge = challenge
    }

    private func rejectStrictHostKeyChallenge(
        _ challenge: HostKeyTrustChallenge,
        for session: TerminalSession
    ) {
        let reason = challenge.reason == .changed
            ? "the presented key does not match the saved key"
            : "the presented key has not been saved"
        connectionFailureMessage =
            "Strict host-key verification blocked the connection to \(challenge.host):\(challenge.port) because \(reason). No trust decision was recorded."
        session.pendingHostKeyChallenge = nil
        sessionManager.closeSession(session)
        clearPendingTrustPrompt()
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

    private var legacyAlgorithmPromptBinding: Binding<Bool> {
        Binding(
            get: { pendingLegacyAlgorithmServer != nil },
            set: { isPresented in
                if !isPresented {
                    pendingLegacyAlgorithmServer = nil
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

        Task { @MainActor in
            if let updatedServer = serverManager.server(for: session.server.id) {
                session.server = updatedServer
            }
            session.pendingHostKeyChallenge = nil
            do {
                try await sessionManager.reconnect(session, settingsManager: settingsManager)
            } catch {
                connectionFailureMessage = error.localizedDescription
                sessionManager.closePendingHostTrustSession(session)
                clearPendingTrustPrompt()
                return
            }
            if session.state == .connected {
                presentTerminalWindow(for: session)
                clearPendingTrustPrompt()
            } else {
                if case .error(let message) = session.state {
                    connectionFailureMessage = message
                }
                sessionManager.closePendingHostTrustSession(session)
                clearPendingTrustPrompt()
            }
        }
    }

    private func closePendingTrustSessionAndClearPrompt() {
        if let session = pendingTrustSession {
            sessionManager.closePendingHostTrustSession(session)
        }
        clearPendingTrustPrompt()
    }

    private func clearPendingTrustPrompt() {
        pendingTrustSession = nil
        pendingTrustChallenge = nil
    }

    // MARK: - Workgroup Presets

    private var currentSavedSessionIntents: [LayoutPreset.SessionIntent] {
        sessionManager.sessions.compactMap { session in
            guard serverManager.server(for: session.server.id) != nil else { return nil }
            return LayoutPreset.SessionIntent(serverID: session.server.id)
        }
    }

    private func editCurrentSessionsAsWorkgroup() {
        let intents = currentSavedSessionIntents
        guard !intents.isEmpty else {
            connectionFailureMessage = "No open sessions use a saved SSH connection."
            return
        }
        workgroupEditorContext = .new(
            name: "Workgroup (\(intents.count) tabs)",
            sessionIntents: intents
        )
    }

    private func openWorkgroup(_ preset: LayoutPreset) {
        settingsManager.updateLayoutPresetLastUsed(preset.id)
        let restorationPlan = LayoutRestorationPlan(
            preset: preset,
            availableServers: serverManager.servers
        )
        #if os(visionOS)
        openVisionWorkgroup(preset, plan: restorationPlan)
        #else
        openMacWorkgroup(preset, plan: restorationPlan)
        #endif
    }

    #if os(visionOS)
    private func openVisionWorkgroup(_ preset: LayoutPreset, plan: LayoutRestorationPlan) {
        Task { @MainActor in
            let workgroupID = sessionManager.createWorkgroup(
                name: preset.name,
                colorTag: preset.colorTag
            )
            var failures = plan.failures
            var appendedSessionIDs: [UUID] = []

            for target in plan.targets {
                guard target.intent.kind == .ssh,
                      let server = target.server,
                      let serverID = target.intent.serverID else {
                    failures.append("\(target.displayName): local terminals are available on macOS.")
                    continue
                }
                do {
                    let launch = try await sessionManager.createAuthorizedSessionByServerID(
                        serverID,
                        settingsManager: settingsManager,
                        startupCommand: target.intent.startupCommand
                    )
                    let session = launch.session
                    if session.state == .connected
                        || (interactiveHostKeyTrustIsAllowed && session.pendingHostKeyChallenge != nil) {
                        if sessionManager.appendSession(session, toWorkgroup: workgroupID) {
                            appendedSessionIDs.append(session.id)
                        } else {
                            failures.append("\(target.displayName): the terminal could not be added to the workgroup.")
                            sessionManager.closeSession(session)
                        }
                    } else if let challenge = session.pendingHostKeyChallenge {
                        let reason = challenge.reason == .changed
                            ? "presented a changed host key"
                            : "presented an unknown host key"
                        failures.append("\(server.name): Strict host-key verification blocked the connection because it \(reason).")
                        session.pendingHostKeyChallenge = nil
                        sessionManager.closeSession(session)
                    } else if case .error(let message) = session.state {
                        failures.append("\(server.name): \(message)")
                        sessionManager.closeSession(session)
                    }
                } catch {
                    failures.append("\(server.name): \(error.localizedDescription)")
                }
            }

            if let firstSessionID = appendedSessionIDs.first {
                sessionManager.selectSession(firstSessionID, inWorkgroup: workgroupID)
                openWindow(id: "terminal", value: workgroupID)
                dismissWindow(id: "main")
            } else {
                sessionManager.discardWorkgroupIfEmpty(workgroupID)
            }
            if !failures.isEmpty {
                connectionFailureMessage = failures.joined(separator: "\n")
            }
        }
    }
    #else
    private func openMacWorkgroup(_ preset: LayoutPreset, plan: LayoutRestorationPlan) {
        let items = plan.targets.compactMap { target -> MacWorkgroupLaunchItem? in
            let paneIntent: MacWorkspacePaneIntent
            switch target.intent.kind {
            case .local:
                paneIntent = .local
            case .ssh:
                guard let serverID = target.intent.serverID else { return nil }
                paneIntent = .ssh(serverID: serverID)
            }
            return MacWorkgroupLaunchItem(
                intent: paneIntent,
                label: target.displayName,
                startupCommand: target.intent.startupCommand
            )
        }
        if !items.isEmpty {
            MacWorkgroupLauncher.launch(
                workgroupID: UUID(),
                name: preset.name,
                color: preset.colorTag,
                items: items
            ) { request in
                openWindow(id: "workspace", value: request)
            }
        }
        if !plan.failures.isEmpty {
            connectionFailureMessage = plan.failures.joined(separator: "\n")
        }
    }
    #endif
}

struct LayoutRestorationTarget {
    let intent: LayoutPreset.SessionIntent
    let server: ServerConfiguration?

    var displayName: String {
        intent.label ?? server?.name ?? "Local Terminal"
    }
}

struct LayoutRestorationPlan {
    let targets: [LayoutRestorationTarget]
    let failures: [String]

    init(preset: LayoutPreset, availableServers: [ServerConfiguration]) {
        let serversByID = Dictionary(
            availableServers.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var targets: [LayoutRestorationTarget] = []
        var failures: [String] = []

        for (index, intent) in preset.sessionIntents.enumerated() {
            let sessionNumber = index + 1
            guard intent.isSupported else {
                failures.append("Session \(sessionNumber): this saved session intention is not supported by this version of glas.sh.")
                continue
            }
            switch intent.kind {
            case .local:
                targets.append(LayoutRestorationTarget(intent: intent, server: nil))
            case .ssh:
                guard let serverID = intent.serverID,
                      let server = serversByID[serverID] else {
                    failures.append("Session \(sessionNumber): a saved server in this workgroup no longer exists.")
                    continue
                }
                guard !server.legacyAlgorithmsEnabled else {
                    failures.append("\(server.name): legacy algorithms require a direct security review.")
                    continue
                }
                targets.append(LayoutRestorationTarget(intent: intent, server: server))
            }
        }

        self.targets = targets
        self.failures = failures
    }
}

private struct WorkgroupEditorContext: Identifiable {
    let id = UUID()
    let original: LayoutPreset?
    let name: String
    let colorTag: ServerColorTag
    let sessionIntents: [LayoutPreset.SessionIntent]

    static func new(
        name: String = "Workgroup",
        colorTag: ServerColorTag = .blue,
        sessionIntents: [LayoutPreset.SessionIntent] = []
    ) -> Self {
        Self(
            original: nil,
            name: name,
            colorTag: colorTag,
            sessionIntents: sessionIntents
        )
    }

    static func edit(_ preset: LayoutPreset) -> Self {
        Self(
            original: preset,
            name: preset.name,
            colorTag: preset.colorTag,
            sessionIntents: preset.sessionIntents
        )
    }

    static func duplicate(_ preset: LayoutPreset) -> Self {
        let copyName = String("\(preset.name) Copy".prefix(LayoutPreset.maximumNameLength))
        return Self(
            original: nil,
            name: copyName,
            colorTag: preset.colorTag,
            sessionIntents: preset.sessionIntents
        )
    }
}

private struct WorkgroupTabDraft: Identifiable {
    let id: UUID
    var kind: LayoutPreset.SessionIntent.Kind
    var serverID: UUID?
    var label: String
    var startupCommand: String

    init(
        id: UUID = UUID(),
        kind: LayoutPreset.SessionIntent.Kind,
        serverID: UUID? = nil,
        label: String = "",
        startupCommand: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.serverID = serverID
        self.label = label
        self.startupCommand = startupCommand
    }

    init(intent: LayoutPreset.SessionIntent) {
        self.init(
            kind: intent.kind,
            serverID: intent.serverID,
            label: intent.label ?? "",
            startupCommand: intent.startupCommand ?? ""
        )
    }
}

private struct WorkgroupEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let context: WorkgroupEditorContext
    let servers: [ServerConfiguration]
    let onSave: (LayoutPreset) -> Void

    @State private var name: String
    @State private var colorTag: ServerColorTag
    @State private var tabs: [WorkgroupTabDraft]

    init(
        context: WorkgroupEditorContext,
        servers: [ServerConfiguration],
        onSave: @escaping (LayoutPreset) -> Void
    ) {
        self.context = context
        self.servers = servers
        self.onSave = onSave
        _name = State(initialValue: context.name)
        _colorTag = State(initialValue: context.colorTag)
        _tabs = State(initialValue: context.sessionIntents.map(WorkgroupTabDraft.init(intent:)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Workgroup") {
                    TextField("Name", text: $name)

                    LabeledContent("Color") {
                        HStack(spacing: 10) {
                            ForEach(ServerColorTag.allCases, id: \.self) { tag in
                                Button {
                                    colorTag = tag
                                } label: {
                                    Circle()
                                        .fill(tag.color)
                                        .frame(width: 26, height: 26)
                                        .overlay {
                                            if colorTag == tag {
                                                Circle()
                                                    .strokeBorder(.primary, lineWidth: 2)
                                                    .padding(2)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(tag.rawValue) color")
                                .accessibilityAddTraits(colorTag == tag ? .isSelected : [])
                            }
                        }
                    }
                }

                Section {
                    ForEach($tabs) { $tab in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                #if os(macOS)
                                Picker("Type", selection: $tab.kind) {
                                    Text("Local").tag(LayoutPreset.SessionIntent.Kind.local)
                                    Text("SSH").tag(LayoutPreset.SessionIntent.Kind.ssh)
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 220)
                                .onChange(of: tab.kind) { _, kind in
                                    tab.serverID = kind == .ssh ? (tab.serverID ?? servers.first?.id) : nil
                                }
                                #else
                                Label(
                                    tab.kind == .local ? "Local (macOS)" : "SSH",
                                    systemImage: tab.kind == .local ? "apple.terminal" : "network"
                                )
                                    .font(.headline)
                                #endif

                                Spacer()
                                Button("Move Tab Up", systemImage: "arrow.up") {
                                    moveTab(tab.id, by: -1)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(tabs.first?.id == tab.id)

                                Button("Move Tab Down", systemImage: "arrow.down") {
                                    moveTab(tab.id, by: 1)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(tabs.last?.id == tab.id)

                                Button("Remove Tab", systemImage: "trash", role: .destructive) {
                                    tabs.removeAll { $0.id == tab.id }
                                }
                                .labelStyle(.iconOnly)
                            }

                            if tab.kind == .ssh {
                                Picker("Connection", selection: $tab.serverID) {
                                    Text("Choose a saved connection").tag(UUID?.none)
                                    ForEach(servers) { server in
                                        Text(server.name).tag(Optional(server.id))
                                    }
                                    if let serverID = tab.serverID,
                                       !servers.contains(where: { $0.id == serverID }) {
                                        Text("Missing Connection").tag(Optional(serverID))
                                    }
                                }
                            }

                            TextField("Tab label (optional)", text: $tab.label)
                            TextField("Startup command (optional)", text: $tab.startupCommand)
                                .font(.body.monospaced())
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { source, destination in
                        tabs.move(fromOffsets: source, toOffset: destination)
                    }

                    HStack {
                        #if os(macOS)
                        Button("Add Local Tab", systemImage: "apple.terminal") {
                            appendTab(kind: .local)
                        }
                        #endif
                        Button("Add SSH Tab", systemImage: "network") {
                            appendTab(kind: .ssh)
                        }
                        .disabled(servers.isEmpty)
                    }
                    .disabled(tabs.count >= LayoutPreset.maximumSessionCount)
                } header: {
                    Text("Ordered Tabs")
                } footer: {
                    Text(validationMessage ?? "Startup commands run once, only after the terminal is connected and host trust succeeds.")
                        .foregroundStyle(validationMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle(context.original == nil ? "New Workgroup" : "Edit Workgroup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(validationMessage != nil)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        guard !normalizedName.isEmpty else { return "Enter a workgroup name." }
        guard normalizedName.count <= LayoutPreset.maximumNameLength,
              !normalizedName.utf8.contains(0) else {
            return "The workgroup name must be at most \(LayoutPreset.maximumNameLength) characters."
        }
        guard !tabs.isEmpty else { return "Add at least one terminal tab." }
        guard tabs.count <= LayoutPreset.maximumSessionCount else {
            return "A workgroup can contain at most \(LayoutPreset.maximumSessionCount) tabs."
        }
        for (index, tab) in tabs.enumerated() {
            if tab.kind == .ssh {
                guard let serverID = tab.serverID,
                      servers.contains(where: { $0.id == serverID }) else {
                    return "Choose a saved connection for tab \(index + 1)."
                }
            }
            let label = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.count > LayoutPreset.SessionIntent.maximumLabelLength
                || label.utf8.contains(0) {
                return "Tab \(index + 1) has an invalid label."
            }
            let command = tab.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty, TerminalStartupCommandTicket(command: command) == nil {
                return "Tab \(index + 1) has an invalid startup command. Use one line no larger than 4 KB."
            }
        }
        return nil
    }

    private func appendTab(kind: LayoutPreset.SessionIntent.Kind) {
        guard tabs.count < LayoutPreset.maximumSessionCount else { return }
        tabs.append(WorkgroupTabDraft(
            kind: kind,
            serverID: kind == .ssh ? servers.first?.id : nil
        ))
    }

    private func moveTab(_ id: UUID, by offset: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard tabs.indices.contains(destination) else { return }
        tabs.swapAt(source, destination)
    }

    private func save() {
        guard validationMessage == nil else { return }
        let intents = tabs.map { tab in
            LayoutPreset.SessionIntent(
                kind: tab.kind,
                serverID: tab.kind == .ssh ? tab.serverID : nil,
                label: tab.label,
                startupCommand: tab.startupCommand
            )
        }
        let preset = LayoutPreset(
            id: context.original?.id ?? UUID(),
            name: normalizedName,
            colorTag: colorTag,
            sessionIntents: intents,
            createdAt: context.original?.createdAt ?? Date(),
            lastUsed: context.original?.lastUsed
        )
        onSave(preset)
        dismiss()
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
                    infoRow("Keep Alive", "\(server.keepAliveInterval)s")
                    infoRow("Legacy Algorithms", server.legacyAlgorithmsEnabled ? "Allowed" : "Disabled")
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
            return "Secure Enclave Hardware"
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
