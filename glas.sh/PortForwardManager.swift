//
//  PortForwardManager.swift
//  glas.sh
//
//  Manages port forwarding state per session
//

import SwiftUI
import Observation

@MainActor
@Observable
class PortForwardManager {
    var forwards: [UUID: [PortForward]] = [:] // sessionID -> forwards

    func addForward(_ forward: PortForward, to sessionID: UUID) {
        if forwards[sessionID] == nil {
            forwards[sessionID] = []
        }
        forwards[sessionID]?.append(forward)
    }

    func removeForward(_ forward: PortForward, from sessionID: UUID) {
        forwards[sessionID]?.removeAll { $0.id == forward.id }
    }

    func toggleForward(_ forward: PortForward, in sessionID: UUID) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forward.id }) else {
            return
        }

        forwards[sessionID]?[index].isActive.toggle()

        // TODO: Actually start/stop the port forward
    }

    func forwards(for sessionID: UUID) -> [PortForward] {
        forwards[sessionID] ?? []
    }
}
