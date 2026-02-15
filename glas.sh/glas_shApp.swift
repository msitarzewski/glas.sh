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
                SessionNotFoundView()
                    .environment(sessionManager)
                    .environment(settingsManager)
                    .trackWindowPresence(key: "terminal-missing", recovery: windowRecoveryManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 800)
        
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
                HTMLPreviewNotFoundView()
                    .trackWindowPresence(key: "html-preview-missing", recovery: windowRecoveryManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1000, height: 800)
        
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
    }
}

struct MainBootstrapView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @State private var didBootstrap = false

    var body: some View {
        ConnectionManagerView()
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            settingsManager.loadPersistentStateIfNeeded()
            sessionManager.preloadPersistentStateIfNeeded()
        }
    }
}

private struct WindowPresenceTrackingModifier: ViewModifier {
    let key: String
    let recovery: WindowRecoveryManager

    func body(content: Content) -> some View {
        content
            .onAppear {
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

struct SessionNotFoundView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Session not found")
                .font(.title3)
                .fontWeight(.semibold)

            Text("This terminal window was restored, but its session is no longer active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Open Connections") {
                openWindow(id: "main")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

struct HTMLPreviewNotFoundView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Preview unavailable")
                .font(.title3)
                .fontWeight(.semibold)

            Text("This preview window was restored, but its source session is no longer active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Open Connections") {
                openWindow(id: "main")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
