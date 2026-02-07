//
//  glas_shApp.swift
//  glas.sh
//
//  Created by Michael Sitarzewski on 9/10/25.
//

import SwiftUI

@main
struct glas_shApp: App {
    @State private var sessionManager = SessionManager()
    @State private var settingsManager = SettingsManager()
    
    var body: some Scene {
        // Connection manager - PRIMARY WINDOW (opens on launch)
        WindowGroup(id: "main") {
            ConnectionManagerView()
                .environment(sessionManager)
                .environment(settingsManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 800, height: 600)
        
        // Main terminal windows (can open multiple)
        WindowGroup(id: "terminal", for: UUID.self) { $sessionID in
            if let sessionID = sessionID,
               let session = sessionManager.session(for: sessionID) {
                TerminalWindowView(session: session)
                    .environment(sessionManager)
                    .environment(settingsManager)
            } else {
                SessionNotFoundView()
                    .environment(sessionManager)
                    .environment(settingsManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1200, height: 800)
        
        // HTML Preview window
        WindowGroup(id: "html-preview", for: HTMLPreviewContext.self) { $context in
            if let context = context {
                HTMLPreviewWindow(context: context)
                    .environment(sessionManager)
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1000, height: 800)
        
        // Port forwarding manager
        Window("Port Forwarding", id: "port-forwarding") {
            PortForwardingManagerView()
                .environment(sessionManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 500)
        
        // Settings window (visionOS uses Window instead of Settings)
        Window("Settings", id: "settings") {
            SettingsView()
                .environment(settingsManager)
        }
        .windowStyle(.plain)
        .defaultSize(width: 700, height: 600)
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
