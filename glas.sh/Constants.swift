//
//  Constants.swift
//  glas.sh
//
//  Typed constants for UserDefaults keys and Keychain service names
//

import Foundation

enum UserDefaultsKeys {
    static let servers = "servers"
    static let autoReconnect = "autoReconnect"
    static let confirmBeforeClosing = "confirmBeforeClosing"
    static let saveScrollback = "saveScrollback"
    static let maxScrollbackLines = "maxScrollbackLines"
    static let bellEnabled = "bellEnabled"
    static let visualBell = "visualBell"
    static let hostKeyVerificationMode = "hostKeyVerificationMode"
    static let cursorStyle = "cursorStyle"
    static let blinkingCursor = "blinkingCursor"
    static let windowOpacity = "windowOpacity"
    static let blurBackground = "blurBackground"
    static let interactiveGlassEffects = "interactiveGlassEffects"
    static let glassTint = "glassTint"
    static let etchedBackground = "etchedBackground"
    static let showSidebarByDefault = "showSidebarByDefault"
    static let showInfoPanelByDefault = "showInfoPanelByDefault"
    static let sidebarPosition = "sidebarPosition"
    static let sessionOverrides = "sessionOverrides"
    static let trustedHostKeys = "trustedHostKeys"
    static let sshKeys = "sshKeys"
    static let theme = "theme"
    static let snippets = "snippets"
    static let layoutPresets = "layoutPresets"
    static let tailscaleTailnet = "tailscaleTailnet"
    static let tailscaleAutoDiscover = "tailscaleAutoDiscover"
    static let tailscaleAuthMethod = "tailscaleAuthMethod"
    static let autoRecordSessions = "autoRecordSessions"
    static let focusEnvironmentStyle = "focusEnvironmentStyle"
    static let notificationOverlaysEnabled = "notificationOverlaysEnabled"
    static let glassMaterialStyle = "glassMaterialStyle"
}

enum SharedDefaults {
    static let suiteName = "group.sh.glas.shared"
    static let defaults = UserDefaults(suiteName: suiteName)!

    static let schemaVersionKey = "sharedSchemaVersion"
    static let currentSchemaVersion = 1

    private static let migrationSentinel = "sharedDefaultsMigrationComplete"

    static func migrateIfNeeded() {
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: migrationSentinel) else { return }

        for key in [UserDefaultsKeys.servers, UserDefaultsKeys.sshKeys, UserDefaultsKeys.trustedHostKeys] {
            if let data = standard.data(forKey: key), defaults.data(forKey: key) == nil {
                defaults.set(data, forKey: key)
            }
        }

        standard.set(true, forKey: migrationSentinel)
    }
}
