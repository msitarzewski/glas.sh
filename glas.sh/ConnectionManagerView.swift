//
//  ConnectionManagerView.swift
//  glas.sh
//
//  Main hub for managing server connections
//

import SwiftUI
import GlasSecretStore
import os

#if os(macOS)
import AppKit
import Observation

enum ConnectionLibraryMacColumnLayout {
    static let navigationMinimum: CGFloat = 240
    static let navigationIdeal: CGFloat = 340
    static let navigationMaximum: CGFloat = 480
    static let resultsMinimum: CGFloat = 320
    static let resultsIdeal: CGFloat = 510
    static let resultsMaximum: CGFloat = 760
    static let autosaveName = "sh.glas.connection-library.columns"
}
#endif

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
    #elseif os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var serverManager: ServerManager { sessionManager.serverManager }
    private var showsExplicitSearchAction: Bool {
        #if os(visionOS)
        true
        #elseif os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    @State private var selectedMode: ConnectionLibraryMode = .library
    @State private var selectedScope: ConnectionLibraryScope = .allConnections
    @State private var selectedServerID: UUID?
    @State private var selectedWorkgroupSelection: ConnectionWorkgroupSelection?
    @State private var selectedTailscaleDeviceID: String?
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfiguration?
    @State private var viewingServer: ServerConfiguration?
    @State private var searchQuery: String = ""
    @FocusState private var searchIsFocused: Bool
    @State private var pendingTrustSession: TerminalSession?
    @State private var pendingTrustChallenge: HostKeyTrustChallenge?
    @State private var connectionFailureMessage: String?
    @State private var connectingServerIDs: Set<UUID> = []
    @State private var pendingLegacyAlgorithmServer: ServerConfiguration?
    @State private var passwordPromptServer: ServerConfiguration?
    #if os(visionOS) || os(iOS)
    @State private var pendingPasswordWorkgroup: LayoutPreset?
    @State private var workgroupPasswordWasSaved = false
    @State private var isOpeningWorkgroup = false
    #endif
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
    #elseif os(macOS)
    @State private var connectionLibraryColumnVisibility:
        NavigationSplitViewVisibility = .all
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
            .accessibilityIdentifier("connection-library-confirm-delete-server")
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
        .sheet(item: $passwordPromptServer, onDismiss: {
            #if os(visionOS) || os(iOS)
            resumeWorkgroupAfterPasswordPrompt()
            #endif
        }) { server in
            ConnectionPasswordPromptSheet(
                server: server,
                savesPassword: serverManager.server(for: server.id) != nil
            ) { password in
                #if os(visionOS) || os(iOS)
                if pendingPasswordWorkgroup != nil {
                    guard let current = serverManager.server(for: server.id) else {
                        return "This saved connection is no longer available."
                    }
                    do {
                        try serverManager.updateServerOrThrow(current, password: password)
                        workgroupPasswordWasSaved = true
                        return nil
                    } catch {
                        return "The password could not be saved. \(error.localizedDescription)"
                    }
                }
                #endif
                return await submitPassword(password, for: server)
            }
        }
        .task {
            serverManager.loadServersIfNeeded()
            await refreshTailscaleConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tailscaleCredentialsDidChange)) { _ in
            tailscaleClient.invalidateCredentialState()
            selectedTailscaleDeviceID = nil
            Task {
                await refreshTailscaleConfiguration()
                if tailscaleIsConfigured, selectedMode == .network {
                    loadTailscaleDevices()
                }
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
        NavigationSplitView(
            columnVisibility: $connectionLibraryColumnVisibility
        ) {
            libraryNavigation(connectionLibrary: connectionLibrary)
        } content: {
            libraryResults(connectionLibrary: connectionLibrary)
                .navigationSplitViewColumnWidth(
                    min: ConnectionLibraryMacColumnLayout.resultsMinimum,
                    ideal: ConnectionLibraryMacColumnLayout.resultsIdeal,
                    max: ConnectionLibraryMacColumnLayout.resultsMaximum
                )
                .background {
                    MacConnectionLibrarySplitViewAutosave(
                        name: ConnectionLibraryMacColumnLayout.autosaveName
                    )
                }
        } detail: {
            libraryDetail(connectionLibrary: connectionLibrary)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if selectedMode == .workgroups {
                    Button {
                        workgroupEditorContext = .new()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New Workgroup")
                    .accessibilityLabel("New workgroup")
                    .accessibilityIdentifier("connection-library-add-workgroup")
                } else {
                        Button {
                            showingAddServer = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add Connection")
                        .accessibilityLabel("Add connection")
                        .accessibilityIdentifier(
                            "connection-library-add-server-toolbar"
                        )

                        Button {
                            openLocalTerminal()
                        } label: {
                            Image(systemName: "apple.terminal")
                        }
                        .help("Local Terminal")
                        .accessibilityLabel("Local terminal")
                        .accessibilityIdentifier(
                            "connection-library-local-terminal-toolbar"
                        )
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                settingsButton
            }
        }
        #elseif os(visionOS)
        TabView(selection: visionModeSelection(in: connectionLibrary)) {
            ForEach(connectionLibrary.availableModes) { mode in
                visionLibrary(
                    mode: mode,
                    connectionLibrary: connectionLibrary
                )
                    .tabItem {
                        Label(mode.title, systemImage: modeSystemImage(mode))
                            .accessibilityIdentifier(
                                "connection-library-mode-\(mode.rawValue)"
                            )
                    }
                    .tag(mode)
            }
        }
            .toolbar {
                ToolbarItem(placement: .bottomOrnament) {
                    Button {
                        showSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("connection-library-settings")
                }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { settingsButton }
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
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { settingsButton }
                }
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
        mode: ConnectionLibraryMode,
        connectionLibrary: ConnectionLibraryProjection
    ) -> some View {
        if mode == .collections {
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

    private func visionModeSelection(
        in connectionLibrary: ConnectionLibraryProjection
    ) -> Binding<ConnectionLibraryMode> {
        Binding(
            get: { selectedMode },
            set: { selectMode($0, in: connectionLibrary) }
        )
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
                    title: "All Connections",
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
        }
        .accessibilityIdentifier("connection-library-navigation")
        .listStyle(.sidebar)
        .navigationTitle("Connections")
        #if os(macOS)
        .navigationSplitViewColumnWidth(
            min: ConnectionLibraryMacColumnLayout.navigationMinimum,
            ideal: ConnectionLibraryMacColumnLayout.navigationIdeal,
            max: ConnectionLibraryMacColumnLayout.navigationMaximum
        )
        #else
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        #endif
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if iOSRouter.resumableWorkgroupID(in: sessionManager) != nil {
                HStack(spacing: 8) {
                    Button("Return to Terminal", systemImage: "arrow.uturn.backward.circle") {
                        resumeMostRecentTerminal()
                    }
                    .accessibilityIdentifier("connection-library-return-to-terminal")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .padding(8)
                .background(.bar)
            }
        }
        #endif
    }

    private var settingsButton: some View {
        Button {
            showSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Settings")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("connection-library-settings")
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
                        passwordPromptServer = config
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
                        isConnecting: connectingServerIDs.contains(server.id),
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
                    .onTapGesture {
                        selectedServerID = server.id
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedServerID = server.id
                            connectToServer(server)
                        }
                    )
                    #elseif os(iOS)
                    .onTapGesture {
                        selectedServerID = server.id
                    }
                    #else
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
        .searchFocused($searchIsFocused)
        .onSubmit(of: .search) {
            if let config = quickConnectConfig {
                passwordPromptServer = config
            }
        }
        .onChange(of: servers.map(\.id)) { _, visibleIDs in
            if let selectedServerID, !visibleIDs.contains(selectedServerID) {
                self.selectedServerID = nil
            }
        }
        .toolbar {
            #if !os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                if showsExplicitSearchAction {
                    Button {
                        searchIsFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("connection-library-search")
                }

                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add connection")
                .accessibilityIdentifier("connection-library-add-server-results")
            }
            #endif
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
        .searchFocused($searchIsFocused)
        .onChange(of: visibleSelections) { _, visibleSelections in
            if let selectedWorkgroupSelection,
               !visibleSelections.contains(selectedWorkgroupSelection) {
                self.selectedWorkgroupSelection = nil
            }
        }
        .toolbar {
            #if !os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                if showsExplicitSearchAction {
                    Button {
                        searchIsFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                    .accessibilityIdentifier("connection-library-search")
                }

                #if !os(macOS)
                Button {
                    editCurrentSessionsAsWorkgroup()
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
                .disabled(currentSavedSessionIntents.isEmpty)
                .accessibilityLabel("Save current SSH sessions as workgroup")
                .accessibilityIdentifier("connection-library-save-current-workgroup")
                #endif

                Button {
                    workgroupEditorContext = .new()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New workgroup")
                .accessibilityIdentifier("connection-library-add-workgroup")
            }
            #endif
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
            let sftpSession = sessionManager.sessions.first {
                $0.server.id == server.id && $0.state == .connected
            }
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
                .accessibilityIdentifier(
                    "connection-library-detail-server-\(server.id.uuidString.lowercased())"
                )

                serverDetailActions(server: server, sftpSession: sftpSession)
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .padding()
                .background(.bar)
            }
            .navigationTitle(server.name)
        } else if connectionLibrary.servers.isEmpty {
            ContentUnavailableView {
                Label("No Connections", systemImage: "server.rack")
            } description: {
                #if os(macOS)
                Text("Add a saved host or open a local terminal to begin.")
                #else
                Text("Add a saved host to begin.")
                #endif
            } actions: {
                #if os(macOS)
                Button("Local Terminal", systemImage: "apple.terminal") {
                    openLocalTerminal()
                }
                .accessibilityIdentifier("connection-library-local-terminal-empty-detail")
                #endif

                Button("Add Connection", systemImage: "plus") {
                    showingAddServer = true
                }
                .accessibilityIdentifier("connection-library-add-server-empty-detail")
            }
            .accessibilityIdentifier("connection-library-detail-empty-server")
        } else {
            Text("Select a connection to get started.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("connection-library-detail-empty-server")
        }
    }

    private func serverDetailSecondaryActions(server: ServerConfiguration) -> some View {
        HStack {
            Button("Edit", systemImage: "pencil") { editingServer = server }
            Button("Details", systemImage: "info.circle") { viewingServer = server }
        }
    }

    private func serverDetailPrimaryActions(server: ServerConfiguration, sftpSession: TerminalSession?) -> some View {
        HStack {
            Button("SFTP", systemImage: "folder") {
                guard let session = sftpSession else { return }
                #if os(iOS)
                iOSRouter.showSFTP(sessionID: session.id)
                #else
                openWindow(id: "sftp", value: SFTPBrowserContext(sessionID: session.id))
                #endif
            }
            .disabled(sftpSession == nil)
            .help(sftpSession == nil ? "Connect to this host to browse files using SFTP" : "Browse remote files using SFTP")
            .accessibilityIdentifier("connection-library-sftp-server-\(server.id.uuidString.lowercased())")
            Button("Connect", systemImage: "terminal") { connectToServer(server) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("connection-library-connect-server-\(server.id.uuidString.lowercased())")
        }
    }

    @ViewBuilder
    private func serverDetailActions(server: ServerConfiguration, sftpSession: TerminalSession?) -> some View {
        #if os(macOS)
        HStack {
            serverDetailSecondaryActions(server: server)
            Spacer()
            serverDetailPrimaryActions(server: server, sftpSession: sftpSession)
        }
        #else
        ViewThatFits(in: .horizontal) {
            HStack {
                serverDetailSecondaryActions(server: server).fixedSize()
                Spacer()
                serverDetailPrimaryActions(server: server, sftpSession: sftpSession).fixedSize()
            }
            VStack(spacing: 12) {
                HStack {
                    serverDetailSecondaryActions(server: server)
                    Spacer()
                }
                HStack {
                    Spacer()
                    serverDetailPrimaryActions(server: server, sftpSession: sftpSession)
                }
            }
        }
        #endif
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
                #if os(iOS)
                HStack {
                    Spacer()
                    Button("Resume Terminal", systemImage: "arrow.uturn.backward.circle") {
                        resumeLiveWorkgroup(workgroup.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "connection-library-resume-workgroup-\(workgroup.id.uuidString.lowercased())"
                    )
                }
                .labelStyle(.titleAndIcon)
                .padding()
                .background(.bar)
                #endif
            }
            .navigationTitle(workgroup.name)
            .accessibilityIdentifier(
                "connection-library-detail-live-workgroup-\(workgroup.id.uuidString.lowercased())"
            )
        } else if let preset = selectedWorkgroup(in: connectionLibrary) {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.largeTitle)
                            .foregroundStyle(preset.colorTag.color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.name)
                                .font(.title2.bold())
                                .textSelection(.enabled)
                            Text("\(preset.workspaceLayout?.tabs.count ?? preset.sessionIntents.count) tabs · \(preset.sessionIntents.count) terminals · \(preset.sessionIntents.filter { $0.startupCommand != nil }.count) startup commands")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(preset.sessionIntents.enumerated()), id: \.offset) { index, intent in
                    Section {
                        workgroupIntentRow(intent, index: index, preset: preset)
                    } header: {
                        if index == 0 {
                            Text("Startup Plan")
                        }
                    } footer: {
                        if index == preset.sessionIntents.count - 1 {
                            Text("All terminals start when you open this Workgroup. Commands run independently, without waiting for another tab.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("Edit", systemImage: "pencil") {
                        workgroupEditorContext = .edit(preset)
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Edit Workgroup")
                    .accessibilityIdentifier("connection-library-edit-workgroup-\(preset.id.uuidString.lowercased())")
                    Spacer()
                    Button("Open Workgroup", systemImage: "rectangle.stack") {
                        openWorkgroup(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(.defaultAction)
                    .help("Open Workgroup")
                    .accessibilityIdentifier(
                        "connection-library-open-workgroup-\(preset.id.uuidString.lowercased())"
                    )
                }
                .buttonStyle(.bordered)
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

    private func workgroupIntentRow(
        _ intent: LayoutPreset.SessionIntent, index: Int, preset: LayoutPreset
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(intent.label ?? defaultIntentLabel(intent))
                        .font(.headline)
                    Label(workgroupIntentDestination(intent), systemImage: intent.kind == .local ? "apple.terminal" : "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let layout = preset.workspaceLayout,
                       let tabIndex = layout.tabs.firstIndex(where: { workgroupNode($0.root, contains: index) }) {
                        Text("Tab \(tabIndex + 1)\(layout.tabs[tabIndex].label.map { " · " + $0 } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if intent.kind == .local {
                VStack(alignment: .leading, spacing: 6) {
                    Label(intent.localDirectory ?? "App default working directory", systemImage: "folder")
                    Label(intent.localShell ?? "App default shell", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                #if !os(macOS)
                Label("Local terminals require macOS", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            if let command = intent.startupCommand {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Startup command: \(command)")
            } else {
                Text("Interactive shell · No startup command")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workgroup-terminal-plan-\(index)")
    }

    private func workgroupIntentDestination(_ intent: LayoutPreset.SessionIntent) -> String {
        guard intent.kind == .ssh else { return "Local terminal" }
        guard let id = intent.serverID, let server = serverManager.server(for: id) else {
            return "Missing SSH connection — edit this Workgroup to choose a host"
        }
        return "\(server.username)@\(server.host):\(server.port)"
    }

    private func workgroupNode(_ node: LayoutPreset.WorkspaceLayout.Node, contains index: Int) -> Bool {
        switch node {
        case .session(let candidate): return candidate == index
        case let .split(_, _, first, second):
            return workgroupNode(first, contains: index) || workgroupNode(second, contains: index)
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
                .formStyle(.grouped)
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
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
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
                                password: password,
                                initialTerminalPresentation: { pendingSession in
                                    presentTerminalWindow(for: pendingSession)
                                }
                            )
                            if launch.session.state == .connected {
                                if !launch.session.didRequestInitialTerminalPresentation {
                                    presentTerminalWindow(for: launch.session)
                                }
                            } else if let challenge = launch.session.pendingHostKeyChallenge {
                                stageHostKeyChallenge(
                                    challenge,
                                    for: launch.session
                                )
                            } else if case .error(let message) = launch.session.state {
                                if !launch.session.didRequestInitialTerminalPresentation {
                                    connectionFailureMessage = message
                                    sessionManager.closeSession(launch.session)
                                }
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

    private func refreshTailscaleConfiguration() async {
        tailscaleIsConfigured = await TailscaleClient.storedCredentialPresence() == .configured
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
        #elseif os(macOS)
        openSettings()
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

        guard !connectingServerIDs.contains(server.id) else { return }
        connectingServerIDs.insert(server.id)

        Task { @MainActor in
            defer { connectingServerIDs.remove(server.id) }

            let launch: AuthorizedSessionLaunch
            do {
                launch = try await sessionManager.createAuthorizedSession(
                    for: server,
                    settingsManager: settingsManager,
                    initialTerminalPresentation: { pendingSession in
                        presentTerminalWindow(for: pendingSession)
                    }
                )
            } catch {
                if let promptServer = Self.targetPasswordPromptServer(
                    for: error,
                    requestedServerID: server.id
                ) {
                    passwordPromptServer = promptServer
                } else {
                    connectionFailureMessage = Self.connectionFailureMessage(
                        base: error.localizedDescription,
                        diagnostics: nil,
                        host: server.host
                    )
                }
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
                if !session.didRequestInitialTerminalPresentation {
                    presentTerminalWindow(for: session)
                }
                return
            }

            if case .error(let message) = session.state {
                if session.didRequestInitialTerminalPresentation {
                    return
                }
                connectionFailureMessage = Self.connectionFailureMessage(
                    base: message,
                    diagnostics: session.lastConnectionDiagnostics,
                    host: server.host
                )
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

    static func targetPasswordPromptServer(
        for error: Error,
        requestedServerID: UUID
    ) -> ServerConfiguration? {
        guard let sessionError = error as? SessionOpenError,
              case .missingPassword(let server, .target) = sessionError,
              server.id == requestedServerID else {
            return nil
        }
        return server
    }

    static func connectionFailureMessage(
        base: String,
        diagnostics: String?,
        host: String
    ) -> String {
        var sections = [base]
        if let diagnostics,
           !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(diagnostics)
        }
        if isLikelyLocalNetworkHost(host) {
            sections.append(
                "Local Network access may be required for this host. In System Settings, open Privacy & Security > Local Network, allow glas.sh, then try again."
            )
        }
        return sections.joined(separator: "\n\n")
    }

    static func isLikelyLocalNetworkHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        if host.contains(":") {
            let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            return address == "::1"
                || address.hasPrefix("fc")
                || address.hasPrefix("fd")
                || address.hasPrefix("fe8")
                || address.hasPrefix("fe9")
                || address.hasPrefix("fea")
                || address.hasPrefix("feb")
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = octets.compactMap { Int($0) }
        guard octets.count == 4,
              values.count == 4,
              values.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        return values[0] == 10
            || values[0] == 127
            || (values[0] == 169 && values[1] == 254)
            || (values[0] == 172 && (16...31).contains(values[1]))
            || (values[0] == 192 && values[1] == 168)
    }

    private func submitPassword(
        _ password: String,
        for server: ServerConfiguration
    ) async -> String? {
        if let savedServer = serverManager.server(for: server.id) {
            do {
                try serverManager.updateServerOrThrow(savedServer, password: password)
                connectToServer(savedServer)
                return nil
            } catch {
                return "The password could not be saved in Keychain. \(error.localizedDescription)"
            }
        }

        do {
            let launch = try await sessionManager.createTransientAuthorizedSession(
                for: server,
                settingsManager: settingsManager,
                password: password,
                initialTerminalPresentation: { pendingSession in
                    presentTerminalWindow(for: pendingSession)
                }
            )
            if launch.session.state == .connected {
                if !launch.session.didRequestInitialTerminalPresentation {
                    presentTerminalWindow(for: launch.session)
                }
                return nil
            }
            if let challenge = launch.session.pendingHostKeyChallenge {
                stageHostKeyChallenge(challenge, for: launch.session)
                return nil
            }
            if case .error(let message) = launch.session.state {
                if launch.session.didRequestInitialTerminalPresentation {
                    return nil
                }
                sessionManager.closeSession(launch.session)
                return message
            }
            if launch.session.didRequestInitialTerminalPresentation {
                return nil
            }
            sessionManager.closeSession(launch.session)
            return "The server did not establish a terminal session."
        } catch {
            return error.localizedDescription
        }
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
                if !session.didRequestInitialTerminalPresentation {
                    presentTerminalWindow(for: session)
                }
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
    private func resumeWorkgroupAfterPasswordPrompt() {
        guard let preset = pendingPasswordWorkgroup else { return }
        let shouldContinue = workgroupPasswordWasSaved
        pendingPasswordWorkgroup = nil
        workgroupPasswordWasSaved = false
        guard shouldContinue else { return }
        openVisionWorkgroup(preset, plan: LayoutRestorationPlan(
            preset: preset, availableServers: serverManager.servers
        ))
    }

    private func openVisionWorkgroup(_ preset: LayoutPreset, plan: LayoutRestorationPlan) {
        guard !isOpeningWorkgroup, passwordPromptServer == nil else { return }
        // Resolve credentials for the entire recipe before opening any sessions.
        // This also finds missing jump-host passwords through the shared policy.
        for target in plan.targets {
            guard let server = target.server else { continue }
            do {
                _ = try sessionManager.prepareConnection(for: server)
            } catch SessionOpenError.missingPassword(let missingServer, _) {
                pendingPasswordWorkgroup = preset
                workgroupPasswordWasSaved = false
                passwordPromptServer = missingServer
                return
            } catch {
                // The launch path below reports non-password failures per pane.
                continue
            }
        }
        isOpeningWorkgroup = true
        Task { @MainActor in
            defer { isOpeningWorkgroup = false }
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
        // Keep every pane's position even when a saved endpoint is missing;
        // its native pane offers recovery without rearranging the workspace.
        // Legacy algorithm consent still requires the direct connection flow.
        if preset.sessionIntents.contains(where: { intent in
            serverManager.servers.contains { $0.id == intent.serverID && $0.legacyAlgorithmsEnabled }
        }) {
            connectionFailureMessage = "A connection in this Workgroup uses legacy algorithms. Open that connection directly to review its security settings."
            return
        }
        do {
            try MacWorkgroupLauncher.launch(preset: preset) { request in
                openWindow(id: "workspace", value: request)
            }
        } catch {
            connectionFailureMessage = error.localizedDescription
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

struct WorkgroupEditorContext: Identifiable {
    let id = UUID()
    let original: LayoutPreset?
    let name: String
    let colorTag: ServerColorTag
    let sessionIntents: [LayoutPreset.SessionIntent]
    var workspaceLayout: LayoutPreset.WorkspaceLayout? = nil

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
            sessionIntents: preset.sessionIntents,
            workspaceLayout: preset.workspaceLayout
        )
    }

    static func duplicate(_ preset: LayoutPreset) -> Self {
        let copyName = String("\(preset.name) Copy".prefix(LayoutPreset.maximumNameLength))
        return Self(
            original: nil,
            name: copyName,
            colorTag: preset.colorTag,
            sessionIntents: preset.sessionIntents,
            workspaceLayout: preset.workspaceLayout
        )
    }
}

private extension ToolbarItemPlacement {
    static var workgroupActions: Self {
        #if os(visionOS)
        .bottomOrnament
        #elseif os(iOS)
        .bottomBar
        #else
        .primaryAction
        #endif
    }
}

struct WorkgroupTabDraft: Identifiable {
    let id: UUID
    var kind: LayoutPreset.SessionIntent.Kind
    var serverID: UUID?
    var label: String
    var startupCommand: String
    var localShell: String = ""
    var localDirectory: String = ""

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
        localShell = intent.localShell ?? ""
        localDirectory = intent.localDirectory ?? ""
    }

    var intent: LayoutPreset.SessionIntent {
        LayoutPreset.SessionIntent(
            kind: kind,
            serverID: kind == .ssh ? serverID : nil,
            label: label,
            startupCommand: startupCommand,
            localShell: kind == .local ? localShell : nil,
            localDirectory: kind == .local ? localDirectory : nil
        )
    }

    func validationMessage(servers: [ServerConfiguration]) -> String? {
        if kind == .ssh {
            guard let serverID, servers.contains(where: { $0.id == serverID }) else {
                return "Choose a saved connection."
            }
        }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= LayoutPreset.SessionIntent.maximumLabelLength,
              !label.utf8.contains(0) else { return "Enter a label no longer than \(LayoutPreset.SessionIntent.maximumLabelLength) characters without null characters." }
        let command = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty, TerminalStartupCommandTicket(command: command) == nil {
            return "Use a single-line startup command no larger than 4 KB."
        }
        if kind == .local {
            for path in [localShell, localDirectory] {
                let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && (!(value.hasPrefix("/") || value == "~" || value.hasPrefix("~/")) || value.utf8.contains(0)) {
                    return "Use an absolute path or ~ for the shell and working directory."
                }
            }
        }
        return nil
    }
}

struct WorkgroupEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let context: WorkgroupEditorContext
    let servers: [ServerConfiguration]
    let onSave: (LayoutPreset) -> Void

    @State private var name: String
    @State private var colorTag: ServerColorTag
    @State private var tabs: [WorkgroupTabDraft]
    @State private var selectedTabID: UUID?
    @State private var editingTab: WorkgroupTabDraft?
    @State private var pendingDeletionIDs: [UUID] = []
    @State private var showingTabDeletion = false

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

    @FocusState private var nameIsFocused: Bool

    var body: some View {
        NavigationStack {
            platformForm
                .navigationTitle(context.original == nil ? "New Workgroup" : "Edit Workgroup")
                .toolbar {
                    #if !os(macOS)
                    ToolbarItemGroup(placement: .workgroupActions) { tabListControls }
                    #endif
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(validationMessage != nil)
                            #if os(macOS)
                            .keyboardShortcut(.defaultAction)
                            #endif
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 900,
               minHeight: 620, idealHeight: 720, maxHeight: 820)
        #endif
        .onAppear { nameIsFocused = true }
        .sheet(item: $editingTab) { draft in
            WorkgroupTabEditorView(
                draft: draft,
                isNew: !tabs.contains(where: { $0.id == draft.id }),
                canDelete: canChangeStructure,
                servers: servers,
                onSave: { updated in
                    if let index = tabs.firstIndex(where: { $0.id == updated.id }) {
                        tabs[index] = updated
                    } else if canChangeStructure, tabs.count < LayoutPreset.maximumSessionCount {
                        tabs.append(updated)
                    }
                    selectedTabID = updated.id
                },
                onDelete: { deleteTabs([draft.id]) }
            )
        }
        .confirmationDialog("Delete \(pendingDeletionIDs.count == 1 ? "Tab" : "Tabs")?", isPresented: $showingTabDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteTabs(pendingDeletionIDs)
                pendingDeletionIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeletionIDs = [] }
        } message: {
            Text("This removes the selected tabs from this draft. The saved Workgroup is unchanged until you save.")
        }
    }

    @ViewBuilder
    private var platformForm: some View {
        #if os(macOS)
        Form { formSections }
            .formStyle(.grouped)
        #else
        Form { formSections }
        #endif
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Workgroup") {
            LabeledContent {
                TextField("Name", text: $name)
                    .terminalTextInputDefaults()
                    .focused($nameIsFocused)
                    .serverFormTextFieldPresentation()
                    .onSubmit { nameIsFocused = false }
            } label: {
                fieldLabel("Name", required: true)
            }

            #if os(macOS)
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
                                        Circle().strokeBorder(.primary, lineWidth: 2).padding(2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tag.rawValue) color")
                        .accessibilityAddTraits(colorTag == tag ? .isSelected : [])
                    }
                }
                .serverFormControlPresentation()
            }
            #else
            Picker("Color", selection: $colorTag) {
                ForEach(ServerColorTag.allCases, id: \.self) { tag in
                    Label(tag.rawValue.capitalized, systemImage: "circle.fill")
                        .foregroundStyle(tag.color)
                        .tag(tag)
                }
            }
            #endif
        }

        Section {
            #if os(macOS)
            tabTable
                .frame(height: min(360, max(220, CGFloat(tabs.count) * 36 + 32)))
            #else
            ForEach(tabs) { tab in
                Button { editTab(tab.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tab.kind == .local ? "apple.terminal" : "network")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tabTitle(tab)).font(.headline)
                            if let group = layoutGroup(for: tab) {
                                Text(group).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(tab.startupCommand.isEmpty ? "Interactive shell" : tab.startupCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .moveDisabled(!canChangeStructure)
                .deleteDisabled(!canChangeStructure)
            }
            .onMove { source, destination in
                guard canChangeStructure else { return }
                tabs.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { indices in
                guard canChangeStructure else { return }
                requestDeletion(indices.map { tabs[$0].id })
            }
            #endif
        } header: {
            HStack {
                Text("\(canChangeStructure ? "Tabs" : "Terminals in saved layout") · \(tabs.count)")
                #if os(macOS)
                Spacer()
                ControlGroup { tabListControls }
                    .controlSize(.small)
                    .accessibilityIdentifier("workgroup-tab-controls")
                #endif
            }
        } footer: {
            if !canChangeStructure {
                Text("Split layout preserved. Edit terminal settings here; rearrange or remove panes in the Mac workspace, then save it again.")
            }
        }

        Section {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Startup commands run once when you open the Workgroup. Do not include passwords or tokens; commands are saved with the Workgroup.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ title: String, required: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var canChangeStructure: Bool { context.workspaceLayout == nil }

    #if os(macOS)
    private var tabTable: some View {
        Table(of: WorkgroupTabDraft.self, selection: $selectedTabID) {
            TableColumn("Order") { tab in
                HStack(spacing: 6) {
                    Image(systemName: canChangeStructure ? "line.3.horizontal" : "lock")
                        .foregroundStyle(.tertiary)
                    Text("\((tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1)")
                        .monospacedDigit()
                }
            }.width(55)
            TableColumn("Label") { tab in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tabTitle(tab)).lineLimit(1)
                    if let group = layoutGroup(for: tab) {
                        Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.width(min: 120, ideal: 160)
            TableColumn("Type") { tab in
                Label(tab.kind == .local ? "Local" : "SSH", systemImage: tab.kind == .local ? "apple.terminal" : "network")
            }.width(75)
            TableColumn("Startup command") { tab in
                Text(tab.startupCommand.isEmpty ? "Interactive shell" : tab.startupCommand)
                    .font(.body.monospaced())
                    .foregroundStyle(tab.startupCommand.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .help(tab.startupCommand)
            }.width(min: 150, ideal: 240)
        } rows: {
            ForEach(tabs) { tab in
                if canChangeStructure {
                    TableRow(tab).draggable(tab.id.uuidString)
                } else {
                    TableRow(tab)
                }
            }
            .dropDestination(for: String.self) { destination, payloads in
                guard canChangeStructure, let payload = payloads.first,
                      let id = UUID(uuidString: payload),
                      let source = tabs.firstIndex(where: { $0.id == id }) else { return }
                tabs.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                selectedTabID = id
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Edit Tab", systemImage: "pencil") { editTab(id) }
                Button("Move Up", systemImage: "arrow.up") { moveTab(id, by: -1) }
                    .disabled(!canChangeStructure || tabs.first?.id == id)
                Button("Move Down", systemImage: "arrow.down") { moveTab(id, by: 1) }
                    .disabled(!canChangeStructure || tabs.last?.id == id)
                Button("Delete Tab", systemImage: "trash", role: .destructive) { requestDeletion([id]) }
                    .disabled(!canChangeStructure)
            }
        } primaryAction: { ids in
            if let id = ids.first { editTab(id) }
        }
        .accessibilityIdentifier("workgroup-tabs-table")
        .accessibilityHint("Drag to reorder. Double-click a tab to edit it.")
    }
    #endif

    @ViewBuilder private var tabListControls: some View {
            Button("Add Tab", systemImage: "plus") { beginAddingTab() }
                .help("Add Tab")
                .disabled(!canChangeStructure || tabs.count >= LayoutPreset.maximumSessionCount)
                .accessibilityIdentifier("workgroup-add-tab")
            #if os(macOS)
            Button("Delete Tab", systemImage: "minus") {
                if let id = selectedTabID { requestDeletion([id]) }
            }
            .help("Delete selected tab")
            .accessibilityIdentifier("workgroup-delete-tab")
            .disabled(!canChangeStructure || selectedTabID == nil)
            Button("Edit Tab", systemImage: "pencil") {
                if let id = selectedTabID { editTab(id) }
            }
            .disabled(selectedTabID == nil)
            .help("Edit selected tab")
            .accessibilityIdentifier("workgroup-edit-tab")
            #else
            if canChangeStructure { EditButton() }
            #endif
    }

    private func tabTitle(_ tab: WorkgroupTabDraft) -> String {
        let label = tab.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        if tab.kind == .local { return "Local Terminal" }
        return servers.first(where: { $0.id == tab.serverID })?.name ?? "Missing Connection"
    }

    private func editTab(_ id: UUID) {
        selectedTabID = id
        editingTab = tabs.first(where: { $0.id == id })
    }

    private func layoutGroup(for tab: WorkgroupTabDraft) -> String? {
        guard let layout = context.workspaceLayout,
              let terminalIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }
        func contains(_ node: LayoutPreset.WorkspaceLayout.Node) -> Bool {
            switch node {
            case .session(let index): return index == terminalIndex
            case let .split(_, _, first, second): return contains(first) || contains(second)
            }
        }
        guard let index = layout.tabs.firstIndex(where: { contains($0.root) }) else { return nil }
        return "Tab \(index + 1)\(layout.tabs[index].label.map { " · " + $0 } ?? "")"
    }

    private func requestDeletion(_ ids: [UUID]) {
        guard canChangeStructure, !ids.isEmpty else { return }
        pendingDeletionIDs = ids
        showingTabDeletion = true
    }

    private func beginAddingTab() {
        guard canChangeStructure, tabs.count < LayoutPreset.maximumSessionCount else { return }
        #if os(macOS)
        editingTab = WorkgroupTabDraft(kind: .local)
        #else
        editingTab = WorkgroupTabDraft(kind: .ssh, serverID: servers.first?.id)
        #endif
    }

    private func deleteTabs(_ ids: [UUID]) {
        guard canChangeStructure else { return }
        tabs.removeAll { ids.contains($0.id) }
        if let selectedTabID, ids.contains(selectedTabID) { self.selectedTabID = tabs.first?.id }
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
            if let message = tab.validationMessage(servers: servers) {
                return "Tab \(index + 1): \(message)"
            }
        }
        return nil
    }

    private func moveTab(_ id: UUID, by offset: Int) {
        guard canChangeStructure, let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard tabs.indices.contains(destination) else { return }
        tabs.swapAt(source, destination)
    }

    private func save() {
        guard validationMessage == nil else { return }
        let intents = tabs.map(\.intent)
        var preset = LayoutPreset(
            id: context.original?.id ?? UUID(),
            name: normalizedName,
            colorTag: colorTag,
            sessionIntents: intents,
            createdAt: context.original?.createdAt ?? Date(),
            lastUsed: context.original?.lastUsed
        )
        preset.workspaceLayout = context.workspaceLayout
        onSave(preset)
        dismiss()
    }
}

struct WorkgroupTabEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkgroupTabDraft
    @State private var showingDeleteConfirmation = false
    let isNew: Bool
    let canDelete: Bool
    let servers: [ServerConfiguration]
    let onSave: (WorkgroupTabDraft) -> Void
    let onDelete: () -> Void
    private let includesLocalChoice: Bool

    init(
        draft: WorkgroupTabDraft,
        isNew: Bool,
        canDelete: Bool,
        servers: [ServerConfiguration],
        onSave: @escaping (WorkgroupTabDraft) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.canDelete = canDelete
        self.servers = servers
        self.onSave = onSave
        self.onDelete = onDelete
        #if os(macOS)
        includesLocalChoice = true
        #else
        includesLocalChoice = draft.kind == .local
        #endif
    }

    var body: some View {
        NavigationStack {
            platformForm
                .navigationTitle(isNew ? "Add Tab" : "Edit Tab")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isNew ? "Add" : "Save") {
                            guard draft.validationMessage(servers: servers) == nil else { return }
                            onSave(draft)
                            dismiss()
                        }
                        .disabled(draft.validationMessage(servers: servers) != nil)
                        #if os(macOS)
                        .keyboardShortcut(.defaultAction)
                        #endif
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 680,
               minHeight: 420, idealHeight: 540, maxHeight: 720)
        #endif
        .confirmationDialog("Delete this tab?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Tab", role: .destructive) {
                guard canDelete else { return }
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tab will be removed when you save the Workgroup.")
        }
    }

    @ViewBuilder private var platformForm: some View {
        #if os(macOS)
        Form { sections }.formStyle(.grouped)
        #else
        Form { sections }
        #endif
    }

    @ViewBuilder private var sections: some View {
        Section("Connection") {
            LabeledContent("Type") {
                Picker("Type", selection: $draft.kind) {
                    if includesLocalChoice {
                        Text("Local").tag(LayoutPreset.SessionIntent.Kind.local)
                    }
                    Text("SSH").tag(LayoutPreset.SessionIntent.Kind.ssh)
                }
                .pickerStyle(.segmented)
                .serverFormControlPresentation()
                .onChange(of: draft.kind) { _, kind in
                    draft.serverID = kind == .ssh ? (draft.serverID ?? servers.first?.id) : nil
                }
            }
            if draft.kind == .ssh {
                LabeledContent {
                    Picker("Connection", selection: $draft.serverID) {
                        Text("Choose a saved connection").tag(UUID?.none)
                        ForEach(servers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                        if let serverID = draft.serverID,
                           !servers.contains(where: { $0.id == serverID }) {
                            Text("Missing Connection").tag(Optional(serverID))
                        }
                    }
                    .serverFormControlPresentation()
                } label: {
                    fieldLabel("Connection", required: true)
                }
            }
            textField("Label", text: $draft.label)
        }
        Section {
            textField("Startup command", text: $draft.startupCommand, monospaced: true)
            if draft.kind == .local {
                textField("Shell", text: $draft.localShell, prompt: "App default")
                textField("Working directory", text: $draft.localDirectory, prompt: "App default")
            }
        } header: {
            Text("Startup")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("The command runs once when you open the Workgroup. Do not include passwords or tokens; commands are saved with the Workgroup.")
                #if !os(macOS)
                if draft.kind == .local {
                    Text("Local terminals open on Mac. These settings are preserved when you save on Vision Pro or iPad.")
                }
                #endif
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        if let message = draft.validationMessage(servers: servers) {
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !isNew {
            Section {
                Button("Delete Tab", systemImage: "trash", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(!canDelete)
            } footer: {
                if !canDelete {
                    Text("This terminal belongs to a saved split layout. Open the Workgroup on Mac to remove it, then save the updated workspace.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func fieldLabel(_ title: String, required: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func textField(
        _ title: String,
        text: Binding<String>,
        prompt: String = "",
        monospaced: Bool = false
    ) -> some View {
        LabeledContent {
            TextField(title, text: text, prompt: Text(prompt))
                .terminalTextInputDefaults()
                .font(monospaced ? .body.monospaced() : .body)
                .serverFormTextFieldPresentation()
        } label: {
            fieldLabel(title)
        }
    }
}

private struct ServerListRow: View {
    let server: ServerConfiguration
    let session: TerminalSession?
    let isConnecting: Bool
    let onView: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void

    private var rawConnection: String {
        "\(server.username)@\(server.host):\(server.port)"
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
        ViewThatFits(in: .horizontal) {
            compactContent
            minimalContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            } else {
                Image(systemName: server.authMethod.icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(server.authMethod.displayName)
            }

            lastConnectedLabel
                .lineLimit(1)

        }
    }

    private var minimalContent: some View {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting")
            }
        }
    }

    private var serverName: some View {
        Text(server.name)
            .font(.headline)
            .lineLimit(1)
            .accessibilityLabel(server.name)
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

}

#if os(macOS)
private struct MacConnectionLibrarySplitViewAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.autosaveName = name
        view.applyAutosaveName()
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        nsView.autosaveName = name
        nsView.applyAutosaveName()
    }

    @MainActor
    final class AttachmentView: NSView {
        var autosaveName = ""

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyAutosaveName()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAutosaveName()
        }

        func applyAutosaveName() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var candidate = self.superview
                while let view = candidate {
                    if let splitView = view as? NSSplitView {
                        if splitView.autosaveName != self.autosaveName {
                            splitView.autosaveName = self.autosaveName
                        }
                        return
                    }
                    candidate = view.superview
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
#endif

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
                    let initialGeometry = settingsManager.initialTerminalGeometry(for: server)
                    infoRow(
                        "Initial Size",
                        "\(initialGeometry.columns) × \(initialGeometry.rows)"
                            + (server.initialTerminalColumns == nil ? " (App Default)" : " (Connection)")
                    )
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

// MARK: - Connection Password Prompt

struct ConnectionPasswordPromptSheet: View {
    let server: ServerConfiguration
    let savesPassword: Bool
    let onSubmit: @MainActor (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failureMessage: String?
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?
    @FocusState private var passwordIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Password Required")
                        .font(.title2.weight(.semibold))

                    Text(promptMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecureField("Password", text: $password)
                        .textContentType(.init(rawValue: ""))
                        .textFieldStyle(.roundedBorder)
                        .focused($passwordIsFocused)
                        .disabled(isSubmitting)
                        .onSubmit(submit)
                        .accessibilityIdentifier("connection-password-prompt.password")

                    if savesPassword {
                        Label("This password will be stored securely in Keychain.", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let failureMessage {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connection-password-prompt.error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    password = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button(actionTitle) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isSubmitting)
                .accessibilityIdentifier("connection-password-prompt.submit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(width: 480)
        .onAppear {
            passwordIsFocused = true
        }
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            password = ""
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var promptMessage: String {
        let endpoint = "\(server.username)@\(server.host):\(server.port)"
        if savesPassword {
            return "Enter the password for \(endpoint) to save it and connect."
        }
        return "Enter the password for \(endpoint) to connect."
    }

    private var actionTitle: String {
        if isSubmitting {
            return savesPassword ? "Saving…" : "Connecting…"
        }
        return savesPassword ? "Save & Connect" : "Connect"
    }

    private func submit() {
        guard !password.isEmpty, !isSubmitting else { return }
        failureMessage = nil
        isSubmitting = true
        let submittedPassword = password
        submissionTask = Task { @MainActor in
            let failure = await onSubmit(submittedPassword)
            guard !Task.isCancelled else { return }
            isSubmitting = false
            if let failure {
                failureMessage = failure
                passwordIsFocused = true
            } else {
                password = ""
                dismiss()
            }
            submissionTask = nil
        }
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
