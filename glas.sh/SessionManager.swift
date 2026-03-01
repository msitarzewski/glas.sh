//
//  SessionManager.swift
//  glas.sh
//
//  Manages active terminal sessions
//

import SwiftUI
import Observation

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
        sessions.append(session)
        activeSessionID = session.id

        await session.connect(password: password)

        if session.state == .connected {
            serverManager.updateLastConnected(server.id)
        }

        return session
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
