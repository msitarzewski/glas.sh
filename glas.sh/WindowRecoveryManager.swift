//
//  WindowRecoveryManager.swift
//  glas.sh
//
//  Handles window recovery when all windows are closed on visionOS
//

import SwiftUI
import Observation
import os

@MainActor
@Observable
class WindowRecoveryManager {
    private(set) var visibleWindowKeys: Set<String> = []
    private var recoveryTask: Task<Void, Never>?
    private var openWindowAction: OpenWindowAction?

    func setOpenWindowAction(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    func markWindowVisible(_ key: String) {
        visibleWindowKeys.insert(key)
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    func markWindowHidden(_ key: String) {
        visibleWindowKeys.remove(key)
        scheduleRecoveryIfNeeded()
    }

    private func scheduleRecoveryIfNeeded() {
        guard visibleWindowKeys.isEmpty else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard visibleWindowKeys.isEmpty else { return }
            openWindowAction?(id: "main")
        }
    }
}

struct TerminalSessionOverride: Codable, Hashable {
    var windowOpacity: Double?
    var blurBackground: Bool?
    var interactiveGlassEffects: Bool?
    var glassTint: String?
}
