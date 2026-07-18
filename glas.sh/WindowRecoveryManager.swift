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
    var glassFrost: String?
    var windowOpacity: Double?
    var blurBackground: Double?
    var interactiveGlass: Bool?
    var glassTint: String?

    /// Compatibility alias for payloads written by the short-lived
    /// backgroundFill schema.
    var backgroundFill: Double? {
        get { windowOpacity }
        set { windowOpacity = newValue }
    }

    init(
        glassFrost: String? = nil,
        windowOpacity: Double? = nil,
        blurBackground: Double? = nil,
        interactiveGlass: Bool? = nil,
        glassTint: String? = nil
    ) {
        self.glassFrost = glassFrost
        self.windowOpacity = Self.unitValue(windowOpacity)
        self.blurBackground = Self.unitValue(blurBackground)
        self.interactiveGlass = interactiveGlass
        self.glassTint = glassTint
    }

    private enum CodingKeys: String, CodingKey {
        case appearanceVersion
        case glassFrost
        case windowOpacity
        case blurBackground
        case interactiveGlass
        case glassTint
        case backgroundFill
        case interactiveGlassEffects
        case glassMaterialStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        glassFrost = try container.decodeIfPresent(String.self, forKey: .glassFrost)
            ?? container.decodeIfPresent(String.self, forKey: .glassMaterialStyle)
        let opacityKey: CodingKeys? = container.contains(.windowOpacity)
            ? .windowOpacity
            : (container.contains(.backgroundFill) ? .backgroundFill : nil)
        if let opacityKey {
            if try container.decodeNil(forKey: opacityKey) {
                windowOpacity = nil
            } else if let value = try? container.decode(Double.self, forKey: opacityKey) {
                windowOpacity = Self.unitValue(value)
            } else {
                windowOpacity = 0
            }
        } else {
            windowOpacity = nil
        }

        if !container.contains(.blurBackground) {
            blurBackground = nil
        } else if try container.decodeNil(forKey: .blurBackground) {
            blurBackground = nil
        } else if let numericBlur = try? container.decode(Double.self, forKey: .blurBackground) {
            blurBackground = Self.unitValue(numericBlur)
        } else if let booleanBlur = try? container.decode(Bool.self, forKey: .blurBackground) {
            blurBackground = booleanBlur ? 1 : 0
        } else {
            blurBackground = 0
        }

        interactiveGlass = try container.decodeIfPresent(Bool.self, forKey: .interactiveGlass)
            ?? container.decodeIfPresent(Bool.self, forKey: .interactiveGlassEffects)
        glassTint = try container.decodeIfPresent(String.self, forKey: .glassTint)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .appearanceVersion)
        try container.encodeIfPresent(glassFrost, forKey: .glassFrost)
        try container.encodeIfPresent(Self.unitValue(windowOpacity), forKey: .windowOpacity)
        try container.encodeIfPresent(Self.unitValue(blurBackground), forKey: .blurBackground)
        try container.encodeIfPresent(interactiveGlass, forKey: .interactiveGlass)
        try container.encodeIfPresent(glassTint, forKey: .glassTint)
    }

    private static func unitValue(_ value: Double?) -> Double? {
        guard let value else { return nil }
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    mutating func canonicalizeAppearance() {
        if let windowOpacity {
            self.windowOpacity = windowOpacity.isFinite
                ? min(1, max(0, windowOpacity))
                : 0
        }
        if let blurBackground {
            self.blurBackground = blurBackground.isFinite
                ? min(1, max(0, blurBackground))
                : 0
        }
    }
}
