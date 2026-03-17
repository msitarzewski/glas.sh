//
//  SharePlayManager.swift
//  glas.sh
//
//  SharePlay terminal sharing via GroupActivities
//

import SwiftUI
import GroupActivities
import Combine
import os

struct TerminalShareActivity: GroupActivity {
    static let activityIdentifier = "sh.glas.terminal-share"

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.type = .generic
        meta.title = "Terminal Session"
        meta.subtitle = serverName
        return meta
    }

    let serverName: String
    let sessionID: UUID
}

enum SharePlayMessage: Codable {
    case terminalOutput(Data)
    case terminalInput(Data)
    case resize(rows: Int, cols: Int)
}

@MainActor
@Observable
class SharePlayManager {
    var isActive = false
    var participantCount = 0

    private var groupSession: GroupSession<TerminalShareActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: [Task<Void, Never>] = []

    func startSharing(serverName: String, sessionID: UUID) async {
        let activity = TerminalShareActivity(serverName: serverName, sessionID: sessionID)
        do {
            let activated = try await activity.activate()
            Logger.shareplay.info("SharePlay activity activated: \(activated)")
        } catch {
            Logger.shareplay.error("Failed to activate SharePlay: \(error)")
            return
        }

        // Listen for incoming sessions
        let sessionTask = Task { @MainActor in
            for await session in TerminalShareActivity.sessions() {
                self.configureSession(session)
            }
        }
        tasks.append(sessionTask)
    }

    func stopSharing() {
        groupSession?.end()
        groupSession = nil
        messenger = nil
        isActive = false
        participantCount = 0
        for task in tasks { task.cancel() }
        tasks.removeAll()
        Logger.shareplay.info("SharePlay session ended")
    }

    func broadcastOutput(_ data: Data) async {
        guard let messenger, isActive else { return }
        do {
            try await messenger.send(SharePlayMessage.terminalOutput(data))
        } catch {
            Logger.shareplay.debug("Failed to broadcast output: \(error)")
        }
    }

    private func configureSession(_ session: GroupSession<TerminalShareActivity>) {
        groupSession = session
        messenger = GroupSessionMessenger(session: session)
        isActive = true

        session.join()
        Logger.shareplay.info("Joined SharePlay session")

        // Track participants
        let participantTask = Task { @MainActor in
            for await participants in session.$activeParticipants.values {
                self.participantCount = participants.count
                Logger.shareplay.debug("SharePlay participants: \(participants.count)")
            }
        }
        tasks.append(participantTask)

        // Receive messages
        if let messenger {
            let messageTask = Task { @MainActor in
                for await (message, _) in messenger.messages(of: SharePlayMessage.self) {
                    await self.handleMessage(message)
                }
            }
            tasks.append(messageTask)
        }

        // Handle session state
        let stateTask = Task { @MainActor in
            for await state in session.$state.values {
                if case .invalidated = state {
                    self.isActive = false
                    self.participantCount = 0
                    Logger.shareplay.info("SharePlay session invalidated")
                }
            }
        }
        tasks.append(stateTask)
    }

    private func handleMessage(_ message: SharePlayMessage) async {
        switch message {
        case .terminalOutput:
            // Viewer would feed this to their terminal display
            break
        case .terminalInput:
            // Host receives input from authorized controller
            break
        case .resize:
            break
        }
    }
}
