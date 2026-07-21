//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI
import GlasSecretStore
import os

private enum ConnectionWorkgroupSelection: Hashable {
    case live(UUID)
    case preset(UUID)
}

#if os(iOS)
private enum ConnectionCompactDestination: Hashable {
    case results
    case detail
}
#endif

struct ConnectionManagerView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    #if os(iOS)
    @Environment(IOSAppRouter.self) private var iOSRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var serverManager: ServerManager { sessionManager.serverManager }

    @State private var selectedMode: ConnectionLibraryMode = .library
    @State private var selectedScope: ConnectionLibraryScope = .allConnections
    @State private var selectedServerID: UUID?
    @State private var selectedWorkgroupSelection: ConnectionWorkgroupSelection?
    @State private var selectedTailscaleDeviceID: String?
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfiguration?
    @State private var viewingServer: ServerConfiguration?
    @State private var searchQuery: String = ""
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
    @State private var tailscaleImportDraft: ServerConfiguration?
    @State private var serverPendingDeletion: ServerConfiguration?
    @State private var workgroupEditorContext: WorkgroupEditorContext?
    @State private var tailscaleIsConfigured = false
    #if os(iOS)
    @State private var compactNavigationPath: [ConnectionCompactDestination] = []
    #endif
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        let connectionLibrary = ConnectionLibraryProjection(
            servers: serverManager.servers,
            workgroups: settingsManager.layoutPresets,
            networkIsConfigured: tailscaleIsConfigured
        )

        platformLibrary(connectionLibrary: connectionLibrary)
        .accessibilityIdentifier("connection-library")
        .sheet(isPresented: $showingAddServer) {
            AddServerView(serverManager: serverManager)
        }
        .sheet(item: $tailscaleImportDraft) { draft in
            AddServerView(serverManager: serverManager, draft: draft)
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
            refreshTailscaleConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tailscaleCredentialsDidChange)) { _ in
            tailscaleClient.invalidateCredentialState()
            selectedTailscaleDeviceID = nil
            refreshTailscaleConfiguration()
            if tailscaleIsConfigured, selectedMode == .network {
                loadTailscaleDevices()
            }
        }
        .onChange(of: tailscaleIsConfigured) { _, isConfigured in
            if !isConfigured, selectedMode == .network {
                selectMode(.library, in: connectionLibrary)
            }
        }
        .onChange(of: serverManager.servers.map(\.id)) { _, serverIDs in
            if let selectedServerID, !serverIDs.contains(selectedServerID) {
                self.selectedServerID = nil
            }
        }
        .onChange(of: settingsManager.layoutPresets.map(\.id)) { _, workgroupIDs in
            if case .preset(let selectedWorkgroupID) = selectedWorkgroupSelection,
               !workgroupIDs.contains(selectedWorkgroupID) {
                selectedWorkgroupSelection = nil
            }
        }
        #if os(iOS)
        .onChange(of: sessionManager.workgroups.map(\.id)) { _, workgroupIDs in
            if case .live(let selectedWorkgroupID) = selectedWorkgroupSelection,
               !workgroupIDs.contains(selectedWorkgroupID) {
                selectedWorkgroupSelection = nil
            }
        }
        #endif
        .onChange(of: connectionLibrary.collections.map(\.id)) { _, collectionIDs in
            guard selectedMode == .collections else { return }
            if case .collection(let selectedCollectionID) = selectedScope,
               collectionIDs.contains(selectedCollectionID) {
                return
            }
            clearLibrarySelection()
            if let firstCollectionID = collectionIDs.first {
                selectedScope = .collection(firstCollectionID)
            } else {
                selectMode(.library, in: connectionLibrary)
            }
        }
        .onChange(of: tailscaleClient.devices.map(\.id)) { _, deviceIDs in
            if let selectedTailscaleDeviceID,
               !deviceIDs.contains(selectedTailscaleDeviceID) {
                self.selectedTailscaleDeviceID = nil
            }
        }
    }

    // MARK: - Connection Library Shells

    @ViewBuilder
    private func platformLibrary(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        #if os(macOS)
        NavigationSplitView {
            libraryNavigation(connectionLibrary: connectionLibrary)
        } content: {
            libraryResults(connectionLibrary: connectionLibrary)
        } detail: {
            libraryDetail(connectionLibrary: connectionLibrary)
        }
        #elseif os(visionOS)
        visionLibrary(connectionLibrary: connectionLibrary)
            .ornament(attachmentAnchor: .scene(.leading)) {
                visionModeOrnament(connectionLibrary: connectionLibrary)
                    .glassBackgroundEffect(in: .rect(cornerRadius: 24))
            }
            .focusedSceneValue(
                \.platformNewTerminalAction,
                PlatformNewTerminalAction(title: "New Terminal") {
                    showTerminalChooser(in: connectionLibrary)
                }
            )
        #elseif os(iOS)
        if horizontalSizeClass == .compact {
            iOSCompactLibrary(connectionLibrary: connectionLibrary)
                .focusedSceneValue(
                    \.platformNewTerminalAction,
                    PlatformNewTerminalAction(title: "New Terminal") {
                        showTerminalChooser(in: connectionLibrary)
                    }
                )
        } else {
            NavigationSplitView {
                libraryNavigation(connectionLibrary: connectionLibrary)
            } content: {
                libraryResults(connectionLibrary: connectionLibrary)
            } detail: {
                libraryDetail(connectionLibrary: connectionLibrary)
            }
            .focusedSceneValue(
                \.platformNewTerminalAction,
                PlatformNewTerminalAction(title: "New Terminal") {
                    showTerminalChooser(in: connectionLibrary)
                }
            )
        }
        #else
        NavigationSplitView {
            libraryNavigation(connectionLibrary: connectionLibrary)
        } content: {
            libraryResults(connectionLibrary: connectionLibrary)
        } detail: {
            libraryDetail(connectionLibrary: connectionLibrary)
        }
        #endif
    }

    #if os(iOS)
    private func iOSCompactLibrary(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        NavigationStack(path: $compactNavigationPath) {
            libraryNavigation(connectionLibrary: connectionLibrary)
                .navigationDestination(for: ConnectionCompactDestination.self) { destination in
                    switch destination {
                    case .results:
                        libraryResults(connectionLibrary: connectionLibrary)
                    case .detail:
                        libraryDetail(connectionLibrary: connectionLibrary)
                    }
                }
        }
        .onChange(of: selectedServerID) { _, serverID in
            updateCompactDetailPath(hasSelection: serverID != nil)
        }
        .onChange(of: selectedWorkgroupSelection) { _, selection in
            updateCompactDetailPath(hasSelection: selection != nil)
        }
        .onChange(of: selectedTailscaleDeviceID) { _, deviceID in
            updateCompactDetailPath(hasSelection: deviceID != nil)
        }
        .onChange(of: compactNavigationPath) { _, path in
            if path.last != .detail {
                clearDetailSelection()
            }
        }
    }

    private func updateCompactDetailPath(hasSelection: Bool) {
        if hasSelection {
            guard compactNavigationPath.last == .results else { return }
            compactNavigationPath.append(.detail)
        } else if compactNavigationPath.last == .detail {
            compactNavigationPath.removeLast()
        }
    }
    #endif

    #if os(visionOS)
    @ViewBuilder
    private func visionLibrary(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        if selectedMode == .collections {
            NavigationSplitView {
                collectionNavigation(connectionLibrary: connectionLibrary)
            } content: {
                libraryResults(connectionLibrary: connectionLibrary)
            } detail: {
                libraryDetail(connectionLibrary: connectionLibrary)
            }
        } else {
            NavigationSplitView {
                libraryResults(connectionLibrary: connectionLibrary)
            } detail: {
                libraryDetail(connectionLibrary: connectionLibrary)
            }
        }
    }

    private func visionModeOrnament(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        VStack(spacing: 10) {
            ForEach(connectionLibrary.availableModes) { mode in
                Button {
                    selectMode(mode, in: connectionLibrary)
                } label: {
                    Image(systemName: modeSystemImage(mode))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(
                    selectedMode == mode ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: .circle
                )
                .accessibilityLabel(mode.title)
                .accessibilityIdentifier("connection-library-mode-\(mode.rawValue)")
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
            }

            Divider()

            Button {
                showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("connection-library-settings")
        }
        .padding(10)
    }
    #endif

    private func libraryNavigation(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        List {
            Section("Library") {
                libraryNavigationButton(
                    mode: .library,
                    scope: .allConnections,
                    count: connectionLibrary.itemCount(in: .allConnections)
                )
                libraryNavigationButton(
                    mode: .favorites,
                    scope: .favorites,
                    count: connectionLibrary.itemCount(in: .favorites)
                )
                libraryNavigationButton(
                    mode: .recent,
                    scope: .recent,
                    count: connectionLibrary.itemCount(in: .recent)
                )
            }

            if !connectionLibrary.collections.isEmpty {
                Section("Collections") {
                    ForEach(connectionLibrary.collections) { collection in
                        libraryNavigationButton(
                            mode: .collections,
                            scope: .collection(collection.id),
                            title: collection.name,
                            count: collection.count
                        )
                    }
                }
            }

            Section("Workgroups") {
                libraryNavigationButton(
                    mode: .workgroups,
                    scope: .workgroups,
                    count: connectionLibrary.workgroups.count
                )
            }

            if connectionLibrary.networkIsConfigured {
                Section("Network") {
                    libraryNavigationButton(
                        mode: .network,
                        scope: .network,
                        title: "Tailscale",
                        count: tailscaleClient.devices.count
                    )
                }
            }

            Section {
                Button {
                    showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("connection-library-settings")
            }
        }
        .accessibilityIdentifier("connection-library-navigation")
        .listStyle(.sidebar)
        .navigationTitle("Connections")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Local Terminal", systemImage: "apple.terminal") {
                    openLocalTerminal()
                }
                #endif
                #if os(iOS)
                if iOSRouter.resumableWorkgroupID(in: sessionManager) != nil {
                    Button("Return to Terminal", systemImage: "arrow.uturn.backward.circle") {
                        resumeMostRecentTerminal()
                    }
                    .accessibilityIdentifier("connection-library-return-to-terminal")
                }
                #endif
                Button("Add Server", systemImage: "plus") {
                    showingAddServer = true
                }
                .accessibilityIdentifier("connection-library-add-server-sidebar")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(8)
            .background(.bar)
        }
    }

    private func collectionNavigation(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        List {
            if connectionLibrary.collections.isEmpty {
                ContentUnavailableView(
                    "No Collections",
                    systemImage: "folder",
                    description: Text("Add a tag to a saved connection to create a collection.")
                )
            } else {
                ForEach(connectionLibrary.collections) { collection in
                    libraryNavigationButton(
                        mode: .collections,
                        scope: .collection(collection.id),
                        title: collection.name,
                        count: collection.count
                    )
                }
            }
        }
        .navigationTitle("Collections")
    }

    private func libraryNavigationButton(
        mode: ConnectionLibraryMode,
        scope: ConnectionLibraryScope,
        title: String? = nil,
        count: Int
    ) -> some View {
        Button {
            selectedMode = mode
            selectedScope = scope
            clearLibrarySelection()
            #if os(iOS)
            if horizontalSizeClass == .compact {
                compactNavigationPath.append(.results)
            }
            #endif
        } label: {
            HStack {
                Label(title ?? mode.title, systemImage: modeSystemImage(mode))
                Spacer()
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection-library-scope-\(scope.id)")
        .listRowBackground(
            selectedMode == mode && selectedScope == scope
                ? Color.accentColor.opacity(0.16)
                : Color.clear
        )
        .accessibilityAddTraits(
            selectedMode == mode && selectedScope == scope ? .isSelected : []
        )
    }

    @ViewBuilder
    private func libraryResults(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        switch selectedMode {
        case .workgroups:
            workgroupResults(connectionLibrary: connectionLibrary)
        case .network:
            tailscaleDetailView
                .navigationTitle("Tailscale")
        case .library, .favorites, .recent, .collections:
            connectionResults(connectionLibrary: connectionLibrary)
        }
    }

    private func connectionResults(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        let servers = visibleServers(in: connectionLibrary)
        return List(selection: $selectedServerID) {
            if let config = quickConnectConfig {
                Section("Quick Connect") {
                    Button {
                        quickConnectPasswordPrompt = config
                    } label: {
                        Label(
                            "Connect to \(config.username)@\(config.host):\(config.port)",
                            systemImage: "bolt.fill"
                        )
                    }
                }
            }

            if servers.isEmpty, quickConnectConfig == nil {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "server.rack")
                    } description: {
                        Text("Add a saved host to begin.")
                    } actions: {
                        #if os(macOS)
                        Button("Local Terminal", systemImage: "apple.terminal") {
                            openLocalTerminal()
                        }
                        #endif
                        Button("Add Server", systemImage: "plus") {
                            showingAddServer = true
                        }
                        .accessibilityIdentifier("connection-library-add-server-empty-results")
                    }
                    .accessibilityIdentifier("connection-library-empty-results")
                } else {
                    ContentUnavailableView.search(text: searchQuery)
                }
            } else {
                ForEach(servers) { server in
                    ServerListRow(
                        server: server,
                        session: sessionForServer(server),
                        onView: { viewingServer = server },
                        onEdit: { editingServer = server },
                        onDelete: { serverPendingDeletion = server },
                        onToggleFavorite: { serverManager.toggleFavorite(server) }
                    )
                    .tag(server.id)
                    .accessibilityIdentifier(
                        "connection-library-server-\(server.id.uuidString.lowercased())"
                    )
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onTapGesture(count: 2) {
                        selectedServerID = server.id
                        connectToServer(server)
                    }
                    #elseif os(iOS)
                    .onTapGesture {
                        selectedServerID = server.id
                    }
                    #endif
                }
            }
        }
        .accessibilityIdentifier("connection-library-results-connections")
        .navigationTitle(resultTitle(connectionLibrary: connectionLibrary))
        .searchable(text: $searchQuery, prompt: "Search connections...")
        .onSubmit(of: .search) {
            if let config = quickConnectConfig {
                quickConnectPasswordPrompt = config
            }
        }
        .onChange(of: servers.map(\.id)) { _, visibleIDs in
            if let selectedServerID, !visibleIDs.contains(selectedServerID) {
                self.selectedServerID = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add connection")
                .accessibilityIdentifier("connection-library-add-server-results")

                #if os(macOS)
                Button {
                    openLocalTerminal()
                } label: {
                    Image(systemName: "apple.terminal")
                }
                .accessibilityLabel("Local terminal")
                #endif
            }
        }
    }

    private func workgroupResults(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        let presets = connectionLibrary.workgroups(matching: searchQuery)
        let liveWorkgroups = matchingLiveWorkgroups(searchQuery)
        let visibleSelections = liveWorkgroups.map { ConnectionWorkgroupSelection.live($0.id) }
            + presets.map { ConnectionWorkgroupSelection.preset($0.id) }
        return List(selection: $selectedWorkgroupSelection) {
            if liveWorkgroups.isEmpty, presets.isEmpty {
                ContentUnavailableView(
                    searchQuery.isEmpty ? "No Workgroups" : "No Matching Workgroups",
                    systemImage: "rectangle.stack",
                    description: Text(
                        searchQuery.isEmpty
                            ? "Create a reusable command-per-tab terminal workspace."
                            : "Try a different search."
                        )
                )
            }

            #if os(iOS)
            if !liveWorkgroups.isEmpty {
                Section("Live Terminals") {
                    ForEach(Array(liveWorkgroups.reversed())) { workgroup in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(workgroup.colorTag.color)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workgroup.name)
                                    .font(.headline)
                                Text("\(liveSessions(in: workgroup).count) live tabs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "waveform.path.ecg")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                        .tag(ConnectionWorkgroupSelection.live(workgroup.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedWorkgroupSelection = .live(workgroup.id)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(workgroup.name), \(liveSessions(in: workgroup).count) live tabs"
                        )
                        .accessibilityHint("Select to inspect this live terminal workgroup")
                        .accessibilityIdentifier(
                            "connection-library-live-workgroup-\(workgroup.id.uuidString.lowercased())"
                        )
                        .contextMenu {
                            Button("Resume", systemImage: "arrow.uturn.backward.circle") {
                                resumeLiveWorkgroup(workgroup.id)
                            }
                        }
                    }
                }
            }
            #endif

            if !presets.isEmpty {
                Section("Saved Workgroups") {
                    ForEach(presets) { preset in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(preset.colorTag.color)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.headline)
                            Text("\(preset.sessionIntents.count) tabs")
                                .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(ConnectionWorkgroupSelection.preset(preset.id))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(preset.name), \(preset.sessionIntents.count) tabs"
                    )
                    .accessibilityHint("Select to show workgroup details")
                    .accessibilityIdentifier(
                        "connection-library-workgroup-\(preset.id.uuidString.lowercased())"
                    )
                    #if os(iOS)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedWorkgroupSelection = .preset(preset.id)
                    }
                    #endif
                    .contextMenu {
                        Button("Open", systemImage: "rectangle.stack") {
                            openWorkgroup(preset)
                        }
                        Button("Edit", systemImage: "pencil") {
                            workgroupEditorContext = .edit(preset)
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            workgroupEditorContext = .duplicate(preset)
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            settingsManager.deleteLayoutPreset(preset)
                        }
                    }
                }
                }
            }
        }
        .accessibilityIdentifier("connection-library-results-workgroups")
        .navigationTitle("Workgroups")
        .searchable(text: $searchQuery, prompt: "Search workgroups...")
        .onChange(of: visibleSelections) { _, visibleSelections in
            if let selectedWorkgroupSelection,
               !visibleSelections.contains(selectedWorkgroupSelection) {
                self.selectedWorkgroupSelection = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editCurrentSessionsAsWorkgroup()
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
                .disabled(currentSavedSessionIntents.isEmpty)
                .accessibilityLabel("Save current SSH sessions as workgroup")
                .accessibilityIdentifier("connection-library-save-current-workgroup")

                Button {
                    workgroupEditorContext = .new()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New workgroup")
                .accessibilityIdentifier("connection-library-add-workgroup")
            }
        }
    }

    @ViewBuilder
    private func libraryDetail(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        switch selectedMode {
        case .workgroups:
            workgroupDetail(connectionLibrary: connectionLibrary)
        case .network:
            tailscaleDeviceDetail
        case .library, .favorites, .recent, .collections:
            serverDetail(connectionLibrary: connectionLibrary)
        }
    }

    @ViewBuilder
    private func serverDetail(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        if let server = selectedServer(in: connectionLibrary) {
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
                        Section("Collections") {
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
                    .accessibilityIdentifier(
                        "connection-library-connect-server-\(server.id.uuidString.lowercased())"
                    )
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(server.name)
            .accessibilityIdentifier(
                "connection-library-detail-server-\(server.id.uuidString.lowercased())"
            )
        } else {
            ContentUnavailableView {
                Label("Select a Connection", systemImage: "server.rack")
            } description: {
                Text("Choose a saved host to inspect it without connecting.")
            } actions: {
                #if os(macOS)
                Button("Local Terminal", systemImage: "apple.terminal") {
                    openLocalTerminal()
                }
                #endif
                Button("Add Server", systemImage: "plus") {
                    showingAddServer = true
                }
                .accessibilityIdentifier("connection-library-add-server-empty-detail")
            }
            .accessibilityIdentifier("connection-library-detail-empty-server")
        }
    }

    @ViewBuilder
    private func workgroupDetail(
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        if let workgroup = selectedLiveWorkgroup {
            let sessions = liveSessions(in: workgroup)
            VStack(spacing: 0) {
                List {
                    Section("Live Workgroup") {
                        LabeledContent("Name", value: workgroup.name)
                        LabeledContent("Live Tabs", value: "\(sessions.count)")
                    }
                    Section("Tabs") {
                        ForEach(sessions) { session in
                            let isSelected = session.id == workgroup.selectedSessionID
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.server.name)
                                        .font(.headline)
                                    Text("\(session.server.username)@\(session.server.host):\(session.server.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(session.state.displayName)
                                    .font(.caption)
                                    .foregroundStyle(session.state.color)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    #if os(iOS)
                    Button("Resume Terminal", systemImage: "arrow.uturn.backward.circle") {
                        resumeLiveWorkgroup(workgroup.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "connection-library-resume-workgroup-\(workgroup.id.uuidString.lowercased())"
                    )
                    #endif
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(workgroup.name)
            .accessibilityIdentifier(
                "connection-library-detail-live-workgroup-\(workgroup.id.uuidString.lowercased())"
            )
        } else if let preset = selectedWorkgroup(in: connectionLibrary) {
            VStack(spacing: 0) {
                List {
                    Section("Workgroup") {
                        LabeledContent("Name", value: preset.name)
                        LabeledContent("Tabs", value: "\(preset.sessionIntents.count)")
                    }
                    Section("Ordered Tabs") {
                        ForEach(Array(preset.sessionIntents.enumerated()), id: \.offset) { index, intent in
                            HStack {
                                Text("\(index + 1)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Image(systemName: intent.kind == .local ? "apple.terminal" : "network")
                                VStack(alignment: .leading) {
                                    Text(intent.label ?? defaultIntentLabel(intent))
                                    if intent.startupCommand != nil {
                                        Label("Runs startup command", systemImage: "checkmark.shield")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("Edit", systemImage: "pencil") {
                        workgroupEditorContext = .edit(preset)
                    }
                    Spacer()
                    Button("Open Workgroup", systemImage: "rectangle.stack") {
                        openWorkgroup(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "connection-library-open-workgroup-\(preset.id.uuidString.lowercased())"
                    )
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(preset.name)
            .accessibilityIdentifier(
                "connection-library-detail-workgroup-\(preset.id.uuidString.lowercased())"
            )
        } else {
            ContentUnavailableView {
                Label("Select a Workgroup", systemImage: "rectangle.stack")
            } description: {
                Text("Workgroups open one configured command per terminal tab.")
            } actions: {
                Button("New Workgroup", systemImage: "plus") {
                    workgroupEditorContext = .new()
                }
                .accessibilityIdentifier("connection-library-add-workgroup-empty-detail")
            }
            .accessibilityIdentifier("connection-library-detail-empty-workgroup")
        }
    }

    @ViewBuilder
    private var tailscaleDeviceDetail: some View {
        if let device = selectedTailscaleDevice {
            let savedServer = savedServer(for: device)
            VStack(spacing: 0) {
                Form {
                    Section("Device") {
                        LabeledContent("Name", value: device.hostname)
                        LabeledContent("Address", value: device.sshAddress)
                        LabeledContent("Operating System", value: device.os)
                        if !device.user.isEmpty {
                            LabeledContent("Owner", value: device.user)
                        }
                    }
                    Section("Library") {
                        LabeledContent("Saved Connection", value: savedServer?.name ?? "Not imported")
                    }
                }
                HStack {
                    if let savedServer {
                        Button("Edit", systemImage: "pencil") {
                            editingServer = savedServer
                        }
                        Spacer()
                        Button("Connect", systemImage: "terminal") {
                            connectToServer(savedServer)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(
                            "connection-library-connect-tailscale-\(device.id)"
                        )
                    } else {
                        Button("Import", systemImage: "square.and.arrow.down") {
                            importTailscaleDevice(device)
                        }
                        .accessibilityIdentifier(
                            "connection-library-import-tailscale-\(device.id)"
                        )
                        Spacer()
                        Button("Connect", systemImage: "terminal") {
                            tailscaleUsernamePromptDevice = device
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(
                            "connection-library-connect-tailscale-\(device.id)"
                        )
                    }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(device.hostname)
            .accessibilityIdentifier("connection-library-detail-tailscale-\(device.id)")
        } else {
            ContentUnavailableView(
                "Select a Tailscale Device",
                systemImage: "network",
                description: Text("Choose a device to connect or save it in the Library.")
            )
            .accessibilityIdentifier("connection-library-detail-empty-tailscale")
        }
    }

    private func selectMode(
        _ mode: ConnectionLibraryMode,
        in connectionLibrary: ConnectionLibraryProjection
    ) {
        selectedMode = mode
        if let firstScope = connectionLibrary.scopes(for: mode).first {
            selectedScope = firstScope
        } else if mode == .collections {
            // Empty collection IDs are impossible after tag normalization, so
            // this transient scope renders an honest empty result set instead
            // of leaking the previously selected mode's connections.
            selectedScope = .collection("")
        }
        clearLibrarySelection()
        searchQuery = ""
    }

    private func clearLibrarySelection() {
        clearDetailSelection()
        #if os(iOS)
        compactNavigationPath.removeAll()
        #endif
    }

    private func clearDetailSelection() {
        selectedServerID = nil
        selectedWorkgroupSelection = nil
        selectedTailscaleDeviceID = nil
    }

    private func showTerminalChooser(
        in connectionLibrary: ConnectionLibraryProjection
    ) {
        selectMode(.library, in: connectionLibrary)
    }

    private func modeSystemImage(_ mode: ConnectionLibraryMode) -> String {
        switch mode {
        case .library: return "server.rack"
        case .favorites: return "heart.fill"
        case .recent: return "clock.fill"
        case .collections: return "folder.fill"
        case .workgroups: return "rectangle.stack.fill"
        case .network: return "network"
        }
    }

    private func resultTitle(
        connectionLibrary: ConnectionLibraryProjection
    ) -> String {
        switch selectedScope {
        case .allConnections: return "All Connections"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .collection(let id):
            return connectionLibrary.collections.first(where: { $0.id == id })?.name ?? "Collection"
        case .workgroups: return "Workgroups"
        case .network: return "Network"
        }
    }

    private func visibleServers(
        in connectionLibrary: ConnectionLibraryProjection
    ) -> [ServerConfiguration] {
        connectionLibrary.servers(
            in: selectedScope,
            searchQuery: searchQuery
        )
    }

    private func selectedServer(
        in connectionLibrary: ConnectionLibraryProjection
    ) -> ServerConfiguration? {
        guard let resolvedServerID = connectionLibrary.resolvedSelection(
            preferredServerID: selectedServerID,
            in: selectedScope,
            searchQuery: searchQuery
        ) else {
            return nil
        }
        return connectionLibrary.servers.first(where: { $0.id == resolvedServerID })
    }

    private func selectedWorkgroup(
        in connectionLibrary: ConnectionLibraryProjection
    ) -> LayoutPreset? {
        guard case .preset(let selectedWorkgroupID) = selectedWorkgroupSelection else {
            return nil
        }
        return connectionLibrary.workgroups.first(where: { $0.id == selectedWorkgroupID })
    }

    private var selectedLiveWorkgroup: TerminalWorkgroup? {
        #if os(iOS)
        guard case .live(let selectedWorkgroupID) = selectedWorkgroupSelection else {
            return nil
        }
        return iOSRouter.liveWorkgroups(in: sessionManager).first {
            $0.id == selectedWorkgroupID
        }
        #else
        return nil
        #endif
    }

    private func liveSessions(in workgroup: TerminalWorkgroup) -> [TerminalSession] {
        workgroup.sessionIDs.compactMap { sessionManager.session(for: $0) }
    }

    private func matchingLiveWorkgroups(_ query: String) -> [TerminalWorkgroup] {
        #if os(iOS)
        let workgroups = iOSRouter.liveWorkgroups(in: sessionManager)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return workgroups }
        return workgroups.filter { workgroup in
            if workgroup.name.localizedCaseInsensitiveContains(normalizedQuery) {
                return true
            }
            return liveSessions(in: workgroup).contains { session in
                session.server.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || session.server.host.localizedCaseInsensitiveContains(normalizedQuery)
                    || session.server.username.localizedCaseInsensitiveContains(normalizedQuery)
            }
        }
        #else
        return []
        #endif
    }

    private var selectedTailscaleDevice: TailscaleDevice? {
        guard let selectedTailscaleDeviceID else { return nil }
        return tailscaleClient.devices.first(where: { $0.id == selectedTailscaleDeviceID })
    }

    private func savedServer(for device: TailscaleDevice) -> ServerConfiguration? {
        serverManager.servers.first {
            $0.provenance?.provider == .tailscale
                && $0.provenance?.externalID == device.id
        }
    }

    private func defaultIntentLabel(_ intent: LayoutPreset.SessionIntent) -> String {
        if intent.kind == .local { return "Local Terminal" }
        guard let serverID = intent.serverID,
              let server = serverManager.server(for: serverID) else {
            return "Missing Connection"
        }
        return server.name
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

    private var tailscaleDetailView: some View {
        List(selection: $selectedTailscaleDeviceID) {
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
                            .tag(device.id)
                            .contentShape(Rectangle())
                            #if os(iOS)
                            .onTapGesture {
                                selectedTailscaleDeviceID = device.id
                            }
                            #endif
                            .accessibilityIdentifier(
                                "connection-library-tailscale-\(device.id)"
                            )
                            .contextMenu {
                                if savedServer(for: device) == nil {
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
        }
        .accessibilityIdentifier("connection-library-results-network")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add connection")
                .accessibilityIdentifier("connection-library-add-server-network")
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
        guard savedServer(for: device) == nil else { return }
        guard let draft = Self.tailscaleImportDraft(for: device) else {
            connectionFailureMessage = "This Tailscale device has an invalid identity and was not imported."
            return
        }
        tailscaleImportDraft = draft
    }

    static func tailscaleImportDraft(for device: TailscaleDevice) -> ServerConfiguration? {
        guard let provenance = ServerConnectionProvenance(
            provider: .tailscale,
            externalID: device.id
        ) else { return nil }
        let importedTags = ["tailscale"] + device.tags.filter { $0 != "tailscale" }
        return ServerConfiguration(
            name: device.hostname,
            host: device.sshAddress,
            port: 22,
            username: "",
            tags: importedTags,
            provenance: provenance
        )
    }

    private func refreshTailscaleConfiguration() {
        tailscaleIsConfigured = TailscaleClient.hasConfiguredCredentials()
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

    private func showSettings() {
        #if os(iOS)
        iOSRouter.showSettings()
        #else
        openWindow(id: "settings")
        #endif
    }

    #if os(iOS)
    private func resumeMostRecentTerminal() {
        guard iOSRouter.resumeMostRecentTerminal(in: sessionManager) else {
            connectionFailureMessage = "The terminal workgroup is no longer available."
            return
        }
    }

    private func resumeLiveWorkgroup(_ workgroupID: UUID) {
        guard iOSRouter.resumeTerminal(
            workgroupID: workgroupID,
            in: sessionManager
        ) else {
            connectionFailureMessage = "The terminal workgroup is no longer available."
            return
        }
    }
    #endif

    private func presentTerminalWindow(for session: TerminalSession) {
        #if os(visionOS)
        let workgroupID = sessionManager.createWorkgroup(
            name: session.server.name,
            colorTag: session.server.colorTag
        )
        guard sessionManager.appendSession(session, toWorkgroup: workgroupID) else {
            sessionManager.closeSession(session)
            sessionManager.discardWorkgroupIfEmpty(workgroupID)
            connectionFailureMessage = "The terminal could not be added to its workgroup."
            return
        }
        openWindow(id: "terminal", value: workgroupID)
        #elseif os(iOS)
        let workgroupID = sessionManager.createWorkgroup(
            name: session.server.name,
            colorTag: session.server.colorTag
        )
        guard sessionManager.appendSession(session, toWorkgroup: workgroupID) else {
            sessionManager.closeSession(session)
            sessionManager.discardWorkgroupIfEmpty(workgroupID)
            connectionFailureMessage = "The terminal could not be added to its workgroup."
            return
        }
        iOSRouter.showTerminal(workgroupID: workgroupID)
        #else
        openWindow(
            id: "workspace",
            value: MacLiveSessionWorkspaceRouter.launchRequest(
                for: session,
                sessionManager: sessionManager
            )
        )
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

        #if os(macOS)
        openWindow(
            id: "workspace",
            value: MacWorkspaceLaunchRequest(
                initialPaneIntent: .ssh(serverID: server.id)
            )
        )
        #else

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
        #endif
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
        #if os(visionOS) || os(iOS)
        openVisionWorkgroup(preset, plan: restorationPlan)
        #else
        openMacWorkgroup(preset, plan: restorationPlan)
        #endif
    }

    #if os(visionOS) || os(iOS)
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
                #if os(visionOS)
                openWindow(id: "terminal", value: workgroupID)
                #else
                iOSRouter.showTerminal(workgroupID: workgroupID)
                #endif
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
                    Text(
                        validationMessage
                            ?? "Startup commands are saved unencrypted in app preferences. Do not include passwords, tokens, or other secrets. Commands run once, only after the terminal is connected and host trust succeeds."
                    )
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

    private var selectionHint: String {
        #if os(macOS)
        "Select to show connection details; double-click to connect"
        #else
        "Select to show connection details"
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            compactContent
            #else
            wideContent
            #endif
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.name), \(server.username) at \(server.host), \(server.authMethod.displayName)")
        .accessibilityHint(selectionHint)
        .contextMenu {
            Button {
                onToggleFavorite()
            } label: {
                Label(
                    server.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: server.isFavorite ? "heart.slash" : "heart"
                )
            }
            .accessibilityIdentifier(
                "connection-library-favorite-server-\(server.id.uuidString.lowercased())"
            )

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

    #if os(iOS)
    private var compactContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.colorTag.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    serverName
                    favoriteIndicator
                }

                Text(displayConnection)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: server.authMethod.icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(server.authMethod.displayName)

            lastConnectedLabel
                .lineLimit(1)

            actionsMenu
        }
    }
    #endif

    private var wideContent: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(server.colorTag.color)
                    .frame(width: 10, height: 10)

                serverName
                favoriteIndicator
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

            lastConnectedLabel
                .frame(width: 90, alignment: .leading)

            actionsMenu
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var serverName: some View {
        Text(server.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .accessibilityIdentifier(
                "connection-library-server-name-\(server.id.uuidString.lowercased())"
            )
    }

    @ViewBuilder
    private var favoriteIndicator: some View {
        if server.isFavorite {
            Image(systemName: "heart.fill")
                .font(.caption)
                .foregroundStyle(.pink)
                .accessibilityLabel("Favorite")
        }
    }

    private var lastConnectedLabel: some View {
        Group {
            if let lastConnected = server.lastConnected {
                Text(lastConnected, formatter: relativeDateFormatter)
            } else {
                Text("Never")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var actionsMenu: some View {
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
        .accessibilityLabel("Actions for \(server.name)")
        .accessibilityIdentifier(
            "connection-library-actions-server-\(server.id.uuidString.lowercased())"
        )
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
        .accessibilityHint("Select to show connection details")
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
