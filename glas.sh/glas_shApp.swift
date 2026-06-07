//
//  glas_shApp.swift
//  glas.sh
//
//  Created by Michael Sitarzewski on 9/10/25.
//

import SwiftUI

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
        
        // Main terminal windows (can open multiple)
        WindowGroup(id: "terminal", for: UUID.self) { $sessionID in
            if let sessionID = sessionID,
               let session = sessionManager.session(for: sessionID) {
                TerminalWindowView(session: session)
                    .environment(sessionManager)
                    .environment(settingsManager)
                    .trackWindowPresence(key: "terminal-\(sessionID.uuidString)", recovery: windowRecoveryManager)
            } else {
                SessionNotFoundView(sessionID: sessionID)
                    .environment(sessionManager)
                    .environment(settingsManager)
                    .trackWindowPresence(
                        key: sessionID.map { "terminal-\($0.uuidString)" } ?? "terminal-missing",
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

        // HTML Preview window
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
        
        // SFTP file browser
        WindowGroup(id: "sftp", for: SFTPBrowserContext.self) { $context in
            if let context,
               let _ = sessionManager.session(for: context.sessionID) {
                SFTPBrowserView(sessionID: context.sessionID)
                    .environment(sessionManager)
                    .environment(settingsManager)
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
                .environment(settingsManager)
                .trackWindowPresence(key: "settings", recovery: windowRecoveryManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 700, height: 600)

        // Immersive focus environment
        ImmersiveSpace(id: "focus-environment") {
            FocusEnvironmentView()
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
        .restorationBehavior(.disabled)
    }
}

struct MainBootstrapView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow
    @State private var didBootstrap = false

    var body: some View {
        ConnectionManagerView()
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            SharedDefaults.migrateIfNeeded()
            settingsManager.loadPersistentStateIfNeeded()
            sessionManager.preloadPersistentStateIfNeeded()
        }
        // NOTE: We intentionally do NOT close sessions on scenePhase == .background.
        // On visionOS, closing the Connections window (or glancing away) backgrounds
        // this scene — which would kill every live terminal and orphan its window into
        // "Session not found". Sessions are ephemeral and the OS tears down sockets on
        // actual app termination; TerminalSession.deinit cancels outstanding tasks.
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "glassh", url.host == "connect" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverIDString = components.queryItems?.first(where: { $0.name == "serverID" })?.value,
              let serverID = UUID(uuidString: serverIDString) else { return }

        Task { @MainActor in
            let session = await sessionManager.createSessionByServerID(serverID)
            if let session, session.state == .connected {
                openWindow(id: "terminal", value: session.id)
            }
        }
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
        .hoverEffect(.highlight)
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
