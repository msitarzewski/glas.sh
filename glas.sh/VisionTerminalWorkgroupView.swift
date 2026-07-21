//
//  VisionTerminalWorkgroupView.swift
//  glas.sh
//
//  Platform terminal tabs backed by SessionManager workgroups.
//

import SwiftUI

#if os(visionOS) || os(iOS)
struct VisionTerminalWorkgroupView: View {
    let workgroupID: UUID

    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    @Environment(IOSAppRouter.self) private var iOSRouter
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
        .onDisappear {
            #if os(visionOS)
            closeWorkgroupOnce()
            #endif
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
        let tabs = TabView(selection: $selectedSessionID) {
            ForEach(sessions) { session in
                TerminalWindowView(
                    session: session,
                    ownsSessionLifecycle: false,
                    showsConnectionOrnament: false,
                    onNewTerminalTab: {
                        showingSavedHostPicker = true
                    },
                    onSessionRequestedClose: {
                        closeSessionTab(session)
                    }
                )
                .tag(Optional(session.id))
                .tabItem {
                    Label {
                        Text(session.server.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(workgroup.colorTag.color)
                    }
                }
            }
        }

        #if os(visionOS)
        tabs
        .ornament(attachmentAnchor: .scene(.top)) {
            workgroupLabel(workgroup: workgroup, sessions: sessions)
                .glassBackgroundEffect(in: .capsule)
        }
        #else
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showConnections()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("Connections")

                workgroupLabel(workgroup: workgroup, sessions: sessions)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            Divider()
            tabs
        }
        #endif
    }

    private func workgroupLabel(
        workgroup: TerminalWorkgroup,
        sessions: [TerminalSession]
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(workgroup.colorTag.color)

            Text(workgroup.name)
                .font(.caption)
                .fontWeight(.semibold)

            if let selectedSessionID,
               let session = sessions.first(where: { $0.id == selectedSessionID }) {
                Divider()
                    .frame(height: 18)
                Text("\(session.server.username)@\(session.server.host):\(session.server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workgroup.name), \(workgroup.colorTag.rawValue) workgroup")
    }

    private func liveSessions(in workgroup: TerminalWorkgroup) -> [TerminalSession] {
        workgroup.sessionIDs.compactMap { sessionManager.session(for: $0) }
    }

    private func synchronizeSelection() {
        guard let workgroup = sessionManager.workgroup(for: workgroupID) else {
            selectedSessionID = nil
            return
        }
        let sessions = liveSessions(in: workgroup)
        let resolvedSelection = workgroup.selectedSessionID.flatMap { selectedID in
            sessions.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? sessions.first?.id
        selectedSessionID = resolvedSelection
        if let resolvedSelection {
            sessionManager.selectSession(resolvedSelection, inWorkgroup: workgroupID)
        }
    }

    private func openSavedHost(_ server: ServerConfiguration) {
        guard openingServerID == nil else { return }
        openingServerID = server.id

        Task { @MainActor in
            defer { openingServerID = nil }
            do {
                let launch = try await sessionManager.createAuthorizedSessionByServerID(
                    server.id,
                    settingsManager: settingsManager
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
        sessionManager.removeSessionFromWorkgroup(session)
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
