//
//  SettingsManager.swift
//  glas.sh
//
//  Manages application settings persistence
//

import SwiftUI
import Foundation
import Observation
import os
import Security
#if canImport(NIOSSH)
import NIOSSH
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import Citadel
import GlasSecretStore

struct SSHKeyLifecycleStore {
    let retrieve: (UUID) throws -> SSHKeyMaterial?
    let delete: (UUID) throws -> Void
    let restore: (UUID, SSHKeyMaterial) throws -> Void
    let addIfAbsent: (UUID, SSHKeyMaterial) throws -> Bool
    let verifiesLegacySecureEnclaveBacking: (UUID, SSHKeyMaterial) throws -> Bool
    let hasAnyArtifacts: (UUID) throws -> Bool

    init(
        retrieve: @escaping (UUID) throws -> SSHKeyMaterial?,
        delete: @escaping (UUID) throws -> Void,
        restore: @escaping (UUID, SSHKeyMaterial) throws -> Void,
        addIfAbsent: @escaping (UUID, SSHKeyMaterial) throws -> Bool,
        verifiesLegacySecureEnclaveBacking: @escaping (UUID, SSHKeyMaterial) throws -> Bool = { _, _ in false },
        hasAnyArtifacts: ((UUID) throws -> Bool)? = nil
    ) {
        self.retrieve = retrieve
        self.delete = delete
        self.restore = restore
        self.addIfAbsent = addIfAbsent
        self.verifiesLegacySecureEnclaveBacking = verifiesLegacySecureEnclaveBacking
        self.hasAnyArtifacts = hasAnyArtifacts ?? { keyID in
            try retrieve(keyID) != nil
        }
    }

    static let live = SSHKeyLifecycleStore(
        retrieve: { keyID in
            do {
                return try KeychainManager.retrieveSSHKey(for: keyID)
            } catch SecretStoreError.notFound {
                return nil
            }
        },
        delete: { keyID in try KeychainManager.deleteSSHKey(for: keyID) },
        restore: { keyID, material in
            guard let privateKey = material.privateKey.toUTF8String() else {
                throw SecretStoreError.encodingFailed
            }
            let passphrase = material.passphrase?.toUTF8String()
            try KeychainManager.saveSSHKey(privateKey, passphrase: passphrase, for: keyID)
        },
        addIfAbsent: { keyID, material in
            try SSHKeyKeychainStore.addIfAbsent(
                privateKey: material.privateKey,
                passphrase: material.passphrase,
                for: keyID,
                config: KeychainManager.config
            )
        },
        verifiesLegacySecureEnclaveBacking: { keyID, material in
            try SSHKeyKeychainStore.verifiesLegacySecureEnclaveBacking(
                material,
                for: keyID,
                config: KeychainManager.config
            )
        },
        hasAnyArtifacts: { keyID in
            try SSHKeyKeychainStore.hasAnyArtifacts(
                for: keyID,
                config: KeychainManager.config
            )
        }
    )
}

enum SSHKeyDeletionPhase: String, Codable, Equatable {
    case prepared
    case metadataRemoved
    case recoveryRequired
}

struct SSHKeyDeletionJournal: Codable, Equatable {
    static let currentVersion = 1
    static let maximumEntries = 16
    static let maximumReferencedServers = 512
    static let maximumEncodedBytes = 64 * 1024

    struct Entry: Codable, Equatable {
        let key: StoredSSHKey
        let referencedServerIDs: [UUID]
        let createdAt: Date
        var phase: SSHKeyDeletionPhase
        var recoveryMessage: String?
    }

    let version: Int
    var entries: [Entry]
}

enum SettingsPersistenceError: LocalizedError {
    case invalidSSHKeyCatalog
    case readbackMismatch
    case rollbackFailed
    case invalidSSHKeyDeletionJournal
    case secretDeletionUnverified
    case sshKeyDeletionRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .invalidSSHKeyCatalog:
            return "The persisted SSH key catalog is malformed, unreadable, or too large. No key changes were made."
        case .readbackMismatch:
            return "The SSH key catalog could not be verified after saving."
        case .rollbackFailed:
            return "The SSH key operation failed and its metadata or credential rollback could not be verified."
        case .invalidSSHKeyDeletionJournal:
            return "SSH key deletion recovery data is invalid. Keep the app data intact and contact support before deleting another key."
        case .secretDeletionUnverified:
            return "The SSH key secret deletion could not be verified. The recovery record was retained."
        case .sshKeyDeletionRecoveryRequired:
            return "An interrupted SSH key deletion was recovered conservatively. Review server key assignments and retry the deletion."
        }
    }
}

@MainActor
@Observable
class SettingsManager {
    private static let appearanceSchemaVersionKey = "appearanceSchemaVersion"
    private static let currentAppearanceSchemaVersion = 2
    private static let maximumScrollbackLines = 100_000
    static let maximumSSHKeyCatalogBytes = 1024 * 1024

    var currentTheme: TerminalTheme = .default
    var themeLibrary: TerminalThemeLibrary = .initial(at: .distantPast)
    private(set) var themeLibraryLoadError: String?
    var snippets: [CommandSnippet] = []
    var autoReconnect: Bool = true
    var confirmBeforeClosing: Bool = true
    var saveScrollback: Bool = true
    var maxScrollbackLines: Int = 10000
    var bellEnabled: Bool = false
    var visualBell: Bool = true
    var hostKeyVerificationMode: String = HostKeyVerificationMode.ask.rawValue
    var sshKeys: [StoredSSHKey] = []
    private(set) var sshKeyCatalogLoadError: SettingsPersistenceError?
    private(set) var sshKeyDeletionRecoveryError: String?
    var cursorStyle: String = "Block"
    var blinkingCursor: Bool = true
    var glassFrost: String = "ultraThin"
    /// Theme-color coverage. Zero leaves the terminal canvas fully transparent.
    var windowOpacity: Double = 0.0
    /// Strength of the independently composited system blur layer.
    var blurBackground: Double = 1.0
    var interactiveGlass: Bool = true
    var glassTint: String = "None"
    /// Compatibility alias for the short-lived glass redesign schema.
    var backgroundFill: Double {
        get { windowOpacity }
        set { windowOpacity = newValue }
    }
    var sessionOverrides: [String: TerminalSessionOverride] = [:]
    var layoutPresets: [LayoutPreset] = []
    var tailscaleTailnet: String = ""
    private(set) var iCloudSyncEnabled: Bool = true
    private(set) var iCloudSyncStatusText: String = "Waiting to sync"
    private var hasLoadedPersistentState = false
    private var isApplyingICloudPayload = false
    private var iCloudSyncConfigured = false
    private var iCloudPushTask: Task<Void, Never>?
    private var iCloudSyncDirty = false
    private var iCloudRetryAttempt = 0
    private let settingsDefaults: UserDefaults
    private let sshKeyDefaults: UserDefaults
    private let sshKeyLifecycleStore: SSHKeyLifecycleStore
    private let sshKeyCatalogWriter: (Data) -> Void
    private let iCloudSettingsSyncService: ICloudSettingsSyncService

    init(
        loadImmediately: Bool = true,
        settingsDefaults: UserDefaults? = nil,
        sshKeyDefaults: UserDefaults? = nil,
        sshKeyLifecycleStore: SSHKeyLifecycleStore? = nil,
        sshKeyCatalogWriter: ((Data) -> Void)? = nil,
        iCloudSettingsSyncService: ICloudSettingsSyncService? = nil
    ) {
        self.settingsDefaults = settingsDefaults ?? .standard
        let resolvedSSHKeyDefaults = sshKeyDefaults ?? SharedDefaults.defaults
        self.sshKeyDefaults = resolvedSSHKeyDefaults
        self.sshKeyLifecycleStore = sshKeyLifecycleStore ?? .live
        self.sshKeyCatalogWriter = sshKeyCatalogWriter ?? { data in
            resolvedSSHKeyDefaults.set(data, forKey: UserDefaultsKeys.sshKeys)
        }
        let writerID: UUID
        if let persistedWriterID = self.settingsDefaults.string(
            forKey: UserDefaultsKeys.iCloudSettingsWriterID
        ).flatMap(UUID.init(uuidString:)) {
            writerID = persistedWriterID
        } else {
            writerID = UUID()
            self.settingsDefaults.set(
                writerID.uuidString,
                forKey: UserDefaultsKeys.iCloudSettingsWriterID
            )
        }
        self.iCloudSettingsSyncService = iCloudSettingsSyncService
            ?? ICloudSettingsSyncService(writerID: writerID)
        if loadImmediately {
            loadPersistentStateIfNeeded()
        }
    }

    func loadPersistentStateIfNeeded() {
        guard !hasLoadedPersistentState else { return }
        hasLoadedPersistentState = true

        if settingsDefaults.object(forKey: UserDefaultsKeys.autoReconnect) != nil {
            autoReconnect = settingsDefaults.bool(forKey: UserDefaultsKeys.autoReconnect)
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.confirmBeforeClosing) != nil {
            confirmBeforeClosing = settingsDefaults.bool(forKey: UserDefaultsKeys.confirmBeforeClosing)
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.saveScrollback) != nil {
            saveScrollback = settingsDefaults.bool(forKey: UserDefaultsKeys.saveScrollback)
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.maxScrollbackLines) != nil {
            maxScrollbackLines = Self.clampedScrollbackLines(
                settingsDefaults.integer(forKey: UserDefaultsKeys.maxScrollbackLines)
            )
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.bellEnabled) != nil {
            bellEnabled = settingsDefaults.bool(forKey: UserDefaultsKeys.bellEnabled)
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.visualBell) != nil {
            visualBell = settingsDefaults.bool(forKey: UserDefaultsKeys.visualBell)
        }
        if let savedHostKeyMode = settingsDefaults.string(forKey: UserDefaultsKeys.hostKeyVerificationMode),
           let mode = HostKeyVerificationMode(rawValue: savedHostKeyMode) {
            hostKeyVerificationMode = mode.rawValue
        }
        if let savedCursorStyle = settingsDefaults.string(forKey: UserDefaultsKeys.cursorStyle) {
            cursorStyle = savedCursorStyle
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.blinkingCursor) != nil {
            blinkingCursor = settingsDefaults.bool(forKey: UserDefaultsKeys.blinkingCursor)
        }
        // Keep opacity and blur as separate persisted dimensions. The
        // short-lived backgroundFill key maps only to opacity; it must never
        // erase a user's blur preference during migration.
        if let v = settingsDefaults.string(forKey: UserDefaultsKeys.glassFrost) {
            glassFrost = v
        } else if let old = settingsDefaults.string(forKey: UserDefaultsKeys.glassMaterialStyle) {
            glassFrost = old
        }
        let canonicalOpacity = settingsDefaults.object(forKey: UserDefaultsKeys.windowOpacity)
        let legacyOpacity = settingsDefaults.object(forKey: UserDefaultsKeys.backgroundFill)
        if canonicalOpacity != nil || legacyOpacity != nil {
            windowOpacity = Self.resolvedWindowOpacity(
                canonical: canonicalOpacity,
                legacy: legacyOpacity
            )
        }
        if let savedBlur = settingsDefaults.object(forKey: UserDefaultsKeys.blurBackground) {
            blurBackground = Self.resolvedBlurBackground(savedBlur)
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.interactiveGlass) != nil {
            interactiveGlass = settingsDefaults.bool(forKey: UserDefaultsKeys.interactiveGlass)
        } else if settingsDefaults.object(forKey: UserDefaultsKeys.interactiveGlassEffects) != nil {
            interactiveGlass = settingsDefaults.bool(forKey: UserDefaultsKeys.interactiveGlassEffects)
        }
        if let savedGlassTint = settingsDefaults.string(forKey: UserDefaultsKeys.glassTint) {
            glassTint = savedGlassTint
        }
        if let data = settingsDefaults.data(forKey: UserDefaultsKeys.sessionOverrides) {
            do {
                sessionOverrides = try JSONDecoder().decode([String: TerminalSessionOverride].self, from: data)
            } catch {
                Logger.settings.error("Failed to load session overrides: \(error)")
                sessionOverrides = [:]
            }
        }

        if let savedTailnet = settingsDefaults.string(forKey: UserDefaultsKeys.tailscaleTailnet) {
            tailscaleTailnet = savedTailnet
        }
        if settingsDefaults.object(forKey: UserDefaultsKeys.iCloudSettingsSyncEnabled) != nil {
            iCloudSyncEnabled = settingsDefaults.bool(forKey: UserDefaultsKeys.iCloudSettingsSyncEnabled)
        }

        if settingsDefaults.integer(forKey: Self.appearanceSchemaVersionKey)
            < Self.currentAppearanceSchemaVersion {
            // Persist the canonical representation immediately so migration is
            // deterministic and idempotent even if the user changes nothing.
            saveSettings()
            settingsDefaults.set(
                Self.currentAppearanceSchemaVersion,
                forKey: Self.appearanceSchemaVersionKey
            )
        }

        loadTheme()
        loadSnippets()
        loadLayoutPresets()
        loadSSHKeys()
        reconcileSSHKeyDeletionJournalAtStartup()
        configureICloudSettingsSync()
    }

    func saveSettings() {
        maxScrollbackLines = Self.clampedScrollbackLines(maxScrollbackLines)
        windowOpacity = Self.unitValue(windowOpacity)
        blurBackground = Self.unitValue(blurBackground)
        sessionOverrides = sessionOverrides.reduce(into: [:]) { result, element in
            var override = element.value
            override.canonicalizeAppearance()
            if override != TerminalSessionOverride() {
                result[element.key] = override
            }
        }
        settingsDefaults.set(autoReconnect, forKey: UserDefaultsKeys.autoReconnect)
        settingsDefaults.set(confirmBeforeClosing, forKey: UserDefaultsKeys.confirmBeforeClosing)
        settingsDefaults.set(saveScrollback, forKey: UserDefaultsKeys.saveScrollback)
        settingsDefaults.set(maxScrollbackLines, forKey: UserDefaultsKeys.maxScrollbackLines)
        settingsDefaults.set(bellEnabled, forKey: UserDefaultsKeys.bellEnabled)
        settingsDefaults.set(visualBell, forKey: UserDefaultsKeys.visualBell)
        settingsDefaults.set(hostKeyVerificationMode, forKey: UserDefaultsKeys.hostKeyVerificationMode)
        settingsDefaults.set(cursorStyle, forKey: UserDefaultsKeys.cursorStyle)
        settingsDefaults.set(blinkingCursor, forKey: UserDefaultsKeys.blinkingCursor)
        settingsDefaults.set(glassFrost, forKey: UserDefaultsKeys.glassFrost)
        settingsDefaults.set(windowOpacity, forKey: UserDefaultsKeys.windowOpacity)
        settingsDefaults.set(blurBackground, forKey: UserDefaultsKeys.blurBackground)
        settingsDefaults.set(interactiveGlass, forKey: UserDefaultsKeys.interactiveGlass)
        settingsDefaults.set(glassTint, forKey: UserDefaultsKeys.glassTint)
        settingsDefaults.set(tailscaleTailnet, forKey: UserDefaultsKeys.tailscaleTailnet)
        settingsDefaults.set(
            Self.currentAppearanceSchemaVersion,
            forKey: Self.appearanceSchemaVersionKey
        )
        settingsDefaults.removeObject(forKey: UserDefaultsKeys.backgroundFill)
        settingsDefaults.removeObject(forKey: UserDefaultsKeys.glassMaterialStyle)
        settingsDefaults.removeObject(forKey: UserDefaultsKeys.interactiveGlassEffects)
        do {
            let data = try JSONEncoder().encode(sessionOverrides)
            settingsDefaults.set(data, forKey: UserDefaultsKeys.sessionOverrides)
        } catch {
            Logger.settings.error("Failed to save session overrides: \(error)")
        }
        scheduleICloudSettingsPush()
    }

    func sessionOverride(for sessionID: UUID) -> TerminalSessionOverride? {
        sessionOverrides[sessionID.uuidString]
    }

    func updateSessionOverride(for sessionID: UUID, mutate: (inout TerminalSessionOverride) -> Void) {
        var override = sessionOverride(for: sessionID) ?? TerminalSessionOverride()
        mutate(&override)
        override.canonicalizeAppearance()
        if override == TerminalSessionOverride() {
            sessionOverrides.removeValue(forKey: sessionID.uuidString)
        } else {
            sessionOverrides[sessionID.uuidString] = override
        }
        saveSettings()
    }

    nonisolated static func unitValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func clampedScrollbackLines(_ value: Int) -> Int {
        min(maximumScrollbackLines, max(0, value))
    }

    static func resolvedWindowOpacity(canonical: Any?, legacy: Any?) -> Double {
        guard let selected = canonical ?? legacy else { return 0 }
        return numericUnitValue(selected) ?? 0
    }

    static func resolvedBlurBackground(_ value: Any) -> Double {
        if isBoolean(value) {
            return (value as? Bool) == true ? 1 : 0
        }
        return numericUnitValue(value) ?? 0
    }

    private static func numericUnitValue(_ value: Any) -> Double? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        return unitValue(number.doubleValue)
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    func loadSSHKeys() {
        do {
            let persistedObject = sshKeyDefaults.object(forKey: UserDefaultsKeys.sshKeys)
            let loadedKeys: [StoredSSHKey]
            if let data = sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeys) {
                guard data.count <= Self.maximumSSHKeyCatalogBytes else {
                    throw SettingsPersistenceError.invalidSSHKeyCatalog
                }
                loadedKeys = try JSONDecoder().decode([StoredSSHKey].self, from: data)
            } else if persistedObject == nil {
                loadedKeys = []
            } else {
                // A persisted value of the wrong type is corruption, not absence.
                throw SettingsPersistenceError.invalidSSHKeyCatalog
            }
            sshKeys = loadedKeys
            sshKeyCatalogLoadError = nil
        } catch {
            Logger.settings.error("Failed to load ssh keys: \(error)")
            // Retain the last verified in-memory view and block every metadata or
            // Keychain mutation until a subsequent load verifies the catalog.
            sshKeyCatalogLoadError = .invalidSSHKeyCatalog
        }
    }

    private func saveSSHKeys() {
        do {
            try persistSSHKeysAndVerify(sshKeys)
        } catch {
            Logger.settings.error("Failed to save ssh keys: \(error)")
        }
    }

    private func persistSSHKeysAndVerify(_ candidateKeys: [StoredSSHKey]) throws {
        try ensureSSHKeyCatalogAvailable()
        let data = try JSONEncoder().encode(candidateKeys)
        guard data.count <= Self.maximumSSHKeyCatalogBytes else {
            throw SettingsPersistenceError.readbackMismatch
        }
        sshKeyCatalogWriter(data)
        guard let persistedData = sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeys),
              persistedData.count <= Self.maximumSSHKeyCatalogBytes,
              let persistedKeys = try? JSONDecoder().decode([StoredSSHKey].self, from: persistedData),
              persistedKeys == candidateKeys else {
            throw SettingsPersistenceError.readbackMismatch
        }
    }

    private func verifiedPersistedSSHKeyCatalog() throws -> [StoredSSHKey] {
        guard let data = sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeys),
              data.count <= Self.maximumSSHKeyCatalogBytes,
              let keys = try? JSONDecoder().decode([StoredSSHKey].self, from: data) else {
            // Missing, oversized, or malformed catalog bytes are ambiguous and
            // must never be interpreted as a committed destructive mutation.
            throw SettingsPersistenceError.readbackMismatch
        }
        return keys
    }

    private func loadSSHKeyDeletionJournal() throws -> SSHKeyDeletionJournal? {
        guard let data = sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) else {
            return nil
        }
        guard data.count <= SSHKeyDeletionJournal.maximumEncodedBytes,
              let journal = try? JSONDecoder().decode(SSHKeyDeletionJournal.self, from: data),
              journal.version == SSHKeyDeletionJournal.currentVersion,
              journal.entries.count <= SSHKeyDeletionJournal.maximumEntries,
              journal.entries.allSatisfy({
                  $0.referencedServerIDs.count <= SSHKeyDeletionJournal.maximumReferencedServers
              }) else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }
        return journal
    }

    private func persistSSHKeyDeletionJournal(_ journal: SSHKeyDeletionJournal) throws {
        guard journal.version == SSHKeyDeletionJournal.currentVersion,
              journal.entries.count <= SSHKeyDeletionJournal.maximumEntries,
              journal.entries.allSatisfy({
                  $0.referencedServerIDs.count <= SSHKeyDeletionJournal.maximumReferencedServers
              }) else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= SSHKeyDeletionJournal.maximumEncodedBytes else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }
        sshKeyDefaults.set(data, forKey: UserDefaultsKeys.sshKeyDeletionJournal)
        guard let readback = sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal),
              readback.count <= SSHKeyDeletionJournal.maximumEncodedBytes,
              let decoded = try? JSONDecoder().decode(SSHKeyDeletionJournal.self, from: readback),
              decoded == journal else {
            throw SettingsPersistenceError.readbackMismatch
        }
    }

    private func clearVerifiedSSHKeyDeletionJournal() throws {
        sshKeyDefaults.removeObject(forKey: UserDefaultsKeys.sshKeyDeletionJournal)
        guard sshKeyDefaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil else {
            throw SettingsPersistenceError.readbackMismatch
        }
    }

    private static func sshKeyMaterialMatches(_ lhs: SSHKeyMaterial, _ rhs: SSHKeyMaterial) -> Bool {
        guard lhs.privateKey.toData() == rhs.privateKey.toData() else { return false }
        switch (lhs.passphrase, rhs.passphrase) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.toData() == right.toData()
        default:
            return false
        }
    }

    private func verifySSHKeySecretDeleted(_ keyID: UUID) throws {
        guard !(try sshKeyLifecycleStore.hasAnyArtifacts(keyID)) else {
            throw SettingsPersistenceError.secretDeletionUnverified
        }
    }

    private func persistedServerMetadataReferences(_ entry: SSHKeyDeletionJournal.Entry) throws -> Bool {
        guard !entry.referencedServerIDs.isEmpty else { return false }
        guard let data = sshKeyDefaults.data(forKey: UserDefaultsKeys.servers) else {
            // Missing server metadata is ambiguous when the prepared journal recorded references.
            return true
        }
        guard let servers = try? JSONDecoder().decode([ServerConfiguration].self, from: data) else {
            throw SettingsPersistenceError.readbackMismatch
        }
        return servers.contains { $0.sshKeyID == entry.key.id }
    }

    private func reconcileSSHKeyDeletionJournalAtStartup() {
        if let catalogError = sshKeyCatalogLoadError {
            do {
                if try loadSSHKeyDeletionJournal() != nil {
                    sshKeyDeletionRecoveryError = catalogError.localizedDescription
                }
            } catch {
                sshKeyDeletionRecoveryError = error.localizedDescription
            }
            return
        }
        do {
            guard var journal = try loadSSHKeyDeletionJournal() else { return }
            let persistedKeys = try verifiedPersistedSSHKeyCatalog()
            var retained: [SSHKeyDeletionJournal.Entry] = []
            for var entry in journal.entries {
                if entry.phase == .recoveryRequired {
                    // The journal intentionally contains no secret material, so
                    // restart cannot prove that an arbitrary nonnil Keychain item
                    // is the exact private key and passphrase captured before the
                    // failed deletion. Preserve the warning until explicit retry.
                    entry.recoveryMessage = entry.recoveryMessage
                        ?? SettingsPersistenceError.sshKeyDeletionRecoveryRequired.localizedDescription
                    sshKeyDeletionRecoveryError = entry.recoveryMessage
                    retained.append(entry)
                    continue
                }

                let catalogContainsKey = persistedKeys.contains { $0.id == entry.key.id }
                let serverMetadataReferencesKey = try persistedServerMetadataReferences(entry)
                if catalogContainsKey || serverMetadataReferencesKey {
                    // Persisted metadata is the commit marker. If either side still refers to
                    // the key, the deletion never committed and its live secret must survive.
                    if !catalogContainsKey {
                        sshKeys.append(entry.key)
                        try persistSSHKeysAndVerify(sshKeys)
                    }
                    guard try sshKeyLifecycleStore.retrieve(entry.key.id) != nil else {
                        entry.phase = .recoveryRequired
                        entry.recoveryMessage = SettingsPersistenceError
                            .sshKeyDeletionRecoveryRequired.localizedDescription
                        sshKeyDeletionRecoveryError = entry.recoveryMessage
                        retained.append(entry)
                        continue
                    }
                    // The deletion was safely aborted; omit its completed recovery record.
                } else {
                    try sshKeyLifecycleStore.delete(entry.key.id)
                    try verifySSHKeySecretDeleted(entry.key.id)
                    // Metadata removal committed, so omit only after verified secret deletion.
                }
            }
            journal.entries = retained
            if journal.entries.isEmpty {
                try clearVerifiedSSHKeyDeletionJournal()
            } else {
                try persistSSHKeyDeletionJournal(journal)
            }
        } catch {
            sshKeyDeletionRecoveryError = error.localizedDescription
            Logger.settings.error("SSH key deletion startup reconciliation requires attention: \(error.localizedDescription)")
        }
    }

    private func persistNewSSHKey(
        _ key: StoredSSHKey,
        material: SSHKeyMaterial
    ) throws {
        try ensureSSHKeyCatalogAvailable()
        let originalKeys = sshKeys
        var journal = try loadSSHKeyDeletionJournal()
            ?? SSHKeyDeletionJournal(
                version: SSHKeyDeletionJournal.currentVersion,
                entries: []
            )
        journal.entries.removeAll { $0.key.id == key.id }
        guard journal.entries.count < SSHKeyDeletionJournal.maximumEntries else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }
        journal.entries.append(.init(
            key: key,
            referencedServerIDs: [],
            createdAt: Date(),
            phase: .prepared,
            recoveryMessage: nil
        ))
        // The secret-free journal makes a crash after secret creation recoverable.
        try persistSSHKeyDeletionJournal(journal)

        do {
            try sshKeyLifecycleStore.restore(key.id, material)
            guard let readback = try sshKeyLifecycleStore.retrieve(key.id),
                  Self.sshKeyMaterialMatches(readback, material) else {
                throw SettingsPersistenceError.readbackMismatch
            }
            sshKeys = originalKeys + [key]
            try persistSSHKeysAndVerify(sshKeys)

            journal.entries.removeAll { $0.key.id == key.id }
            if journal.entries.isEmpty {
                try clearVerifiedSSHKeyDeletionJournal()
            } else {
                try persistSSHKeyDeletionJournal(journal)
            }
        } catch {
            var rollbackSucceeded = true
            sshKeys = originalKeys
            do {
                try persistSSHKeysAndVerify(originalKeys)
            } catch {
                rollbackSucceeded = false
            }
            do {
                try sshKeyLifecycleStore.delete(key.id)
                try verifySSHKeySecretDeleted(key.id)
            } catch {
                rollbackSucceeded = false
            }
            if rollbackSucceeded {
                journal.entries.removeAll { $0.key.id == key.id }
                do {
                    if journal.entries.isEmpty {
                        try clearVerifiedSSHKeyDeletionJournal()
                    } else {
                        try persistSSHKeyDeletionJournal(journal)
                    }
                } catch {
                    rollbackSucceeded = false
                }
            }
            guard rollbackSucceeded else {
                throw SettingsPersistenceError.rollbackFailed
            }
            throw error
        }
    }

    func addSSHKey(name: String, privateKey: String, passphrase: String?) throws -> StoredSSHKey {
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKey)
        guard keyType == .ed25519 || keyType == .rsa else {
            throw SecretStoreError.unsupportedSSHKeyType
        }
        let key = StoredSSHKey(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: keyType.description,
            storageKind: .imported,
            algorithmKind: SSHKeyAlgorithmKind.fromLegacyDescription(keyType.description),
            // This key is written directly to the canonical UUID-namespaced
            // Keychain account, so no migration remains outstanding.
            migrationState: .migrated,
            createdAt: Date()
        )
        try persistNewSSHKey(
            key,
            material: SSHKeyMaterial(
                privateKey: SecureBytes(Data(privateKey.utf8)),
                passphrase: passphrase.map { SecureBytes(Data($0.utf8)) }
            )
        )
        return key
    }

    func generateSecureEnclaveP256Key(name: String) throws -> StoredSSHKey {
        #if canImport(CryptoKit)
        let keyID = UUID()

        // Generate true Secure Enclave signing key — private key never leaves hardware
        guard SecureEnclave.isAvailable else {
            throw SecretStoreError.secureEnclaveUnavailable
        }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessControlError
        ) else {
            if let error = accessControlError?.takeRetainedValue() {
                throw error
            }
            throw SecretStoreError.secureEnclaveUnavailable
        }
        let seKey = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: accessControl
        )
        let dataRep = seKey.dataRepresentation // opaque device-bound token, NOT raw key material

        // Store the opaque token via Keychain — prefixed so auth flow knows it's true SE
        let encoded = "TRUE_SE_P256:" + dataRep.base64EncodedString()
        let key = StoredSSHKey(
            id: keyID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: SSHKeyType.ecdsaP256.description,
            storageKind: .secureEnclave,
            algorithmKind: .ecdsaP256,
            migrationState: .migrated,
            keyTag: nil,
            createdAt: Date()
        )
        try persistNewSSHKey(
            key,
            material: SSHKeyMaterial(
                privateKey: SecureBytes(Data(encoded.utf8)),
                passphrase: nil
            )
        )
        return key
        #else
        throw SecretStoreError.secureEnclaveUnavailable
        #endif
    }

    func renameSSHKey(_ keyID: UUID, name: String) {
        do {
            try renameSSHKeyOrThrow(keyID, name: name)
        } catch {
            Logger.settings.error("Failed to rename SSH key: \(error.localizedDescription)")
        }
    }

    func renameSSHKeyOrThrow(_ keyID: UUID, name: String) throws {
        try ensureSSHKeyCatalogAvailable()
        guard let index = sshKeys.firstIndex(where: { $0.id == keyID }) else {
            throw SecretStoreError.notFound
        }
        var candidateKeys = sshKeys
        candidateKeys[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try persistSSHKeysAndVerify(candidateKeys)
        sshKeys = candidateKeys
    }

    func openSSHPublicKey(for keyID: UUID) throws -> String {
        guard let keyMetadata = sshKeys.first(where: { $0.id == keyID }) else {
            throw SecretStoreError.notFound
        }

        let keyMaterial = try KeychainManager.retrieveSSHKey(for: keyID)
        let privateKeyString = keyMaterial.privateKey.toUTF8String() ?? ""
        let passphraseData = keyMaterial.passphrase?.toData()

        let publicKey: NIOSSHPublicKey
        if privateKeyString.hasPrefix("TRUE_SE_P256:") {
            let payload = String(privateKeyString.dropFirst("TRUE_SE_P256:".count))
            guard let dataRep = Data(base64Encoded: payload) else {
                throw SecretStoreError.unsupportedSSHKeyType
            }
            let seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRep)
            publicKey = NIOSSHPrivateKey(secureEnclaveP256Key: seKey).publicKey
        } else if privateKeyString.hasPrefix("SECURE_ENCLAVE_P256:") {
            let payload = String(privateKeyString.dropFirst("SECURE_ENCLAVE_P256:".count))
            guard let rawData = Data(base64Encoded: payload) else {
                throw SecretStoreError.unsupportedSSHKeyType
            }
            let p256 = try P256.Signing.PrivateKey(rawRepresentation: rawData)
            publicKey = NIOSSHPrivateKey(p256Key: p256).publicKey
        } else {
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKeyString)
            switch keyType {
            case .rsa:
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: privateKeyString, decryptionKey: passphraseData)
                publicKey = NIOSSHPrivateKey(custom: rsa).publicKey
            case .ed25519:
                let ed = try Curve25519.Signing.PrivateKey(sshEd25519: privateKeyString, decryptionKey: passphraseData)
                publicKey = NIOSSHPrivateKey(ed25519Key: ed).publicKey
            default:
                throw SecretStoreError.unsupportedSSHKeyType
            }
        }

        return "\(String(openSSHPublicKey: publicKey)) \(keyMetadata.name)"
    }

    func deleteSSHKey(_ keyID: UUID, serverManager: ServerManager? = nil) throws {
        try ensureSSHKeyCatalogAvailable()
        guard let keyMetadata = sshKeys.first(where: { $0.id == keyID }) else {
            throw SecretStoreError.notFound
        }
        let originalKeys = sshKeys
        let originalServers = serverManager?.servers
        let material = try sshKeyLifecycleStore.retrieve(keyID)
        let referencedServerIDs = (originalServers ?? [])
            .filter { $0.sshKeyID == keyID }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        guard referencedServerIDs.count <= SSHKeyDeletionJournal.maximumReferencedServers else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }

        var journal = try loadSSHKeyDeletionJournal()
            ?? SSHKeyDeletionJournal(
                version: SSHKeyDeletionJournal.currentVersion,
                entries: []
            )
        journal.entries.removeAll { $0.key.id == keyID }
        guard journal.entries.count < SSHKeyDeletionJournal.maximumEntries else {
            throw SettingsPersistenceError.invalidSSHKeyDeletionJournal
        }
        journal.entries.append(.init(
            key: keyMetadata,
            referencedServerIDs: referencedServerIDs,
            createdAt: Date(),
            phase: .prepared,
            recoveryMessage: nil
        ))
        // The secret-free journal is durable before either catalog or reference mutation.
        try persistSSHKeyDeletionJournal(journal)

        sshKeys.removeAll { $0.id == keyID }
        if let serverManager {
            for index in serverManager.servers.indices where serverManager.servers[index].sshKeyID == keyID {
                serverManager.servers[index].sshKeyID = nil
            }
        }

        do {
            try persistSSHKeysAndVerify(sshKeys)
            try serverManager?.persistServersOrThrow()
            if let index = journal.entries.firstIndex(where: { $0.key.id == keyID }) {
                journal.entries[index].phase = .metadataRemoved
            }
            try persistSSHKeyDeletionJournal(journal)
        } catch {
            sshKeys = originalKeys
            if let serverManager, let originalServers {
                serverManager.servers = originalServers
            }
            do {
                try persistSSHKeysAndVerify(originalKeys)
                try serverManager?.persistServersOrThrow()
            } catch {
                sshKeyDeletionRecoveryError = SettingsPersistenceError.rollbackFailed.localizedDescription
                throw SettingsPersistenceError.rollbackFailed
            }
            throw error
        }

        do {
            try sshKeyLifecycleStore.delete(keyID)
            try verifySSHKeySecretDeleted(keyID)

            journal.entries.removeAll { $0.key.id == keyID }
            if journal.entries.isEmpty {
                try clearVerifiedSSHKeyDeletionJournal()
            } else {
                try persistSSHKeyDeletionJournal(journal)
            }
        } catch {
            // A nil material snapshot means the original partial representation
            // cannot be reconstructed or compared after a failed delete. Even if
            // metadata rollback succeeds, retain a recovery-required journal and
            // fail closed instead of claiming that the secret was restored.
            var rollbackSucceeded = material != nil
            if let material {
                do {
                    try restoreSSHKeySecretIfUnchanged(keyID, original: material)
                } catch {
                    rollbackSucceeded = false
                }
            }
            sshKeys = originalKeys
            if let serverManager, let originalServers {
                serverManager.servers = originalServers
            }
            do {
                try persistSSHKeysAndVerify(originalKeys)
                try serverManager?.persistServersOrThrow()
            } catch {
                rollbackSucceeded = false
            }
            if let index = journal.entries.firstIndex(where: { $0.key.id == keyID }) {
                journal.entries[index].phase = .recoveryRequired
                journal.entries[index].recoveryMessage = rollbackSucceeded
                    ? "SSH key deletion failed; the secret and metadata were restored and verified. Retry the deletion."
                    : SettingsPersistenceError.rollbackFailed.localizedDescription
            }
            do {
                try persistSSHKeyDeletionJournal(journal)
                sshKeyDeletionRecoveryError = journal.entries
                    .first(where: { $0.key.id == keyID })?.recoveryMessage
            } catch {
                rollbackSucceeded = false
                sshKeyDeletionRecoveryError = SettingsPersistenceError.rollbackFailed.localizedDescription
            }
            guard rollbackSucceeded else { throw SettingsPersistenceError.rollbackFailed }
            throw error
        }
    }

    /// Restores a secret deleted by this transaction only when the account is
    /// still absent. A concurrent replacement is preserved and surfaced as a
    /// recovery-required rollback instead of being overwritten by stale bytes.
    private func restoreSSHKeySecretIfUnchanged(
        _ keyID: UUID,
        original: SSHKeyMaterial
    ) throws {
        if Self.isLegacySecureEnclaveMaterial(original) {
            guard try sshKeyLifecycleStore.verifiesLegacySecureEnclaveBacking(keyID, original),
                  let current = try sshKeyLifecycleStore.retrieve(keyID),
                  Self.sshKeyMaterialMatches(current, original) else {
                throw SettingsPersistenceError.rollbackFailed
            }
            return
        }

        if let current = try sshKeyLifecycleStore.retrieve(keyID) {
            guard Self.sshKeyMaterialMatches(current, original) else {
                throw SettingsPersistenceError.rollbackFailed
            }
            return
        }

        guard try sshKeyLifecycleStore.addIfAbsent(keyID, original) else {
            throw SettingsPersistenceError.rollbackFailed
        }
        guard let restored = try sshKeyLifecycleStore.retrieve(keyID),
              Self.sshKeyMaterialMatches(restored, original) else {
            throw SettingsPersistenceError.rollbackFailed
        }
    }

    private static func isLegacySecureEnclaveMaterial(_ material: SSHKeyMaterial) -> Bool {
        material.privateKey.toUTF8String()?.hasPrefix("SECURE_ENCLAVE_P256:") == true
    }

    func importSSHConfig(_ text: String, serverManager: ServerManager) -> SSHConfigImportResult {
        let (entries, parserWarnings) = SSHConfigParser.parse(text)
        var warnings = parserWarnings
        var imported = 0
        var updated = 0
        var skipped = 0

        for entry in entries {
            let host = (entry.hostName ?? entry.alias).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                warnings.append("Skipped Host '\(entry.alias)' because HostName resolved empty.")
                skipped += 1
                continue
            }
            guard let username = entry.user, !username.isEmpty else {
                warnings.append("Skipped Host '\(entry.alias)' because User is missing.")
                skipped += 1
                continue
            }

            let port = entry.port ?? 22
            let identityFile = entry.identityFile
            let matchedKeyID = resolveKeyID(for: identityFile)
            let authMethod: AuthenticationMethod = identityFile == nil ? .password : .sshKey

            if let idx = serverManager.servers.firstIndex(where: { $0.name == entry.alias }) {
                serverManager.servers[idx].host = host
                serverManager.servers[idx].port = port
                serverManager.servers[idx].username = username
                serverManager.servers[idx].authMethod = authMethod
                serverManager.servers[idx].sshKeyPath = identityFile
                serverManager.servers[idx].sshKeyID = matchedKeyID
                updated += 1
            } else {
                let server = ServerConfiguration(
                    name: entry.alias,
                    host: host,
                    port: port,
                    username: username,
                    authMethod: authMethod,
                    sshKeyPath: identityFile,
                    sshKeyID: matchedKeyID,
                    tags: ["imported"]
                )
                serverManager.servers.append(server)
                imported += 1
            }
        }

        serverManager.saveServers()
        return SSHConfigImportResult(imported: imported, updated: updated, skipped: skipped, warnings: warnings)
    }

    private func resolveKeyID(for identityFile: String?) -> UUID? {
        guard let identityFile, !identityFile.isEmpty else { return nil }
        let normalized = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()

        return sshKeys.first {
            let keyName = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return keyName == normalized.lowercased() || keyName == basename
        }?.id
    }

    private func ensureSSHKeyCatalogAvailable() throws {
        if let sshKeyCatalogLoadError {
            throw sshKeyCatalogLoadError
        }
    }

    func loadTheme() {
        if let libraryData = settingsDefaults.data(forKey: UserDefaultsKeys.themeLibrary) {
            do {
                var library = try JSONDecoder().decode(TerminalThemeLibrary.self, from: libraryData)
                guard library.schemaVersion == TerminalThemeLibrary.currentSchemaVersion else {
                    themeLibraryLoadError = "This theme library was created by a newer version of glas.sh and is read-only here."
                    return
                }
                var repairedLegacyColors = false
                for index in library.records.indices where !library.records[index].isDeleted {
                    if library.records[index].theme.hasCorruptedLegacyGlassTerminalColors {
                        library.records[index].theme.applyAppleClearDarkColors()
                        library.records[index].modifiedAt = Date()
                        repairedLegacyColors = true
                    }
                }
                library.canonicalize()
                themeLibrary = library
                currentTheme = library.selectedTheme ?? .default
                themeLibraryLoadError = nil
                if repairedLegacyColors { persistThemeLibrary() }
                return
            } catch {
                Logger.settings.error("Failed to load theme library: \(error)")
                themeLibraryLoadError = "The saved theme library could not be read and was left untouched."
                return
            }
        }

        var migratedTheme = TerminalTheme.default
        var migrationTimestamp = Date.distantPast
        if let data = settingsDefaults.data(forKey: UserDefaultsKeys.theme) {
            do {
                migratedTheme = try JSONDecoder().decode(TerminalTheme.self, from: data)
                // A successfully decoded legacy theme represents real local
                // user state. A synthetic first-launch default does not and
                // must never defeat an existing iCloud selection.
                migrationTimestamp = Date()
                if migratedTheme.hasCorruptedLegacyGlassTerminalColors {
                    migratedTheme.applyAppleClearDarkColors()
                }
            } catch {
                Logger.settings.error("Failed to load legacy theme: \(error)")
            }
        }
        themeLibrary = .initial(theme: migratedTheme, at: migrationTimestamp)
        currentTheme = migratedTheme
        themeLibraryLoadError = nil
        persistThemeLibrary()
    }

    func saveTheme(_ theme: TerminalTheme) {
        guard themeLibraryLoadError == nil, theme.isValidForPersistence else { return }
        themeLibrary.upsert(theme)
        _ = themeLibrary.select(theme.id)
        currentTheme = theme
        persistThemeLibrary()
    }

    var selectedThemeID: UUID {
        themeLibrary.selectedThemeID
    }

    @discardableResult
    func selectTheme(id: UUID) -> Bool {
        guard themeLibraryLoadError == nil else { return false }
        guard themeLibrary.select(id), let selected = themeLibrary.selectedTheme else { return false }
        currentTheme = selected
        persistThemeLibrary()
        return true
    }

    @discardableResult
    func createTheme(named name: String = "New Theme") -> UUID? {
        guard themeLibraryLoadError == nil, canAddThemeRecord else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = currentTheme.reidentified(
            name: trimmedName.isEmpty ? "New Theme" : String(trimmedName.prefix(80))
        )
        themeLibrary.upsert(theme, origin: .custom)
        _ = themeLibrary.select(theme.id)
        currentTheme = theme
        persistThemeLibrary()
        return theme.id
    }

    @discardableResult
    func duplicateTheme(id: UUID) -> UUID? {
        guard themeLibraryLoadError == nil, canAddThemeRecord,
              let source = themeLibrary.activeRecords.first(where: { $0.id == id }) else {
            return nil
        }
        let copy = source.theme.reidentified(name: "\(source.theme.name) Copy")
        themeLibrary.upsert(copy, origin: .custom)
        _ = themeLibrary.select(copy.id)
        currentTheme = copy
        persistThemeLibrary()
        return copy.id
    }

    @discardableResult
    func deleteTheme(id: UUID) -> Bool {
        guard themeLibraryLoadError == nil else { return false }
        guard themeLibrary.delete(id), let selected = themeLibrary.selectedTheme else { return false }
        currentTheme = selected
        persistThemeLibrary()
        return true
    }

    @discardableResult
    func resetTheme(id: UUID) -> Bool {
        guard themeLibraryLoadError == nil,
              let record = themeLibrary.activeRecords.first(where: { $0.id == id }),
              record.isBuiltIn else {
            return false
        }
        let reset = TerminalTheme.default.reidentified(id: record.id, name: record.theme.name)
        themeLibrary.upsert(reset, origin: .builtIn)
        if selectedThemeID == id { currentTheme = reset }
        persistThemeLibrary()
        return true
    }

    @discardableResult
    func addImportedTheme(_ importedTheme: TerminalTheme) -> UUID? {
        guard themeLibraryLoadError == nil,
              canAddThemeRecord,
              importedTheme.isValidForPersistence else { return nil }
        let theme = importedTheme.reidentified()
        themeLibrary.upsert(theme, origin: .appleTerminal)
        _ = themeLibrary.select(theme.id)
        currentTheme = theme
        persistThemeLibrary()
        return theme.id
    }

    @discardableResult
    func replaceThemeLibrary(_ replacement: TerminalThemeLibrary) -> Bool {
        guard themeLibraryLoadError == nil,
              replacement.schemaVersion == TerminalThemeLibrary.currentSchemaVersion,
              replacement.records.count <= TerminalThemeLibrary.maximumRecordCount,
              replacement.activeRecords.count <= TerminalThemeLibrary.maximumThemeCount,
              replacement.activeRecords.allSatisfy({ $0.theme.isValidForPersistence }),
              replacement.activeRecords.filter(\.isBuiltIn).count == 1 else {
            return false
        }
        var canonical = replacement
        canonical.canonicalize()
        themeLibrary = canonical
        currentTheme = canonical.selectedTheme ?? currentTheme
        persistThemeLibrary()
        return true
    }

    private var canAddThemeRecord: Bool {
        themeLibrary.activeRecords.count < TerminalThemeLibrary.maximumThemeCount
            && themeLibrary.records.count < TerminalThemeLibrary.maximumRecordCount
    }

    private func persistThemeLibrary() {
        guard themeLibraryLoadError == nil else { return }
        do {
            themeLibrary.canonicalize()
            let data = try JSONEncoder().encode(themeLibrary)
            settingsDefaults.set(data, forKey: UserDefaultsKeys.themeLibrary)
            if let selected = themeLibrary.selectedTheme {
                currentTheme = selected
                settingsDefaults.set(
                    try JSONEncoder().encode(selected),
                    forKey: UserDefaultsKeys.theme
                )
            }
        } catch {
            Logger.settings.error("Failed to save theme library: \(error)")
        }
        scheduleICloudSettingsPush()
    }

    func setICloudSyncEnabled(_ enabled: Bool) {
        guard iCloudSyncEnabled != enabled else { return }
        iCloudSyncEnabled = enabled
        settingsDefaults.set(enabled, forKey: UserDefaultsKeys.iCloudSettingsSyncEnabled)
        configureICloudSettingsSync()
    }

    private func configureICloudSettingsSync() {
        iCloudPushTask?.cancel()
        iCloudSyncConfigured = false

        guard iCloudSyncEnabled else {
            iCloudSettingsSyncService.stop()
            iCloudSyncStatusText = "Off"
            return
        }

        iCloudSettingsSyncService.start(
            enabled: true,
            onMerge: { [weak self] payload in
                self?.applyICloudSettingsPayload(payload)
            },
            onStatusChange: { [weak self] status, errorDescription in
                self?.updateICloudSyncStatus(status, errorDescription: errorDescription)
            }
        )
        iCloudSyncConfigured = true
        scheduleICloudSettingsPush()
    }

    private func updateICloudSyncStatus(
        _ status: ICloudSettingsSyncStatus,
        errorDescription: String?
    ) {
        switch status {
        case .disabled:
            iCloudSyncStatusText = "Off"
        case .syncing:
            iCloudSyncStatusText = "Syncing…"
        case .synced:
            iCloudSyncStatusText = "Up to date"
            if iCloudSyncDirty {
                scheduleICloudSettingsPush(markDirty: false)
            }
        case .unavailable:
            iCloudSyncStatusText = errorDescription ?? "iCloud sync is unavailable"
        case .quota:
            iCloudSyncStatusText = errorDescription ?? "iCloud storage quota exceeded"
        case .account:
            iCloudSyncStatusText = errorDescription ?? "Sign in to iCloud to sync"
        case .error:
            iCloudSyncStatusText = errorDescription ?? "Sync failed"
        }
    }

    private func scheduleICloudSettingsPush(
        markDirty: Bool = true,
        delay: Duration = .milliseconds(400)
    ) {
        guard iCloudSyncConfigured, iCloudSyncEnabled, !isApplyingICloudPayload else { return }
        if markDirty {
            iCloudSyncDirty = true
            iCloudRetryAttempt = 0
        }
        iCloudPushTask?.cancel()
        iCloudPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.iCloudSyncDirty = false
            do {
                _ = try self.iCloudSettingsSyncService.push(self.makeICloudSettingsPayload())
            } catch {
                self.iCloudSyncDirty = true
                Logger.settings.error("Failed to synchronize portable settings: \(error)")
                if self.shouldRetryICloudSync(after: error), self.iCloudRetryAttempt < 5 {
                    self.iCloudRetryAttempt += 1
                    let seconds = min(30, 1 << self.iCloudRetryAttempt)
                    self.scheduleICloudSettingsPush(
                        markDirty: false,
                        delay: .seconds(seconds)
                    )
                }
            }
        }
    }

    private func shouldRetryICloudSync(after error: Error) -> Bool {
        guard let syncError = error as? ICloudSettingsSyncError else { return false }
        switch syncError {
        case .unavailable, .accountUnavailable:
            return true
        default:
            return false
        }
    }

    private func applyICloudSettingsPayload(_ payload: ICloudSettingsSyncPayload) {
        guard (try? payload.validate()) != nil else { return }
        isApplyingICloudPayload = true
        defer { isApplyingICloudPayload = false }

        let incomingLibrary = TerminalThemeLibrary(
            records: payload.themeRecords.map(Self.localThemeRecord),
            selectedThemeID: payload.selectedThemeID,
            selectionModifiedAt: payload.selectionModifiedAt
        )
        themeLibrary.merge(incomingLibrary)
        currentTheme = themeLibrary.selectedTheme ?? currentTheme

        let preferences = payload.preferences
        autoReconnect = preferences.autoReconnect
        confirmBeforeClosing = preferences.confirmBeforeClosing
        saveScrollback = preferences.saveScrollback
        maxScrollbackLines = Self.clampedScrollbackLines(preferences.maximumScrollbackLines)
        bellEnabled = preferences.bellEnabled
        visualBell = preferences.visualBell
        cursorStyle = preferences.cursorStyle
        blinkingCursor = preferences.blinkingCursor
        glassFrost = preferences.glassFrost
        windowOpacity = Self.unitValue(preferences.windowOpacity)
        blurBackground = Self.unitValue(preferences.blurBackground)
        interactiveGlass = preferences.interactiveGlass
        glassTint = preferences.glassTint

        persistThemeLibrary()
        saveSettings()
    }

    private func makeICloudSettingsPayload() -> ICloudSettingsSyncPayload {
        ICloudSettingsSyncPayload(
            themeRecords: themeLibrary.records.map(Self.cloudThemeRecord),
            selectedThemeID: themeLibrary.selectedThemeID,
            selectionModifiedAt: themeLibrary.selectionModifiedAt,
            preferences: ICloudPortableTerminalPreferences(
                autoReconnect: autoReconnect,
                confirmBeforeClosing: confirmBeforeClosing,
                saveScrollback: saveScrollback,
                maximumScrollbackLines: maxScrollbackLines,
                bellEnabled: bellEnabled,
                visualBell: visualBell,
                cursorStyle: cursorStyle,
                blinkingCursor: blinkingCursor,
                glassFrost: glassFrost,
                windowOpacity: windowOpacity,
                blurBackground: blurBackground,
                interactiveGlass: interactiveGlass,
                glassTint: glassTint
            )
        )
    }

    private static func cloudThemeRecord(_ record: TerminalThemeRecord) -> ICloudTerminalThemeRecord {
        ICloudTerminalThemeRecord(
            theme: cloudTheme(record.theme),
            origin: record.origin,
            modifiedAt: record.modifiedAt,
            deletedAt: record.deletedAt
        )
    }

    private static func localThemeRecord(_ record: ICloudTerminalThemeRecord) -> TerminalThemeRecord {
        TerminalThemeRecord(
            theme: localTheme(record.theme),
            origin: record.origin,
            modifiedAt: record.modifiedAt,
            deletedAt: record.deletedAt
        )
    }

    private static func cloudTheme(_ theme: TerminalTheme) -> ICloudTerminalTheme {
        ICloudTerminalTheme(
            id: theme.id,
            name: theme.name,
            background: cloudColor(theme.background),
            foreground: cloudColor(theme.foreground),
            cursor: cloudColor(theme.cursor),
            selection: cloudColor(theme.selection),
            ansiColors: theme.ansiColors.map(cloudColor),
            fontName: theme.fontName,
            fontSize: Double(theme.fontSize),
            preferredAppearance: theme.preferredAppearance
        )
    }

    private static func localTheme(_ theme: ICloudTerminalTheme) -> TerminalTheme {
        let colors = theme.ansiColors
        return TerminalTheme(
            id: theme.id,
            name: theme.name,
            background: localColor(theme.background),
            foreground: localColor(theme.foreground),
            cursor: localColor(theme.cursor),
            selection: localColor(theme.selection),
            black: localColor(colors[0]),
            red: localColor(colors[1]),
            green: localColor(colors[2]),
            yellow: localColor(colors[3]),
            blue: localColor(colors[4]),
            magenta: localColor(colors[5]),
            cyan: localColor(colors[6]),
            white: localColor(colors[7]),
            brightBlack: localColor(colors[8]),
            brightRed: localColor(colors[9]),
            brightGreen: localColor(colors[10]),
            brightYellow: localColor(colors[11]),
            brightBlue: localColor(colors[12]),
            brightMagenta: localColor(colors[13]),
            brightCyan: localColor(colors[14]),
            brightWhite: localColor(colors[15]),
            fontName: theme.fontName,
            fontSize: CGFloat(theme.fontSize),
            preferredAppearance: theme.preferredAppearance
        )
    }

    private static func cloudColor(_ color: CodableColor) -> ICloudTerminalColor {
        ICloudTerminalColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func localColor(_ color: ICloudTerminalColor) -> CodableColor {
        CodableColor(sRGBRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    func loadSnippets() {
        guard let data = settingsDefaults.data(forKey: UserDefaultsKeys.snippets) else {
            snippets = []
            return
        }

        do {
            snippets = try JSONDecoder().decode([CommandSnippet].self, from: data)
        } catch {
            Logger.settings.error("Failed to load snippets: \(error)")
            snippets = []
        }
    }

    func saveSnippets() {
        do {
            let data = try JSONEncoder().encode(snippets)
            settingsDefaults.set(data, forKey: UserDefaultsKeys.snippets)
        } catch {
            Logger.settings.error("Failed to save snippets: \(error)")
        }
    }

    func addSnippet(_ snippet: CommandSnippet) {
        snippets.append(snippet)
        saveSnippets()
    }

    func updateSnippet(_ snippet: CommandSnippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
            saveSnippets()
        }
    }

    func deleteSnippet(_ snippet: CommandSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        saveSnippets()
    }

    func useSnippet(_ snippetID: UUID) {
        if let index = snippets.firstIndex(where: { $0.id == snippetID }) {
            snippets[index].lastUsed = Date()
            snippets[index].useCount += 1
            saveSnippets()
        }
    }

    // MARK: - Workgroup Presets

    func loadLayoutPresets() {
        guard let data = settingsDefaults.data(forKey: UserDefaultsKeys.layoutPresets) else {
            layoutPresets = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([LayoutPreset].self, from: data)
            let normalized = Self.validWorkgroupPresets(decoded)
            let requiresRewrite = decoded.contains(where: \.needsMigration)
                || normalized != decoded
            layoutPresets = normalized
            if requiresRewrite {
                // Rewrite legacy or invalid records once as canonical, bounded,
                // versioned workgroup recipes. Migration is idempotent.
                saveLayoutPresets()
            }
        } catch {
            Logger.settings.error("Failed to load layout presets: \(error)")
            layoutPresets = []
        }
    }

    func saveLayoutPresets() {
        do {
            layoutPresets = Self.validWorkgroupPresets(layoutPresets)
            let data = try JSONEncoder().encode(layoutPresets)
            settingsDefaults.set(data, forKey: UserDefaultsKeys.layoutPresets)
        } catch {
            Logger.settings.error("Failed to save layout presets: \(error)")
        }
    }

    func addLayoutPreset(_ preset: LayoutPreset) {
        upsertLayoutPreset(preset)
    }

    func upsertLayoutPreset(_ preset: LayoutPreset) {
        let normalized = preset.migratedToCurrentSchema()
        guard normalized.isValidForPersistence else {
            Logger.settings.error("Refusing to persist an invalid workgroup preset")
            return
        }
        if let index = layoutPresets.firstIndex(where: { $0.id == normalized.id }) {
            layoutPresets[index] = normalized
        } else {
            layoutPresets.append(normalized)
        }
        saveLayoutPresets()
    }

    func deleteLayoutPreset(_ preset: LayoutPreset) {
        layoutPresets.removeAll { $0.id == preset.id }
        saveLayoutPresets()
    }

    func updateLayoutPresetLastUsed(_ presetID: UUID) {
        if let index = layoutPresets.firstIndex(where: { $0.id == presetID }) {
            layoutPresets[index].lastUsed = Date()
            saveLayoutPresets()
        }
    }

    private static func validWorkgroupPresets(_ candidates: [LayoutPreset]) -> [LayoutPreset] {
        var seenIDs = Set<UUID>()
        let newestUnique: [LayoutPreset] = candidates.reversed().compactMap { candidate in
            let normalized = candidate.migratedToCurrentSchema()
            guard normalized.isValidForPersistence,
                  seenIDs.insert(normalized.id).inserted else { return nil }
            return normalized
        }
        return Array(newestUnique.reversed())
    }
}

/// Canonical, independently resolved levels for the terminal's two appearance
/// dimensions. Opacity paints the theme color; blur composites passthrough
/// frosting. Keeping them separate preserves all four endpoint combinations.
struct TerminalGlassAppearance: Equatable {
    let opacity: Double
    let blur: Double

    init(opacity: Double, blur: Double) {
        self.opacity = SettingsManager.unitValue(opacity)
        self.blur = SettingsManager.unitValue(blur)
    }

    static func resolved(
        globalOpacity: Double,
        globalBlur: Double,
        sessionOverride: TerminalSessionOverride?
    ) -> Self {
        Self(
            opacity: sessionOverride?.windowOpacity ?? globalOpacity,
            blur: sessionOverride?.blurBackground ?? globalBlur
        )
    }

    var paintsTheme: Bool { opacity > 0 }
    var compositesBlur: Bool { blur > 0 }
    var isFullyTransparent: Bool { !paintsTheme && !compositesBlur }
}
