//
//  VisionTerminalWorkgroupView.swift
//  glas.sh
//
//  Platform terminal tabs backed by SessionManager workgroups.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(visionOS) || os(iOS)
struct VisionTerminalWorkgroupView: View {
    let workgroupID: UUID

    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    @Environment(IOSAppRouter.self) private var iOSRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var selectedSessionID: UUID?
    @State private var showingSavedHostPicker = false
    @State private var openingServerID: UUID?
    @State private var connectionFailureMessage: String?
    @State private var didCloseWorkgroup = false

    var body: some View {
        Group {
            if let workgroup = sessionManager.workgroup(for: workgroupID) {
                let sessions = liveSessions(in: workgroup)
                if sessions.isEmpty {
                    missingWorkgroupContent
                } else {
                    terminalTabs(workgroup: workgroup, sessions: sessions)
                }
            } else {
                missingWorkgroupContent
            }
        }
        .sheet(isPresented: $showingSavedHostPicker) {
            savedHostPicker
        }
        .alert("Unable to Open Terminal", isPresented: connectionFailureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionFailureMessage ?? "The saved host could not be opened.")
        }
        .onAppear {
            sessionManager.serverManager.loadServersIfNeeded()
            synchronizeSelection()
        }
        .onChange(of: liveSelectedSessionID) { _, newSelection in
            if selectedSessionID != newSelection {
                selectedSessionID = newSelection
            }
        }
        .onChange(of: selectedSessionID) { _, newSelection in
            guard let newSelection else { return }
            sessionManager.selectSession(newSelection, inWorkgroup: workgroupID)
        }
        .focusedSceneValue(
            \.platformNewTerminalAction,
            PlatformNewTerminalAction(title: "New Terminal Tab") {
                showingSavedHostPicker = true
            }
        )
    }

    private var liveSelectedSessionID: UUID? {
        sessionManager.workgroup(for: workgroupID)?.selectedSessionID
    }

    private var connectionFailureBinding: Binding<Bool> {
        Binding(
            get: { connectionFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    connectionFailureMessage = nil
                }
            }
        )
    }

    private var savedHostPicker: some View {
        NavigationStack {
            Group {
                if sessionManager.serverManager.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Hosts", systemImage: "server.rack")
                    } description: {
                        Text("Add a server in Connections before opening another terminal tab.")
                    } actions: {
                        Button("Open Connections", systemImage: "sidebar.left") {
                            showingSavedHostPicker = false
                            showConnections()
                        }
                    }
                } else {
                    List(sessionManager.serverManager.servers) { server in
                        Button {
                            openSavedHost(server)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(server.colorTag.color)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name)
                                        .fontWeight(.semibold)
                                    Text("\(server.username)@\(server.host):\(server.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if openingServerID == server.id {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                            .frame(minHeight: 60)
                        }
                        .buttonStyle(.plain)
                        .disabled(openingServerID != nil)
                        .accessibilityLabel("Open \(server.name) in this workgroup")
                    }
                }
            }
            .navigationTitle("New Terminal Tab")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingSavedHostPicker = false
                    }
                }
            }
        }
        .alert("Unable to Open Terminal", isPresented: connectionFailureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionFailureMessage ?? "The saved host could not be opened.")
        }
    }

    private var missingWorkgroupContent: some View {
        ContentUnavailableView {
            Label("Terminal Workgroup Closed", systemImage: "rectangle.stack.badge.minus")
        } description: {
            Text("This terminal window no longer has any live sessions.")
        } actions: {
            Button("Open Connections", systemImage: "sidebar.left") {
                showConnections()
            }
        }
    }

    @ViewBuilder
    private func terminalTabs(
        workgroup: TerminalWorkgroup,
        sessions: [TerminalSession]
    ) -> some View {
        #if os(visionOS)
        adaptiveTerminalTabs(workgroup: workgroup, sessions: sessions)
            .accessibilityIdentifier("terminal-workgroup-tabs")
        #else
        if usesCompactPhoneNavigation {
            NavigationStack {
                compactTerminalTabs(workgroup: workgroup, sessions: sessions)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
                    .toolbar {
                        terminalNavigationToolbar(
                            sessions: sessions,
                            includesSessionSwitcher: true
                        )
                    }
                    .accessibilityIdentifier("terminal-workgroup-tabs")
            }
        } else {
            NavigationStack {
                adaptiveTerminalTabs(workgroup: workgroup, sessions: sessions)
                    .defaultAdaptableTabBarPlacement(.tabBar)
                    .toolbar {
                        terminalNavigationToolbar(
                            sessions: sessions,
                            includesSessionSwitcher: false
                        )
                    }
                    .toolbarBackground(.automatic, for: .tabBar)
                    .accessibilityIdentifier("terminal-workgroup-tabs")
            }
        }
        #endif
    }

    private func adaptiveTerminalTabs(
        workgroup: TerminalWorkgroup,
        sessions: [TerminalSession]
    ) -> some View {
        TabView(selection: $selectedSessionID) {
            TabSection(workgroup.name) {
                ForEach(sessions) { session in
                    terminalTab(session: session, workgroup: workgroup)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    #if os(iOS)
    private func compactTerminalTabs(
        workgroup: TerminalWorkgroup,
        sessions: [TerminalSession]
    ) -> some View {
        TabView(selection: $selectedSessionID) {
            ForEach(sessions) { session in
                terminalTab(session: session, workgroup: workgroup)
            }
        }
    }
    #endif

    private func terminalTab(
        session: TerminalSession,
        workgroup: TerminalWorkgroup
    ) -> some TabContent<UUID?> {
        Tab(value: Optional(session.id)) {
            TerminalWindowView(
                session: session,
                ownsSessionLifecycle: false,
                showsConnectionOrnament: false,
                isTerminalActive: selectedSessionID == session.id,
                onNewTerminalTab: {
                    showingSavedHostPicker = true
                },
                onSessionRequestedClose: {
                    closeSessionTab(session)
                }
            )
            .accessibilityIdentifier("terminal-workgroup-session-\(session.id.uuidString)")
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.server.name)
                    Text("\(session.server.username)@\(session.server.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(workgroup.colorTag.color)
            }
        }
    }

    #if os(iOS)
    private var usesCompactPhoneNavigation: Bool {
        horizontalSizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone
    }

    @ToolbarContentBuilder
    private func terminalNavigationToolbar(
        sessions: [TerminalSession],
        includesSessionSwitcher: Bool
    ) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showConnections()
            } label: {
                Label("Connections", systemImage: "sidebar.left")
            }
            .accessibilityIdentifier("terminal-workgroup-connections")
        }

        if includesSessionSwitcher {
            ToolbarItem(placement: .principal) {
                compactSessionSwitcher(sessions: sessions)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSavedHostPicker = true
            } label: {
                Label("New Terminal Tab", systemImage: "plus")
            }
            .accessibilityIdentifier("terminal-workgroup-new-tab")
        }
    }

    private func compactSessionSwitcher(sessions: [TerminalSession]) -> some View {
        Menu {
            Picker("Session", selection: $selectedSessionID) {
                ForEach(sessions) { session in
                    Text(
                        "\(session.server.name) — "
                            + "\(session.server.username)@\(session.server.host)"
                    )
                        .tag(Optional(session.id))
                }
            }
        } label: {
            Label(
                selectedSessionName(in: sessions),
                systemImage: "rectangle.stack"
            )
            .lineLimit(1)
        }
        .accessibilityLabel("Terminal Sessions")
        .accessibilityValue(selectedSessionName(in: sessions))
        .accessibilityIdentifier("terminal-workgroup-session-switcher")
    }

    private func selectedSessionName(in sessions: [TerminalSession]) -> String {
        sessions.first(where: { $0.id == selectedSessionID })?.server.name
            ?? sessions.first?.server.name
            ?? "Session"
    }
    #endif

    private func liveSessions(in workgroup: TerminalWorkgroup) -> [TerminalSession] {
        sessionManager.sessions(inWorkgroup: workgroup.id)
    }

    private func synchronizeSelection() {
        guard sessionManager.workgroup(for: workgroupID) != nil else {
            selectedSessionID = nil
            return
        }
        selectedSessionID = sessionManager.selectedSession(inWorkgroup: workgroupID)?.id
    }

    private func openSavedHost(_ server: ServerConfiguration) {
        guard openingServerID == nil else { return }
        openingServerID = server.id

        Task { @MainActor in
            defer { openingServerID = nil }
            do {
                let launch = try await sessionManager.createAuthorizedSessionByServerID(
                    server.id,
                    settingsManager: settingsManager,
                    initialTerminalPresentation: { pendingSession in
                        guard sessionManager.appendSession(
                            pendingSession,
                            toWorkgroup: workgroupID
                        ) else { return }
                        selectedSessionID = pendingSession.id
                        showingSavedHostPicker = false
                    }
                )
                let session = launch.session
                guard session.state == .connected || session.pendingHostKeyChallenge != nil else {
                    if case .error(let message) = session.state {
                        connectionFailureMessage = message
                    } else {
                        connectionFailureMessage = "\(server.name) did not establish a terminal session."
                    }
                    sessionManager.closeSession(session)
                    return
                }
                if session.didRequestInitialTerminalPresentation {
                    return
                }
                guard sessionManager.appendSession(session, toWorkgroup: workgroupID) else {
                    sessionManager.closeSession(session)
                    connectionFailureMessage = "\(server.name) could not be added to this workgroup."
                    return
                }
                selectedSessionID = session.id
                showingSavedHostPicker = false
            } catch {
                connectionFailureMessage = error.localizedDescription
            }
        }
    }

    private func closeSessionTab(_ session: TerminalSession) {
        let closesLastSession = sessionManager.workgroup(for: workgroupID)?.sessionIDs == [session.id]
        guard sessionManager.closeSession(session.id, inWorkgroup: workgroupID) else {
            return
        }
        if closesLastSession {
            closeWorkgroupOnce()
            #if os(visionOS)
            dismiss()
            #else
            iOSRouter.showConnections()
            #endif
        } else {
            synchronizeSelection()
        }
    }

    private func showConnections() {
        #if os(visionOS)
        openWindow(id: "main")
        dismiss()
        #else
        iOSRouter.showConnections()
        #endif
    }

    private func closeWorkgroupOnce() {
        guard !didCloseWorkgroup else { return }
        didCloseWorkgroup = true
        sessionManager.closeWorkgroup(workgroupID)
    }
}
#endif
