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
        scheduleRecoveryIfNeeded(lastClosed: key)
    }

    /// When the last visible window closes, decide what to bring back:
    /// - Connections (`main`) was the last window  → park it as the minimized spinner.
    /// - the minimized spinner was the last window → leave the space empty (this is the quit gesture).
    /// - a terminal / SFTP / preview was the last  → reopen Connections.
    /// The 220ms debounce avoids firing during window-to-window handoffs.
    private func scheduleRecoveryIfNeeded(lastClosed: String) {
        guard visibleWindowKeys.isEmpty else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard visibleWindowKeys.isEmpty else { return }
            switch lastClosed {
            case "main":
                openWindowAction?(id: "minimized")
            case "minimized":
                break
            default:
                openWindowAction?(id: "main")
            }
        }
    }
}

struct TerminalSessionOverride: Codable, Hashable {
    var windowOpacity: Double?
    var blurBackground: Double?
    var etchedBackground: Bool?
    var interactiveGlassEffects: Bool?
    var glassTint: String?
    var glassMaterialStyle: String?
}
