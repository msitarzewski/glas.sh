//
//  SessionManager.swift
//  glas.sh
//
//  Manages active terminal sessions
//

import SwiftUI
import Observation
import WidgetKit

@MainActor
@Observable
class SessionManager {
    var sessions: [TerminalSession] = []
    var activeSessionID: UUID?

    private let serverManager: ServerManager

    init(loadImmediately: Bool = true) {
        self.serverManager = ServerManager(loadImmediately: loadImmediately)
    }

    func preloadPersistentStateIfNeeded() {
        serverManager.loadServersIfNeeded()
    }

    func createSession(for server: ServerConfiguration, password: String? = nil) async -> TerminalSession {
        let session = TerminalSession(server: server)

        // Resolve jump host configuration if the server uses ProxyJump
        if let jumpID = server.jumpHostID {
            session.jumpHostConfig = serverManager.server(for: jumpID)
        }

        sessions.append(session)
        activeSessionID = session.id

        await session.connect(password: password)

        if session.state == .connected {
            serverManager.updateLastConnected(server.id)
            WidgetCenter.shared.reloadAllTimelines()
        }

        return session
    }

    func createSessionByServerID(_ serverID: UUID) async -> TerminalSession? {
        guard let server = serverManager.server(for: serverID) else { return nil }
        return await createSession(for: server)
    }

    func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func closeSession(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }

        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    func closeAllSessions() {
        for session in sessions {
            session.disconnect()
        }
        sessions.removeAll()
        activeSessionID = nil
    }
}
