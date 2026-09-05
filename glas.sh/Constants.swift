//
//  Constants.swift
//  glas.sh
//
//  Typed constants for UserDefaults keys and Keychain service names
//

import Foundation

nonisolated enum UserDefaultsKeys {
    static let servers = "servers"
    static let autoReconnect = "autoReconnect"
    static let confirmBeforeClosing = "confirmBeforeClosing"
    static let saveScrollback = "saveScrollback"
    static let maxScrollbackLines = "maxScrollbackLines"
    static let initialTerminalColumns = "initialTerminalColumns"
    static let initialTerminalRows = "initialTerminalRows"
    static let localShell = "localShell"
    static let localWorkingDirectory = "localWorkingDirectory"
    static let bellEnabled = "bellEnabled"
    static let visualBell = "visualBell"
    static let hostKeyVerificationMode = "hostKeyVerificationMode"
    static let cursorStyle = "cursorStyle"
    static let blinkingCursor = "blinkingCursor"
    static let windowOpacity = "windowOpacity"
    static let blurBackground = "blurBackground"
    static let interactiveGlassEffects = "interactiveGlassEffects"
    static let glassTint = "glassTint"
    static let glassFrost = "glassFrost"
    static let backgroundFill = "backgroundFill"
    static let interactiveGlass = "interactiveGlass"
    static let sessionOverrides = "sessionOverrides"
    static let trustedHostKeys = "trustedHostKeys"
    static let hostTrustMigrationVersion = "hostTrustMigrationVersion"
    static let hostTrustMigrationReport = "hostTrustMigrationReport"
    static let credentialMigrationVersion = "credentialMigrationVersion"
    static let credentialMigrationReport = "credentialMigrationReport"
    static let sshKeys = "sshKeys"
    static let sshKeyDeletionJournal = "sshKeyDeletionJournal"
    static let theme = "theme"
    static let themeLibrary = "themeLibrary"
    static let iCloudSettingsSyncEnabled = "iCloudSettingsSyncEnabled"
    static let iCloudSettingsWriterID = "iCloudSettingsWriterID"
    static let snippets = "snippets"
    static let layoutPresets = "layoutPresets"
    static let macWorkspaceRestoration = "macWorkspaceRestoration"
    static let tailscaleTailnet = "tailscaleTailnet"
    static let tailscaleAuthMethod = "tailscaleAuthMethod"
    static let focusEnvironmentStyle = "focusEnvironmentStyle"
    static let notificationOverlaysEnabled = "notificationOverlaysEnabled"
    // Legacy keys retained for one-time read-side migration in SettingsManager.
    static let glassMaterialStyle = "glassMaterialStyle"
}

nonisolated enum SharedDefaults {
    static let suiteName = "group.sh.glas.shared"
    #if os(macOS)
    static let legacyMacBundleIdentifier = "sh.glas.mac"
    static let legacyMacDomainMigrationSentinel = "legacyMacDomainMigrationComplete"

    // The Mac terminal must remain outside App Sandbox so it can launch the
    // user's shell and PTYs. App Group containers require sandbox membership,
    // so Mac metadata belongs in its bundle-scoped defaults domain instead.
    static var defaults: UserDefaults { .standard }
    #else
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }
    #endif

    static let schemaVersionKey = "sharedSchemaVersion"
    static let currentSchemaVersion = 1

    private static let migrationSentinel = "sharedDefaultsMigrationComplete"

    static func migrateIfNeeded() {
        let standard = UserDefaults.standard
        #if os(macOS)
        migrateLegacyMacDomainIfNeeded(
            legacyDomain: standard.persistentDomain(forName: legacyMacBundleIdentifier),
            destination: standard
        )
        #endif
        guard !standard.bool(forKey: migrationSentinel) else { return }

        for key in [UserDefaultsKeys.servers, UserDefaultsKeys.sshKeys, UserDefaultsKeys.trustedHostKeys] {
            if let data = standard.data(forKey: key), defaults.data(forKey: key) == nil {
                defaults.set(data, forKey: key)
            }
        }

        standard.set(true, forKey: migrationSentinel)
    }

    #if os(macOS)
    private static let legacyMacNonSecretKeys: Set<String> = [
        UserDefaultsKeys.servers,
        UserDefaultsKeys.sshKeys,
        UserDefaultsKeys.autoReconnect,
        UserDefaultsKeys.confirmBeforeClosing,
        UserDefaultsKeys.saveScrollback,
        UserDefaultsKeys.maxScrollbackLines,
        UserDefaultsKeys.initialTerminalColumns,
        UserDefaultsKeys.initialTerminalRows,
        UserDefaultsKeys.bellEnabled,
        UserDefaultsKeys.visualBell,
        UserDefaultsKeys.hostKeyVerificationMode,
        UserDefaultsKeys.cursorStyle,
        UserDefaultsKeys.blinkingCursor,
        UserDefaultsKeys.windowOpacity,
        UserDefaultsKeys.blurBackground,
        UserDefaultsKeys.interactiveGlassEffects,
        UserDefaultsKeys.glassTint,
        UserDefaultsKeys.glassFrost,
        UserDefaultsKeys.backgroundFill,
        UserDefaultsKeys.interactiveGlass,
        UserDefaultsKeys.sessionOverrides,
        UserDefaultsKeys.theme,
        UserDefaultsKeys.themeLibrary,
        UserDefaultsKeys.iCloudSettingsSyncEnabled,
        UserDefaultsKeys.iCloudSettingsWriterID,
        UserDefaultsKeys.snippets,
        UserDefaultsKeys.layoutPresets,
        UserDefaultsKeys.macWorkspaceRestoration,
        UserDefaultsKeys.tailscaleTailnet,
        UserDefaultsKeys.tailscaleAuthMethod,
        UserDefaultsKeys.focusEnvironmentStyle,
        UserDefaultsKeys.notificationOverlaysEnabled,
        UserDefaultsKeys.glassMaterialStyle,
    ]

    static func migrateLegacyMacDomainIfNeeded(
        legacyDomain: [String: Any]?,
        destination: UserDefaults
    ) {
        guard !destination.bool(forKey: legacyMacDomainMigrationSentinel),
              let legacyDomain else { return }

        var copiedEveryPendingValue = true
        for (key, value) in legacyDomain
        where isLegacyMacNonSecretKey(key) && destination.object(forKey: key) == nil {
            if key == UserDefaultsKeys.servers {
                guard let sanitizedServers = sanitizedLegacyServerCatalog(value) else {
                    copiedEveryPendingValue = false
                    continue
                }
                destination.set(sanitizedServers, forKey: key)
            } else {
                destination.set(value, forKey: key)
            }
        }

        if copiedEveryPendingValue {
            destination.set(true, forKey: legacyMacDomainMigrationSentinel)
        }
    }

    private static func isLegacyMacNonSecretKey(_ key: String) -> Bool {
        legacyMacNonSecretKeys.contains(key)
            || key.hasPrefix("\(UserDefaultsKeys.macWorkspaceRestoration).")
    }

    private static func sanitizedLegacyServerCatalog(_ value: Any) -> Data? {
        guard let data = value as? Data,
              var servers = try? JSONDecoder().decode([ServerConfiguration].self, from: data) else {
            return nil
        }
        for index in servers.indices {
            servers[index].trustedHostKeys = nil
        }
        return try? JSONEncoder().encode(servers)
    }
    #endif
}
