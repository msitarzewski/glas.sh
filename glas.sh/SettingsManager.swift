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
#if canImport(NIOSSH)
import NIOSSH
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import Citadel
import GlasSecretStore

@MainActor
@Observable
class SettingsManager {
    var currentTheme: TerminalTheme = .default
    var snippets: [CommandSnippet] = []
    var autoReconnect: Bool = true
    var confirmBeforeClosing: Bool = true
    var saveScrollback: Bool = true
    var maxScrollbackLines: Int = 10000
    var bellEnabled: Bool = false
    var visualBell: Bool = true
    var hostKeyVerificationMode: String = HostKeyVerificationMode.ask.rawValue
    var trustedHostKeys: [TrustedHostKeyEntry] = []
    var sshKeys: [StoredSSHKey] = []
    var cursorStyle: String = "Block"
    var blinkingCursor: Bool = true
    var windowOpacity: Double = 0.95
    var blurBackground: Bool = true
    var interactiveGlassEffects: Bool = true
    var glassTint: String = "None"
    var showSidebarByDefault: Bool = true
    var showInfoPanelByDefault: Bool = false
    var sidebarPosition: String = "Left"
    var sessionOverrides: [String: TerminalSessionOverride] = [:]
    var secretMigrationStatus: SecretStoreMigrationStatus?
    private var hasLoadedPersistentState = false

    init(loadImmediately: Bool = true) {
        if loadImmediately {
            loadPersistentStateIfNeeded()
        }
    }

    func loadPersistentStateIfNeeded() {
        guard !hasLoadedPersistentState else { return }
        hasLoadedPersistentState = true

        if UserDefaults.standard.object(forKey: UserDefaultsKeys.autoReconnect) != nil {
            autoReconnect = UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoReconnect)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.confirmBeforeClosing) != nil {
            confirmBeforeClosing = UserDefaults.standard.bool(forKey: UserDefaultsKeys.confirmBeforeClosing)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.saveScrollback) != nil {
            saveScrollback = UserDefaults.standard.bool(forKey: UserDefaultsKeys.saveScrollback)
        }
        let savedMaxLines = UserDefaults.standard.integer(forKey: UserDefaultsKeys.maxScrollbackLines)
        if savedMaxLines > 0 {
            maxScrollbackLines = savedMaxLines
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.bellEnabled) != nil {
            bellEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.bellEnabled)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.visualBell) != nil {
            visualBell = UserDefaults.standard.bool(forKey: UserDefaultsKeys.visualBell)
        }
        if let savedHostKeyMode = UserDefaults.standard.string(forKey: UserDefaultsKeys.hostKeyVerificationMode),
           HostKeyVerificationMode(rawValue: savedHostKeyMode) != nil {
            hostKeyVerificationMode = savedHostKeyMode
        }
        if let savedCursorStyle = UserDefaults.standard.string(forKey: UserDefaultsKeys.cursorStyle) {
            cursorStyle = savedCursorStyle
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.blinkingCursor) != nil {
            blinkingCursor = UserDefaults.standard.bool(forKey: UserDefaultsKeys.blinkingCursor)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.windowOpacity) != nil {
            windowOpacity = UserDefaults.standard.double(forKey: UserDefaultsKeys.windowOpacity)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.blurBackground) != nil {
            blurBackground = UserDefaults.standard.bool(forKey: UserDefaultsKeys.blurBackground)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.interactiveGlassEffects) != nil {
            interactiveGlassEffects = UserDefaults.standard.bool(forKey: UserDefaultsKeys.interactiveGlassEffects)
        }
        if let savedGlassTint = UserDefaults.standard.string(forKey: UserDefaultsKeys.glassTint) {
            glassTint = savedGlassTint
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.showSidebarByDefault) != nil {
            showSidebarByDefault = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showSidebarByDefault)
        }
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.showInfoPanelByDefault) != nil {
            showInfoPanelByDefault = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showInfoPanelByDefault)
        }
        if let savedSidebarPosition = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarPosition) {
            sidebarPosition = savedSidebarPosition
        }
        if let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.sessionOverrides) {
            do {
                sessionOverrides = try JSONDecoder().decode([String: TerminalSessionOverride].self, from: data)
            } catch {
                Logger.settings.error("Failed to load session overrides: \(error)")
                sessionOverrides = [:]
            }
        }

        loadTheme()
        loadSnippets()
        loadTrustedHostKeys()
        loadSSHKeys()
        KeychainManager.runMigrationsIfNeeded()
        refreshSecretMigrationStatus()
    }

    func saveSettings() {
        UserDefaults.standard.set(autoReconnect, forKey: UserDefaultsKeys.autoReconnect)
        UserDefaults.standard.set(confirmBeforeClosing, forKey: UserDefaultsKeys.confirmBeforeClosing)
        UserDefaults.standard.set(saveScrollback, forKey: UserDefaultsKeys.saveScrollback)
        UserDefaults.standard.set(maxScrollbackLines, forKey: UserDefaultsKeys.maxScrollbackLines)
        UserDefaults.standard.set(bellEnabled, forKey: UserDefaultsKeys.bellEnabled)
        UserDefaults.standard.set(visualBell, forKey: UserDefaultsKeys.visualBell)
        UserDefaults.standard.set(hostKeyVerificationMode, forKey: UserDefaultsKeys.hostKeyVerificationMode)
        UserDefaults.standard.set(cursorStyle, forKey: UserDefaultsKeys.cursorStyle)
        UserDefaults.standard.set(blinkingCursor, forKey: UserDefaultsKeys.blinkingCursor)
        UserDefaults.standard.set(windowOpacity, forKey: UserDefaultsKeys.windowOpacity)
        UserDefaults.standard.set(blurBackground, forKey: UserDefaultsKeys.blurBackground)
        UserDefaults.standard.set(interactiveGlassEffects, forKey: UserDefaultsKeys.interactiveGlassEffects)
        UserDefaults.standard.set(glassTint, forKey: UserDefaultsKeys.glassTint)
        UserDefaults.standard.set(showSidebarByDefault, forKey: UserDefaultsKeys.showSidebarByDefault)
        UserDefaults.standard.set(showInfoPanelByDefault, forKey: UserDefaultsKeys.showInfoPanelByDefault)
        UserDefaults.standard.set(sidebarPosition, forKey: UserDefaultsKeys.sidebarPosition)
        do {
            let data = try JSONEncoder().encode(sessionOverrides)
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.sessionOverrides)
        } catch {
            Logger.settings.error("Failed to save session overrides: \(error)")
        }
    }

    func sessionOverride(for sessionID: UUID) -> TerminalSessionOverride? {
        sessionOverrides[sessionID.uuidString]
    }

    func updateSessionOverride(for sessionID: UUID, mutate: (inout TerminalSessionOverride) -> Void) {
        var override = sessionOverride(for: sessionID) ?? TerminalSessionOverride()
        mutate(&override)
        sessionOverrides[sessionID.uuidString] = override
        saveSettings()
    }

    func loadTrustedHostKeys() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.trustedHostKeys) else {
            trustedHostKeys = []
            return
        }

        do {
            trustedHostKeys = try JSONDecoder().decode([TrustedHostKeyEntry].self, from: data)
        } catch {
            Logger.settings.error("Failed to load trusted host keys: \(error)")
            trustedHostKeys = []
        }
    }

    func saveTrustedHostKeys() {
        do {
            let data = try JSONEncoder().encode(trustedHostKeys)
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.trustedHostKeys)
        } catch {
            Logger.settings.error("Failed to save trusted host keys: \(error)")
        }
    }

    func loadSSHKeys() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.sshKeys) else {
            sshKeys = []
            return
        }
        do {
            sshKeys = try JSONDecoder().decode([StoredSSHKey].self, from: data)
        } catch {
            Logger.settings.error("Failed to load ssh keys: \(error)")
            sshKeys = []
        }
    }

    func refreshSecretMigrationStatus() {
        secretMigrationStatus = KeychainManager.currentStatus()
    }

    private func saveSSHKeys() {
        do {
            let data = try JSONEncoder().encode(sshKeys)
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.sshKeys)
        } catch {
            Logger.settings.error("Failed to save ssh keys: \(error)")
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
            migrationState: .pending,
            createdAt: Date()
        )
        try KeychainManager.saveSSHKey(privateKey, passphrase: passphrase, for: key.id)
        sshKeys.append(key)
        saveSSHKeys()
        return key
    }

    func generateSecureEnclaveP256Key(name: String) throws -> StoredSSHKey {
        #if canImport(CryptoKit)
        let keyID = UUID()
        let keyTag = SecureEnclaveKeyManager.keyTag(for: keyID)
        let p256PrivateKey = P256.Signing.PrivateKey()
        let sealedPayload = try SecureEnclaveKeyManager.wrap(data: p256PrivateKey.rawRepresentation, keyTag: keyTag)
        try KeychainManager.saveSecureEnclaveWrappedP256(sealedPayload, keyTag: keyTag, for: keyID)

        let key = StoredSSHKey(
            id: keyID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: SSHKeyType.ecdsaP256.description,
            storageKind: .secureEnclave,
            algorithmKind: .ecdsaP256,
            migrationState: .migrated,
            keyTag: keyTag,
            createdAt: Date()
        )
        sshKeys.append(key)
        saveSSHKeys()
        return key
        #else
        throw SecretStoreError.secureEnclaveUnavailable
        #endif
    }

    func renameSSHKey(_ keyID: UUID, name: String) {
        guard let index = sshKeys.firstIndex(where: { $0.id == keyID }) else { return }
        sshKeys[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSSHKeys()
    }

    func openSSHPublicKey(for keyID: UUID) throws -> String {
        guard let keyMetadata = sshKeys.first(where: { $0.id == keyID }) else {
            throw SecretStoreError.notFound
        }

        let keyMaterial = try KeychainManager.retrieveSSHKey(for: keyID)
        let privateKeyString = keyMaterial.privateKey.toUTF8String() ?? ""
        let passphraseData = keyMaterial.passphrase?.toData()

        let publicKey: NIOSSHPublicKey
        if privateKeyString.hasPrefix("SECURE_ENCLAVE_P256:") {
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

    func deleteSSHKey(_ keyID: UUID, serverManager: ServerManager? = nil) {
        sshKeys.removeAll { $0.id == keyID }
        try? KeychainManager.deleteSSHKey(for: keyID)

        if let serverManager {
            for i in serverManager.servers.indices {
                if serverManager.servers[i].sshKeyID == keyID {
                    serverManager.servers[i].sshKeyID = nil
                }
            }
            serverManager.saveServers()
        }
        saveSSHKeys()
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

    func trustedHostKeyBase64Set(host: String, port: Int) -> Set<String> {
        Set(
            trustedHostKeys
                .filter { $0.host == host && $0.port == port }
                .map { $0.keyDataBase64 }
        )
    }

    func trustHostKey(_ challenge: HostKeyTrustChallenge) {
        let entry = TrustedHostKeyEntry(
            host: challenge.host,
            port: challenge.port,
            algorithm: challenge.algorithm,
            fingerprintSHA256: challenge.fingerprintSHA256,
            keyDataBase64: challenge.keyDataBase64,
            addedAt: Date()
        )
        trustedHostKeys.removeAll {
            $0.host == challenge.host
                && $0.port == challenge.port
                && $0.keyDataBase64 == challenge.keyDataBase64
        }
        trustedHostKeys.append(entry)
        saveTrustedHostKeys()
    }

    func loadTheme() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.theme) else {
            currentTheme = .default
            return
        }

        do {
            currentTheme = try JSONDecoder().decode(TerminalTheme.self, from: data)
        } catch {
            Logger.settings.error("Failed to load theme: \(error)")
            currentTheme = .default
        }
    }

    func saveTheme(_ theme: TerminalTheme) {
        do {
            let data = try JSONEncoder().encode(theme)
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.theme)
            currentTheme = theme
        } catch {
            Logger.settings.error("Failed to save theme: \(error)")
        }
    }

    func loadSnippets() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.snippets) else {
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
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.snippets)
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
}
