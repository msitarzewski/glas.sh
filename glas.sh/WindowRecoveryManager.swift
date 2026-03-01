//
//  WindowRecoveryManager.swift
//  glas.sh
//
//  Handles window recovery when all windows are closed on visionOS
//

import SwiftUI
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class WindowRecoveryManager {
    private(set) var visibleWindowKeys: Set<String> = []
    private var recoveryTask: Task<Void, Never>?

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
            requestWindowActivation(id: "main")
        }
    }

    private func requestWindowActivation(id: String) {
        #if canImport(UIKit)
        let activity = NSUserActivity(activityType: id)
        activity.targetContentIdentifier = id
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: activity,
            options: nil
        ) { error in
            Logger.app.error("Window recovery activation failed for \(id): \(error)")
        }
        #endif
    }
}

struct TerminalSessionOverride: Codable, Hashable {
    var windowOpacity: Double?
    var blurBackground: Bool?
    var interactiveGlassEffects: Bool?
    var glassTint: String?
}
