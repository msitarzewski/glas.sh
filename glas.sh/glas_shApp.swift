//
//  glas_shApp.swift
//  glas.sh
//
//  Created by Michael Sitarzewski on 9/10/25.
//

import SwiftUI

#if os(visionOS)
@main
struct glas_shApp: App {
    @State private var sessionManager = SessionManager(loadImmediately: false)
    @State private var settingsManager = SettingsManager(loadImmediately: false)
    @State private var windowRecoveryManager = WindowRecoveryManager()
    
    var body: some Scene {
        // Connection manager - PRIMARY WINDOW (single instance)
        Window("Connections", id: "main") {
            MainBootstrapView()
                .environment(sessionManager)
                .environment(settingsManager)
                .trackWindowPresence(key: "main", recovery: windowRecoveryManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1320, height: 760)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: ["main"])
        
        // Terminal workgroup windows (each value identifies one runtime tab group).
        WindowGroup(id: "terminal", for: UUID.self) { $workgroupID in
            if let workgroupID {
                VisionTerminalWorkgroupView(workgroupID: workgroupID)
                    .environment(sessionManager)
                    .environment(settingsManager)
                    .trackWindowPresence(
                        key: "terminal-workgroup-\(workgroupID.uuidString)",
                        recovery: windowRecoveryManager
                    )
            } else {
                ContentUnavailableView(
                    "Terminal Workgroup Not Found",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Open a terminal from Connections to begin.")
                )
                    .trackWindowPresence(
                        key: "terminal-workgroup-missing",
                        recovery: windowRecoveryManager
                    )
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 800)
        .restorationBehavior(.disabled)

        // Minimized Connections proxy — a slowly spinning terminal icon shown when the
        // Connections window is closed while it is the last open window. Tap to restore.
        Window("", id: "minimized") {
            MinimizedConnectionsView()
                .trackWindowPresence(key: "minimized", recovery: windowRecoveryManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 160, height: 160)
        .restorationBehavior(.disabled)

        #if DEBUG
        // Development-only until preview has an authenticated tunnel/origin policy.
        WindowGroup(id: "html-preview", for: HTMLPreviewContext.self) { $context in
            if let context = context {
                HTMLPreviewWindow(context: context)
                    .environment(sessionManager)
                    .trackWindowPresence(
                        key: "html-preview-\(context.sessionID.uuidString)",
                        recovery: windowRecoveryManager
                    )
            } else {
                HTMLPreviewNotFoundView(context: context)
                    .trackWindowPresence(key: "html-preview-missing", recovery: windowRecoveryManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1000, height: 800)
        .restorationBehavior(.disabled)
        #endif
        
        // SFTP file browser
        WindowGroup(id: "sftp", for: SFTPBrowserContext.self) { $context in
            if let context,
               let _ = sessionManager.session(for: context.sessionID) {
                SFTPBrowserView(sessionID: context.sessionID)
                    .environment(sessionManager)
                    .environment(settingsManager)
                    .trackWindowPresence(
                        key: "sftp-\(context.sessionID.uuidString)",
                        recovery: windowRecoveryManager
                    )
            } else {
                SFTPBrowserNotFoundView(context: context)
                    .trackWindowPresence(key: "sftp-missing", recovery: windowRecoveryManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 700, height: 500)
        .restorationBehavior(.disabled)

        // Port forwarding manager
        Window("Port Forwarding", id: "port-forwarding") {
            PortForwardingManagerView()
                .environment(sessionManager)
                .trackWindowPresence(key: "port-forwarding", recovery: windowRecoveryManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 500)
        
        // Settings window (visionOS uses Window instead of Settings)
        Window("Settings", id: "settings") {
            SettingsView()
                .environment(sessionManager)
                .environment(settingsManager)
                .trackWindowPresence(key: "settings", recovery: windowRecoveryManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 700, height: 600)
        .restorationBehavior(.disabled)

        #if os(visionOS)
        // Immersive focus environment
        ImmersiveSpace(id: "focus-environment") {
            FocusEnvironmentView()
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
        .restorationBehavior(.disabled)
        #endif
    }
}
#endif

struct MainBootstrapView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow
    @State private var didBootstrap = false
    @State private var pendingDeepLinkServer: ServerConfiguration?
    @State private var pendingDeepLinkJumpRoute: [ServerConfiguration] = []
    @State private var pendingDeepLinkTrustSession: TerminalSession?
    @State private var pendingDeepLinkTrustChallenge: HostKeyTrustChallenge?
    @State private var deepLinkFailureMessage: String?

    var body: some View {
        ConnectionManagerView()
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            loadPersistentState()
        }
        // NOTE: We intentionally do NOT close sessions on scenePhase == .background.
        // On visionOS, closing the Connections window (or glancing away) backgrounds
        // this scene — which would kill every live terminal and orphan its window into
        // "Session not found". Sessions are ephemeral and the OS tears down sockets on
        // actual app termination; TerminalSession.deinit cancels outstanding tasks.
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .alert(
            "Connect to Server?",
            isPresented: deepLinkConfirmationBinding,
            presenting: pendingDeepLinkServer
        ) { server in
            Button(
                server.legacyAlgorithmsEnabled ? "Connect with Legacy Algorithms" : "Connect",
                role: server.legacyAlgorithmsEnabled ? .destructive : nil
            ) {
                connectToDeepLinkServer(server)
            }
            Button("Cancel", role: .cancel) {
                pendingDeepLinkServer = nil
                pendingDeepLinkJumpRoute = []
            }
        } message: { server in
            if server.legacyAlgorithmsEnabled {
                Text("An external link requested a connection to \(server.username)@\(server.host):\(server.port). This server permits obsolete SSH algorithms with weaker protection.")
            } else {
                Text("An external link requested a connection to \(server.username)@\(server.host):\(server.port).")
            }
        }
        .alert(
            pendingDeepLinkTrustChallenge?.reason == .changed
                ? "SSH Host Key Changed"
                : "Trust SSH Host Key?",
            isPresented: deepLinkTrustBinding,
            presenting: pendingDeepLinkTrustChallenge
        ) { challenge in
            Button(
                challenge.reason == .changed ? "Trust Changed Key & Connect" : "Trust & Connect",
                role: challenge.reason == .changed ? .destructive : nil
            ) {
                trustDeepLinkHostKeyAndReconnect(challenge)
            }
            Button("Cancel", role: .cancel) {
                closePendingDeepLinkTrustSession()
            }
        } message: { challenge in
            Text(deepLinkTrustMessage(for: challenge))
        }
        .alert("Connection Failed", isPresented: deepLinkFailureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deepLinkFailureMessage ?? "Unable to connect.")
        }
    }

    private func loadPersistentState() {
        SharedDefaults.migrateIfNeeded()
        sessionManager.preloadPersistentStateIfNeeded()
        settingsManager.loadPersistentStateIfNeeded()
    }

    private func handleDeepLink(_ url: URL) {
        loadPersistentState()

        guard url.scheme == "glassh", url.host == "connect" else {
            deepLinkFailureMessage = "The connection link is invalid."
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "serverID",
              let serverIDString = queryItems[0].value,
              let serverID = UUID(uuidString: serverIDString) else {
            deepLinkFailureMessage = "The connection link is invalid."
            return
        }

        guard let server = sessionManager.server(for: serverID) else {
            deepLinkFailureMessage = "The requested server was not found."
            return
        }

        guard let route = resolvedDeepLinkJumpRoute(for: server) else {
            deepLinkFailureMessage = "A jump host required by the requested server is no longer available."
            return
        }
        pendingDeepLinkJumpRoute = route
        pendingDeepLinkServer = server
    }

    private var deepLinkConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeepLinkServer != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeepLinkServer = nil
                    pendingDeepLinkJumpRoute = []
                }
            }
        )
    }

    private var deepLinkFailureBinding: Binding<Bool> {
        Binding(
            get: { deepLinkFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deepLinkFailureMessage = nil
                }
            }
        )
    }

    private var deepLinkTrustBinding: Binding<Bool> {
        Binding(
            get: { pendingDeepLinkTrustChallenge != nil },
            set: { isPresented in
                if !isPresented {
                    closePendingDeepLinkTrustSession()
                }
            }
        )
    }

    private func deepLinkTrustMessage(for challenge: HostKeyTrustChallenge) -> String {
        let context = challenge.reason == .changed
            ? "The presented key no longer matches the saved key. Verify this change before continuing."
            : "No trusted key is saved for this endpoint."
        return "\(context)\n\nEndpoint: \(challenge.host):\(challenge.port)\nAlgorithm: \(challenge.algorithm)\nFingerprint (SHA-256): \(challenge.fingerprintSHA256)"
    }

    private func trustDeepLinkHostKeyAndReconnect(_ challenge: HostKeyTrustChallenge) {
        guard let session = pendingDeepLinkTrustSession else {
            pendingDeepLinkTrustChallenge = nil
            return
        }
        do {
            try sessionManager.trustHostKey(challenge, for: session)
        } catch {
            deepLinkFailureMessage = error.localizedDescription
            closePendingDeepLinkTrustSession()
            return
        }
        session.pendingHostKeyChallenge = nil
        pendingDeepLinkTrustSession = nil
        pendingDeepLinkTrustChallenge = nil
        Task { @MainActor in
            do {
                try await sessionManager.reconnect(session, settingsManager: settingsManager)
            } catch {
                deepLinkFailureMessage = error.localizedDescription
                sessionManager.closePendingHostTrustSession(session)
                return
            }
            if session.state == .connected {
                presentTerminalWorkgroup(for: session)
            } else {
                if case .error(let message) = session.state {
                    deepLinkFailureMessage = message
                }
                sessionManager.closePendingHostTrustSession(session)
            }
        }
    }

    private func closePendingDeepLinkTrustSession() {
        if let session = pendingDeepLinkTrustSession {
            sessionManager.closePendingHostTrustSession(session)
        }
        pendingDeepLinkTrustSession = nil
        pendingDeepLinkTrustChallenge = nil
    }

    private func connectToDeepLinkServer(_ server: ServerConfiguration) {
        pendingDeepLinkServer = nil
        Task { @MainActor in
            guard let currentServer = sessionManager.server(for: server.id) else {
                deepLinkFailureMessage = "The requested server is no longer available."
                return
            }
            guard let currentRoute = resolvedDeepLinkJumpRoute(for: currentServer) else {
                pendingDeepLinkJumpRoute = []
                deepLinkFailureMessage = "A jump host required by the requested server is no longer available."
                return
            }
            let routeIsUnchanged = currentRoute.count == pendingDeepLinkJumpRoute.count
                && zip(currentRoute, pendingDeepLinkJumpRoute).allSatisfy {
                    Self.sameDeepLinkSecurityIdentity($0.0, $0.1)
                }
            guard Self.sameDeepLinkSecurityIdentity(currentServer, server), routeIsUnchanged else {
                // The connection target or its authentication/routing policy
                // changed after the prompt was presented. Show the new identity
                // and require a fresh decision.
                pendingDeepLinkJumpRoute = currentRoute
                pendingDeepLinkServer = currentServer
                return
            }
            pendingDeepLinkJumpRoute = []
            do {
                let launch = try await sessionManager.createAuthorizedSession(
                    for: currentServer,
                    settingsManager: settingsManager
                )
                if launch.session.state == .connected {
                    presentTerminalWorkgroup(for: launch.session)
                } else if let challenge = launch.session.pendingHostKeyChallenge {
                    pendingDeepLinkTrustSession = launch.session
                    pendingDeepLinkTrustChallenge = challenge
                } else if case .error(let message) = launch.session.state {
                    deepLinkFailureMessage = message
                    sessionManager.closeSession(launch.session)
                }
            } catch {
                deepLinkFailureMessage = error.localizedDescription
            }
        }
    }

    private func presentTerminalWorkgroup(for session: TerminalSession) {
        let workgroupID = sessionManager.createWorkgroup(
            name: session.server.name,
            colorTag: session.server.colorTag
        )
        guard sessionManager.appendSession(session, toWorkgroup: workgroupID) else {
            sessionManager.discardWorkgroupIfEmpty(workgroupID)
            sessionManager.closeSession(session)
            deepLinkFailureMessage = "The terminal could not be added to its workgroup."
            return
        }
        openWindow(id: "terminal", value: workgroupID)
    }

    private static func sameDeepLinkSecurityIdentity(
        _ lhs: ServerConfiguration,
        _ rhs: ServerConfiguration
    ) -> Bool {
        lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.username == rhs.username
            && lhs.authMethod == rhs.authMethod
            && lhs.sshKeyID == rhs.sshKeyID
            && lhs.resolvedJumpHostIDs == rhs.resolvedJumpHostIDs
            && lhs.legacyAlgorithmsEnabled == rhs.legacyAlgorithmsEnabled
    }

    private func resolvedDeepLinkJumpRoute(
        for server: ServerConfiguration
    ) -> [ServerConfiguration]? {
        var route: [ServerConfiguration] = []
        var visited: Set<UUID> = [server.id]
        for id in server.resolvedJumpHostIDs {
            guard visited.insert(id).inserted,
                  let hop = sessionManager.server(for: id) else { return nil }
            route.append(hop)
        }
        return route
    }
}

private struct WindowPresenceTrackingModifier: ViewModifier {
    let key: String
    let recovery: WindowRecoveryManager
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                recovery.setOpenWindowAction(openWindow)
                recovery.markWindowVisible(key)
            }
            .onDisappear {
                recovery.markWindowHidden(key)
            }
    }
}

private extension View {
    func trackWindowPresence(key: String, recovery: WindowRecoveryManager) -> some View {
        modifier(WindowPresenceTrackingModifier(key: key, recovery: recovery))
    }
}

/// Slowly spinning terminal icon shown when Connections is closed as the last window.
/// Tapping it restores the full Connections window and dismisses this proxy.
struct MinimizedConnectionsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button {
            openWindow(id: "main")
            dismissWindow(id: "minimized")
        } label: {
            Image(systemName: "terminal")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .padding(28)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .terminalHoverHighlight()
        .help("Open Connections")
        .accessibilityLabel("Open Connections")
    }
}

struct SessionNotFoundView: View {
    let sessionID: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Session not found")
                .font(.title3)
                .fontWeight(.semibold)

            Text("This terminal window's session is no longer active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Open Connections") {
                    openWindow(id: "main")
                    closeThisWindow()
                }
                .buttonStyle(.borderedProminent)

                Button("Close Window") {
                    closeThisWindow()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }

    private func closeThisWindow() {
        if let sessionID {
            dismissWindow(id: "terminal", value: sessionID)
        } else {
            dismissWindow(id: "terminal")
        }
    }
}

struct SFTPBrowserNotFoundView: View {
    let context: SFTPBrowserContext?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.fill.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("SFTP browser unavailable")
                .font(.title3)
                .fontWeight(.semibold)

            Text("This SFTP window's source session is no longer active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Close Window") {
                if let context {
                    dismissWindow(id: "sftp", value: context)
                } else {
                    dismissWindow(id: "sftp")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

#if DEBUG
struct HTMLPreviewNotFoundView: View {
    let context: HTMLPreviewContext?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Preview unavailable")
                .font(.title3)
                .fontWeight(.semibold)

            Text("This preview window's source session is no longer active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Close Window") {
                if let context {
                    dismissWindow(id: "html-preview", value: context)
                } else {
                    dismissWindow(id: "html-preview")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
#endif
