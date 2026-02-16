//
//  Managers.swift
//  glas.sh
//
//  Core business logic managers
//

import SwiftUI
import Foundation
import Security
import Observation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(NIOSSH)
import NIOSSH
#endif
#if canImport(UIKit)
import UIKit
#endif
import Citadel

enum HostKeyVerificationMode: String, Codable, CaseIterable {
    case ask = "Ask"
    case strict = "Strict"
    case insecureAcceptAny = "Insecure (Accept Any)"
}

struct TrustedHostKeyEntry: Codable, Identifiable, Hashable {
    var id: String { "\(host):\(port):\(algorithm):\(fingerprintSHA256)" }
    let host: String
    let port: Int
    let algorithm: String
    let fingerprintSHA256: String
    let keyDataBase64: String
    let addedAt: Date
}

struct StoredSSHKey: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let algorithm: String
    var storageKind: SSHKeyStorageKind
    var algorithmKind: SSHKeyAlgorithmKind
    var migrationState: SSHKeyMigrationState
    var keyTag: String?
    let createdAt: Date

    init(
        id: UUID,
        name: String,
        algorithm: String,
        storageKind: SSHKeyStorageKind = .imported,
        algorithmKind: SSHKeyAlgorithmKind = .unknown,
        migrationState: SSHKeyMigrationState = .notNeeded,
        keyTag: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.storageKind = storageKind
        self.algorithmKind = algorithmKind
        self.migrationState = migrationState
        self.keyTag = keyTag
        self.createdAt = createdAt
    }

    var keyTypeBadge: String {
        "\(storageKind.badgePrefix) \(algorithmKind.badgeName)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case algorithm
        case storageKind
        case algorithmKind
        case migrationState
        case keyTag
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        storageKind = try container.decodeIfPresent(SSHKeyStorageKind.self, forKey: .storageKind) ?? .legacy
        algorithmKind =
            try container.decodeIfPresent(SSHKeyAlgorithmKind.self, forKey: .algorithmKind)
            ?? SSHKeyAlgorithmKind.fromLegacyDescription(algorithm)
        migrationState = try container.decodeIfPresent(SSHKeyMigrationState.self, forKey: .migrationState) ?? .notNeeded
        keyTag = try container.decodeIfPresent(String.self, forKey: .keyTag)
    }
}

struct SSHKeyMaterial {
    let privateKey: String
    let passphrase: String?
}

enum SSHKeyStorageKind: String, Codable, CaseIterable {
    case legacy
    case imported
    case secureEnclave

    var badgePrefix: String {
        switch self {
        case .legacy:
            return "Legacy"
        case .imported:
            return "Imported"
        case .secureEnclave:
            return "Secure Enclave"
        }
    }
}

enum SSHKeyAlgorithmKind: String, Codable, CaseIterable {
    case rsa
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case unknown

    var badgeName: String {
        switch self {
        case .rsa:
            return "RSA"
        case .ed25519:
            return "ED25519"
        case .ecdsaP256:
            return "P-256"
        case .ecdsaP384:
            return "P-384"
        case .ecdsaP521:
            return "P-521"
        case .unknown:
            return "Unknown"
        }
    }

    static func fromLegacyDescription(_ value: String) -> SSHKeyAlgorithmKind {
        switch value.lowercased() {
        case "rsa":
            return .rsa
        case "ed25519":
            return .ed25519
        case "ecdsa p-256", "ecdsa-p256", "ecdsa_p256":
            return .ecdsaP256
        case "ecdsa p-384", "ecdsa-p384", "ecdsa_p384":
            return .ecdsaP384
        case "ecdsa p-521", "ecdsa-p521", "ecdsa_p521":
            return .ecdsaP521
        default:
            return .unknown
        }
    }
}

enum SSHKeyMigrationState: String, Codable, CaseIterable {
    case notNeeded
    case pending
    case migrated
    case failed
}

protocol SecretStore {
    func savePassword(_ password: String, for server: ServerConfiguration) throws
    func retrievePassword(for server: ServerConfiguration) throws -> String
    func deletePassword(for server: ServerConfiguration) throws
    func saveSSHKey(_ privateKey: String, passphrase: String?, for keyID: UUID) throws
    func retrieveSSHKey(for keyID: UUID) throws -> SSHKeyMaterial
    func deleteSSHKey(for keyID: UUID) throws
    func runMigrationsIfNeeded()
}

enum SecretStoreConstants {
    static let migrationMarkerComment = "sh.glas.secretstore.v1"
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
}

enum SecretStoreFactory {
    static let shared: SecretStore = KeychainSecretStore()
}

final class KeychainSecretStore: SecretStore {
    func savePassword(_ password: String, for server: ServerConfiguration) throws {
        try KeychainManager.savePassword(password, for: server)
    }

    func retrievePassword(for server: ServerConfiguration) throws -> String {
        try KeychainManager.retrievePassword(for: server)
    }

    func deletePassword(for server: ServerConfiguration) throws {
        try KeychainManager.deletePassword(for: server)
    }

    func saveSSHKey(_ privateKey: String, passphrase: String?, for keyID: UUID) throws {
        try KeychainManager.saveSSHKey(privateKey, passphrase: passphrase, for: keyID)
    }

    func retrieveSSHKey(for keyID: UUID) throws -> SSHKeyMaterial {
        try KeychainManager.retrieveSSHKey(for: keyID)
    }

    func deleteSSHKey(for keyID: UUID) throws {
        try KeychainManager.deleteSSHKey(for: keyID)
    }

    func runMigrationsIfNeeded() {
        _ = SecretStoreMigrationManager.shared.runScaffoldIfNeeded()
    }
}

struct SecretStoreMigrationReport: Codable {
    let fromVersion: Int
    let toVersion: Int
    let discoveredPasswordItemCount: Int
    let discoveredSSHPrivateKeyItemCount: Int
    let discoveredSSHPassphraseItemCount: Int
    let migratedItemCount: Int
    let failedItemCount: Int
    let completedAt: Date

    init(
        fromVersion: Int,
        toVersion: Int,
        discoveredPasswordItemCount: Int,
        discoveredSSHPrivateKeyItemCount: Int,
        discoveredSSHPassphraseItemCount: Int,
        migratedItemCount: Int,
        failedItemCount: Int,
        completedAt: Date
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.discoveredPasswordItemCount = discoveredPasswordItemCount
        self.discoveredSSHPrivateKeyItemCount = discoveredSSHPrivateKeyItemCount
        self.discoveredSSHPassphraseItemCount = discoveredSSHPassphraseItemCount
        self.migratedItemCount = migratedItemCount
        self.failedItemCount = failedItemCount
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case fromVersion
        case toVersion
        case discoveredPasswordItemCount
        case discoveredSSHPrivateKeyItemCount
        case discoveredSSHPassphraseItemCount
        case migratedItemCount
        case failedItemCount
        case completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromVersion = try container.decode(Int.self, forKey: .fromVersion)
        toVersion = try container.decode(Int.self, forKey: .toVersion)
        discoveredPasswordItemCount = try container.decode(Int.self, forKey: .discoveredPasswordItemCount)
        discoveredSSHPrivateKeyItemCount = try container.decode(Int.self, forKey: .discoveredSSHPrivateKeyItemCount)
        discoveredSSHPassphraseItemCount = try container.decode(Int.self, forKey: .discoveredSSHPassphraseItemCount)
        migratedItemCount = try container.decodeIfPresent(Int.self, forKey: .migratedItemCount) ?? 0
        failedItemCount = try container.decodeIfPresent(Int.self, forKey: .failedItemCount) ?? 0
        completedAt = try container.decode(Date.self, forKey: .completedAt)
    }
}

struct SecretStoreMigrationStatus {
    let currentVersion: Int
    let targetVersion: Int
    let passwordItemCount: Int
    let sshPrivateKeyItemCount: Int
    let sshPassphraseItemCount: Int
    let lastCompletedAt: Date?

    var pendingItemCount: Int {
        passwordItemCount + sshPrivateKeyItemCount + sshPassphraseItemCount
    }

    var needsMigration: Bool {
        pendingItemCount > 0
    }
}

final class SecretStoreMigrationManager {
    static let shared = SecretStoreMigrationManager()

    private let defaults = UserDefaults.standard
    private let migrationVersionKey = "secretStoreMigrationVersion"
    private let migrationReportKey = "secretStoreMigrationReport"
    private let scaffoldVersion = 1

    private init() {}

    @discardableResult
    func runScaffoldIfNeeded() -> SecretStoreMigrationReport? {
        let previousVersion = defaults.integer(forKey: migrationVersionKey)
        guard previousVersion < scaffoldVersion else { return nil }
        let migrationResult = runLegacyMigration()

        let report = SecretStoreMigrationReport(
            fromVersion: previousVersion,
            toVersion: scaffoldVersion,
            discoveredPasswordItemCount: keychainItemCount(for: "sh.glas.passwords", legacyOnly: true),
            discoveredSSHPrivateKeyItemCount: keychainItemCount(for: "sh.glas.sshkeys.private", legacyOnly: true),
            discoveredSSHPassphraseItemCount: keychainItemCount(for: "sh.glas.sshkeys.passphrase", legacyOnly: true),
            migratedItemCount: migrationResult.migrated,
            failedItemCount: migrationResult.failed,
            completedAt: Date()
        )

        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: migrationReportKey)
        }
        defaults.set(scaffoldVersion, forKey: migrationVersionKey)
        return report
    }

    func currentStatus() -> SecretStoreMigrationStatus {
        let report: SecretStoreMigrationReport?
        if let data = defaults.data(forKey: migrationReportKey) {
            report = try? JSONDecoder().decode(SecretStoreMigrationReport.self, from: data)
        } else {
            report = nil
        }

        return SecretStoreMigrationStatus(
            currentVersion: defaults.integer(forKey: migrationVersionKey),
            targetVersion: scaffoldVersion,
            passwordItemCount: keychainItemCount(for: "sh.glas.passwords", legacyOnly: true),
            sshPrivateKeyItemCount: keychainItemCount(for: "sh.glas.sshkeys.private", legacyOnly: true),
            sshPassphraseItemCount: keychainItemCount(for: "sh.glas.sshkeys.passphrase", legacyOnly: true),
            lastCompletedAt: report?.completedAt
        )
    }

    private func runLegacyMigration() -> (migrated: Int, failed: Int) {
        var migrated = 0
        var failed = 0
        let services = [
            "sh.glas.passwords",
            "sh.glas.sshkeys.private",
            "sh.glas.sshkeys.passphrase"
        ]
        for service in services {
            let result = migrateServiceToMarkedItems(service: service)
            migrated += result.migrated
            failed += result.failed
        }
        return (migrated, failed)
    }

    private func migrateServiceToMarkedItems(service: String) -> (migrated: Int, failed: Int) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (0, 0) }

        guard let items = result as? [[String: Any]] else { return (0, 0) }
        var migrated = 0
        var failed = 0
        for item in items {
            let comment = item[kSecAttrComment as String] as? String
            if comment == SecretStoreConstants.migrationMarkerComment {
                continue
            }
            guard
                let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data
            else {
                failed += 1
                continue
            }

            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: service
            ]
            let updateValues: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: SecretStoreConstants.accessibility,
                kSecAttrComment as String: SecretStoreConstants.migrationMarkerComment
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateValues as CFDictionary)
            if updateStatus == errSecSuccess {
                migrated += 1
            } else {
                failed += 1
            }
        }
        return (migrated, failed)
    }

    private func keychainItemCount(for service: String, legacyOnly: Bool) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return 0 }
        guard let items = result as? [[String: Any]] else { return 0 }
        if !legacyOnly {
            return items.count
        }
        return items.filter { item in
            let comment = item[kSecAttrComment as String] as? String
            return comment != SecretStoreConstants.migrationMarkerComment
        }.count
    }
}

struct SSHConfigImportResult {
    let imported: Int
    let updated: Int
    let skipped: Int
    let warnings: [String]
}

struct ParsedSSHHostEntry {
    let alias: String
    let hostName: String?
    let user: String?
    let port: Int?
    let identityFile: String?
}

enum SSHConfigParser {
    static func parse(_ text: String) -> ([ParsedSSHHostEntry], [String]) {
        let blockedDirectives: Set<String> = [
            "proxycommand", "localcommand", "include", "match", "proxyjump", "remotecommand"
        ]
        var warnings: [String] = []
        var entries: [ParsedSSHHostEntry] = []

        var currentHosts: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?

        func flushCurrent() {
            guard !currentHosts.isEmpty else { return }
            for alias in currentHosts {
                if alias.contains("*") || alias.contains("?") || alias.contains("!") {
                    warnings.append("Skipped wildcard/negated Host pattern '\(alias)'.")
                    continue
                }
                entries.append(
                    ParsedSSHHostEntry(
                        alias: alias,
                        hostName: hostName,
                        user: user,
                        port: port,
                        identityFile: identityFile
                    )
                )
            }
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let stripped = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty, !stripped.hasPrefix("#") else { continue }

            let line = stripped.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? stripped
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else {
                warnings.append("Ignored malformed line \(lineNo).")
                continue
            }

            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if blockedDirectives.contains(key) {
                warnings.append("Ignored unsupported directive '\(parts[0])' on line \(lineNo).")
                continue
            }

            switch key {
            case "host":
                flushCurrent()
                let hostParts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                currentHosts = hostParts.map(String.init)
                hostName = nil
                user = nil
                port = nil
                identityFile = nil
            case "hostname":
                hostName = value
            case "user":
                user = value
            case "port":
                port = Int(value)
                if port == nil {
                    warnings.append("Ignored invalid Port '\(value)' on line \(lineNo).")
                }
            case "identityfile":
                identityFile = value
            case "identitiesonly":
                // Parsed but currently no-op in app settings.
                break
            default:
                // Unknown directives are ignored to keep parser safe.
                break
            }
        }
        flushCurrent()
        return (entries, warnings)
    }
}

// MARK: - Session Manager

@MainActor
@Observable
class SessionManager {
    var sessions: [TerminalSession] = []
    var activeSessionID: UUID?
    
    private let serverManager: ServerManager
    
    init(loadImmediately: Bool = true) {
        self.serverManager = ServerManager(loadImmediately: loadImmediately)
    }

    func preloadPersistentStateIfNeeded() {
        serverManager.loadServersIfNeeded()
    }
    
    func createSession(for server: ServerConfiguration, password: String? = nil) async -> TerminalSession {
        let session = TerminalSession(server: server)
        sessions.append(session)
        activeSessionID = session.id
        
        await session.connect(password: password)
        
        // Update last connected on successful connection only.
        if session.state == .connected {
            serverManager.updateLastConnected(server.id)
        }
        
        return session
    }
    
    func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }
    
    func closeSession(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }
    
    func closeAllSessions() {
        for session in sessions {
            session.disconnect()
        }
        sessions.removeAll()
        activeSessionID = nil
    }
}

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
            print("Window recovery activation failed for \(id): \(error)")
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

// MARK: - Server Manager

@MainActor
@Observable
class ServerManager {
    var servers: [ServerConfiguration] = []
    
    private let serversKey = "servers"
    private var hasLoadedServers = false
    
    init(loadImmediately: Bool = true) {
        if loadImmediately {
            loadServersIfNeeded()
        }
    }

    func loadServersIfNeeded() {
        guard !hasLoadedServers else { return }
        hasLoadedServers = true
        loadServers()
    }
    
    func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: serversKey) else {
            servers = []
            return
        }
        
        do {
            servers = try JSONDecoder().decode([ServerConfiguration].self, from: data)
        } catch {
            print("Failed to load servers: \(error)")
            servers = []
        }
    }
    
    func saveServers() {
        do {
            let data = try JSONEncoder().encode(servers)
            UserDefaults.standard.set(data, forKey: serversKey)
        } catch {
            print("Failed to save servers: \(error)")
        }
    }
    
    func addServer(_ server: ServerConfiguration) {
        servers.append(server)
        saveServers()
    }
    
    func updateServer(_ server: ServerConfiguration) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
            saveServers()
        }
    }

    func server(for id: UUID) -> ServerConfiguration? {
        servers.first { $0.id == id }
    }
    
    func deleteServer(_ server: ServerConfiguration) {
        servers.removeAll { $0.id == server.id }
        saveServers()
    }
    
    func updateLastConnected(_ serverID: UUID) {
        if let index = servers.firstIndex(where: { $0.id == serverID }) {
            servers[index].lastConnected = Date()
            saveServers()
        }
    }
    
    func toggleFavorite(_ server: ServerConfiguration) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].isFavorite.toggle()
            saveServers()
        }
    }

    func trustHostKey(_ challenge: HostKeyTrustChallenge, for serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        var keys = servers[index].trustedHostKeys ?? []
        keys.removeAll {
            $0.host == challenge.host
                && $0.port == challenge.port
                && $0.keyDataBase64 == challenge.keyDataBase64
        }
        keys.append(
            TrustedHostKeyEntry(
                host: challenge.host,
                port: challenge.port,
                algorithm: challenge.algorithm,
                fingerprintSHA256: challenge.fingerprintSHA256,
                keyDataBase64: challenge.keyDataBase64,
                addedAt: Date()
            )
        )
        servers[index].trustedHostKeys = keys
        saveServers()
    }
    
    var favoriteServers: [ServerConfiguration] {
        servers.filter { $0.isFavorite }
            .sorted { ($0.lastConnected ?? $0.dateAdded) > ($1.lastConnected ?? $1.dateAdded) }
    }
    
    var recentServers: [ServerConfiguration] {
        servers
            .filter { $0.lastConnected != nil }
            .sorted { $0.lastConnected! > $1.lastConnected! }
            .prefix(10)
            .map { $0 }
    }
}

// MARK: - Settings Manager

@MainActor
@Observable
class SettingsManager {
    // Observable properties
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
    private let secretStore: SecretStore = SecretStoreFactory.shared
    
    init(loadImmediately: Bool = true) {
        if loadImmediately {
            loadPersistentStateIfNeeded()
        }
    }

    func loadPersistentStateIfNeeded() {
        guard !hasLoadedPersistentState else { return }
        hasLoadedPersistentState = true

        // Load from UserDefaults without triggering didSet
        if UserDefaults.standard.object(forKey: "autoReconnect") != nil {
            autoReconnect = UserDefaults.standard.bool(forKey: "autoReconnect")
        }
        if UserDefaults.standard.object(forKey: "confirmBeforeClosing") != nil {
            confirmBeforeClosing = UserDefaults.standard.bool(forKey: "confirmBeforeClosing")
        }
        if UserDefaults.standard.object(forKey: "saveScrollback") != nil {
            saveScrollback = UserDefaults.standard.bool(forKey: "saveScrollback")
        }
        let savedMaxLines = UserDefaults.standard.integer(forKey: "maxScrollbackLines")
        if savedMaxLines > 0 {
            maxScrollbackLines = savedMaxLines
        }
        if UserDefaults.standard.object(forKey: "bellEnabled") != nil {
            bellEnabled = UserDefaults.standard.bool(forKey: "bellEnabled")
        }
        if UserDefaults.standard.object(forKey: "visualBell") != nil {
            visualBell = UserDefaults.standard.bool(forKey: "visualBell")
        }
        if let savedHostKeyMode = UserDefaults.standard.string(forKey: "hostKeyVerificationMode"),
           HostKeyVerificationMode(rawValue: savedHostKeyMode) != nil {
            hostKeyVerificationMode = savedHostKeyMode
        }
        if let savedCursorStyle = UserDefaults.standard.string(forKey: "cursorStyle") {
            cursorStyle = savedCursorStyle
        }
        if UserDefaults.standard.object(forKey: "blinkingCursor") != nil {
            blinkingCursor = UserDefaults.standard.bool(forKey: "blinkingCursor")
        }
        if UserDefaults.standard.object(forKey: "windowOpacity") != nil {
            windowOpacity = UserDefaults.standard.double(forKey: "windowOpacity")
        }
        if UserDefaults.standard.object(forKey: "blurBackground") != nil {
            blurBackground = UserDefaults.standard.bool(forKey: "blurBackground")
        }
        if UserDefaults.standard.object(forKey: "interactiveGlassEffects") != nil {
            interactiveGlassEffects = UserDefaults.standard.bool(forKey: "interactiveGlassEffects")
        }
        if let savedGlassTint = UserDefaults.standard.string(forKey: "glassTint") {
            glassTint = savedGlassTint
        }
        if UserDefaults.standard.object(forKey: "showSidebarByDefault") != nil {
            showSidebarByDefault = UserDefaults.standard.bool(forKey: "showSidebarByDefault")
        }
        if UserDefaults.standard.object(forKey: "showInfoPanelByDefault") != nil {
            showInfoPanelByDefault = UserDefaults.standard.bool(forKey: "showInfoPanelByDefault")
        }
        if let savedSidebarPosition = UserDefaults.standard.string(forKey: "sidebarPosition") {
            sidebarPosition = savedSidebarPosition
        }
        if let data = UserDefaults.standard.data(forKey: "sessionOverrides") {
            do {
                sessionOverrides = try JSONDecoder().decode([String: TerminalSessionOverride].self, from: data)
            } catch {
                print("Failed to load session overrides: \(error)")
                sessionOverrides = [:]
            }
        }
        
        loadTheme()
        loadSnippets()
        loadTrustedHostKeys()
        loadSSHKeys()
        secretStore.runMigrationsIfNeeded()
        refreshSecretMigrationStatus()
    }
    
    // Manually save when properties change
    func saveSettings() {
        UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect")
        UserDefaults.standard.set(confirmBeforeClosing, forKey: "confirmBeforeClosing")
        UserDefaults.standard.set(saveScrollback, forKey: "saveScrollback")
        UserDefaults.standard.set(maxScrollbackLines, forKey: "maxScrollbackLines")
        UserDefaults.standard.set(bellEnabled, forKey: "bellEnabled")
        UserDefaults.standard.set(visualBell, forKey: "visualBell")
        UserDefaults.standard.set(hostKeyVerificationMode, forKey: "hostKeyVerificationMode")
        UserDefaults.standard.set(cursorStyle, forKey: "cursorStyle")
        UserDefaults.standard.set(blinkingCursor, forKey: "blinkingCursor")
        UserDefaults.standard.set(windowOpacity, forKey: "windowOpacity")
        UserDefaults.standard.set(blurBackground, forKey: "blurBackground")
        UserDefaults.standard.set(interactiveGlassEffects, forKey: "interactiveGlassEffects")
        UserDefaults.standard.set(glassTint, forKey: "glassTint")
        UserDefaults.standard.set(showSidebarByDefault, forKey: "showSidebarByDefault")
        UserDefaults.standard.set(showInfoPanelByDefault, forKey: "showInfoPanelByDefault")
        UserDefaults.standard.set(sidebarPosition, forKey: "sidebarPosition")
        do {
            let data = try JSONEncoder().encode(sessionOverrides)
            UserDefaults.standard.set(data, forKey: "sessionOverrides")
        } catch {
            print("Failed to save session overrides: \(error)")
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
        guard let data = UserDefaults.standard.data(forKey: "trustedHostKeys") else {
            trustedHostKeys = []
            return
        }

        do {
            trustedHostKeys = try JSONDecoder().decode([TrustedHostKeyEntry].self, from: data)
        } catch {
            print("Failed to load trusted host keys: \(error)")
            trustedHostKeys = []
        }
    }

    func saveTrustedHostKeys() {
        do {
            let data = try JSONEncoder().encode(trustedHostKeys)
            UserDefaults.standard.set(data, forKey: "trustedHostKeys")
        } catch {
            print("Failed to save trusted host keys: \(error)")
        }
    }

    func loadSSHKeys() {
        guard let data = UserDefaults.standard.data(forKey: "sshKeys") else {
            sshKeys = []
            return
        }
        do {
            sshKeys = try JSONDecoder().decode([StoredSSHKey].self, from: data)
        } catch {
            print("Failed to load ssh keys: \(error)")
            sshKeys = []
        }
    }

    func refreshSecretMigrationStatus() {
        secretMigrationStatus = SecretStoreMigrationManager.shared.currentStatus()
    }

    private func saveSSHKeys() {
        do {
            let data = try JSONEncoder().encode(sshKeys)
            UserDefaults.standard.set(data, forKey: "sshKeys")
        } catch {
            print("Failed to save ssh keys: \(error)")
        }
    }

    func addSSHKey(name: String, privateKey: String, passphrase: String?) throws -> StoredSSHKey {
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKey)
        guard keyType == .ed25519 || keyType == .rsa else {
            throw KeychainManager.KeychainError.unsupportedSSHKeyType
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
        try secretStore.saveSSHKey(privateKey, passphrase: passphrase, for: key.id)
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
        throw KeychainManager.KeychainError.secureEnclaveUnavailable
        #endif
    }

    func renameSSHKey(_ keyID: UUID, name: String) {
        guard let index = sshKeys.firstIndex(where: { $0.id == keyID }) else { return }
        sshKeys[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSSHKeys()
    }

    func openSSHPublicKey(for keyID: UUID) throws -> String {
        guard let keyMetadata = sshKeys.first(where: { $0.id == keyID }) else {
            throw KeychainManager.KeychainError.notFound
        }

        let keyMaterial = try secretStore.retrieveSSHKey(for: keyID)
        let passphraseData = keyMaterial.passphrase?.data(using: .utf8)

        let publicKey: NIOSSHPublicKey
        if keyMaterial.privateKey.hasPrefix("SECURE_ENCLAVE_P256:") {
            let payload = String(keyMaterial.privateKey.dropFirst("SECURE_ENCLAVE_P256:".count))
            guard let rawData = Data(base64Encoded: payload) else {
                throw KeychainManager.KeychainError.unsupportedSSHKeyType
            }
            let p256 = try P256.Signing.PrivateKey(rawRepresentation: rawData)
            publicKey = NIOSSHPrivateKey(p256Key: p256).publicKey
        } else {
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyMaterial.privateKey)
            switch keyType {
            case .rsa:
                let rsa = try Insecure.RSA.PrivateKey(sshRsa: keyMaterial.privateKey, decryptionKey: passphraseData)
                publicKey = NIOSSHPrivateKey(custom: rsa).publicKey
            case .ed25519:
                let ed = try Curve25519.Signing.PrivateKey(sshEd25519: keyMaterial.privateKey, decryptionKey: passphraseData)
                publicKey = NIOSSHPrivateKey(ed25519Key: ed).publicKey
            default:
                throw KeychainManager.KeychainError.unsupportedSSHKeyType
            }
        }

        return "\(String(openSSHPublicKey: publicKey)) \(keyMetadata.name)"
    }

    func deleteSSHKey(_ keyID: UUID, serverManager: ServerManager? = nil) {
        sshKeys.removeAll { $0.id == keyID }
        try? secretStore.deleteSSHKey(for: keyID)

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
        guard let data = UserDefaults.standard.data(forKey: "theme") else {
            currentTheme = .default
            return
        }
        
        do {
            currentTheme = try JSONDecoder().decode(TerminalTheme.self, from: data)
        } catch {
            print("Failed to load theme: \(error)")
            currentTheme = .default
        }
    }
    
    func saveTheme(_ theme: TerminalTheme) {
        do {
            let data = try JSONEncoder().encode(theme)
            UserDefaults.standard.set(data, forKey: "theme")
            currentTheme = theme
        } catch {
            print("Failed to save theme: \(error)")
        }
    }
    
    func loadSnippets() {
        guard let data = UserDefaults.standard.data(forKey: "snippets") else {
            snippets = []
            return
        }
        
        do {
            snippets = try JSONDecoder().decode([CommandSnippet].self, from: data)
        } catch {
            print("Failed to load snippets: \(error)")
            snippets = []
        }
    }
    
    func saveSnippets() {
        do {
            let data = try JSONEncoder().encode(snippets)
            UserDefaults.standard.set(data, forKey: "snippets")
        } catch {
            print("Failed to save snippets: \(error)")
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

enum SecureEnclaveKeyManager {
    static func keyTag(for keyID: UUID) -> String {
        "sh.glas.secureenclave.p256.\(keyID.uuidString)"
    }

    static func wrap(data: Data, keyTag: String) throws -> Data {
        guard let privateKey = try secureEnclavePrivateKey(keyTag: keyTag, createIfMissing: true) else {
            throw KeychainManager.KeychainError.secureEnclaveUnavailable
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KeychainManager.KeychainError.secureEnclaveOperationFailed
        }
        let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw KeychainManager.KeychainError.secureEnclaveOperationFailed
        }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &error) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? KeychainManager.KeychainError.secureEnclaveOperationFailed
        }
        return wrapped
    }

    static func unwrap(wrapped: Data, keyTag: String) throws -> Data {
        guard let privateKey = try secureEnclavePrivateKey(keyTag: keyTag, createIfMissing: false) else {
            throw KeychainManager.KeychainError.secureEnclaveUnavailable
        }
        let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw KeychainManager.KeychainError.secureEnclaveOperationFailed
        }
        var error: Unmanaged<CFError>?
        guard let unwrapped = SecKeyCreateDecryptedData(privateKey, algorithm, wrapped as CFData, &error) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? KeychainManager.KeychainError.secureEnclaveOperationFailed
        }
        return unwrapped
    }

    static func deleteKeyIfPresent(keyTag: String) {
        let tagData = keyTag.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func secureEnclavePrivateKey(keyTag: String, createIfMissing: Bool) throws -> SecKey? {
        let tagData = keyTag.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as! SecKey? {
            return key
        }
        if !createIfMissing {
            return nil
        }

        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            SecretStoreConstants.accessibility,
            [.privateKeyUsage, .userPresence],
            &error
        )
        guard let access else {
            throw (error?.takeRetainedValue() as Error?) ?? KeychainManager.KeychainError.secureEnclaveOperationFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessControl as String: access
            ]
        ]
        guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw (error?.takeRetainedValue() as Error?) ?? KeychainManager.KeychainError.secureEnclaveUnavailable
        }
        return created
    }
}

// MARK: - Keychain Manager

enum KeychainManager {
    private static let secureEnclaveSealedService = "sh.glas.sshkeys.sealedp256"
    private static let secureEnclaveTagService = "sh.glas.sshkeys.sealedp256.tag"
    
    static func savePassword(_ password: String, for server: ServerConfiguration) throws {
        let account = "\(server.username)@\(server.host):\(server.port)"
        let data = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "sh.glas.passwords",
            kSecAttrAccessible as String: SecretStoreConstants.accessibility,
            kSecAttrComment as String: SecretStoreConstants.migrationMarkerComment,
            kSecValueData as String: data
        ]
        
        // Delete existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave
        }
    }
    
    static func retrievePassword(for server: ServerConfiguration) throws -> String {
        let account = "\(server.username)@\(server.host):\(server.port)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "sh.glas.passwords",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        
        return password
    }
    
    static func deletePassword(for server: ServerConfiguration) throws {
        let account = "\(server.username)@\(server.host):\(server.port)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "sh.glas.passwords"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete
        }
    }

    static func saveSSHKey(_ privateKey: String, passphrase: String?, for keyID: UUID) throws {
        try saveGenericPassword(privateKey, account: keyID.uuidString, service: "sh.glas.sshkeys.private")
        if let passphrase, !passphrase.isEmpty {
            try saveGenericPassword(passphrase, account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
        } else {
            try? deleteGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
        }
    }

    static func retrieveSSHKey(for keyID: UUID) throws -> SSHKeyMaterial {
        if let privateKey = try? retrieveGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.private") {
            let passphrase = try? retrieveGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
            return SSHKeyMaterial(privateKey: privateKey, passphrase: passphrase)
        }

        if let (wrapped, keyTag) = try? retrieveSecureEnclaveWrappedP256(for: keyID) {
            let raw = try SecureEnclaveKeyManager.unwrap(wrapped: wrapped, keyTag: keyTag)
            let marker = "SECURE_ENCLAVE_P256:\(raw.base64EncodedString())"
            return SSHKeyMaterial(privateKey: marker, passphrase: nil)
        }

        throw KeychainError.notFound
    }

    static func deleteSSHKey(for keyID: UUID) throws {
        try deleteGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.private")
        try? deleteGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
        if let keyTag = try? retrieveGenericPassword(account: keyID.uuidString, service: secureEnclaveTagService) {
            SecureEnclaveKeyManager.deleteKeyIfPresent(keyTag: keyTag)
        }
        try? deleteGenericData(account: keyID.uuidString, service: secureEnclaveSealedService)
        try? deleteGenericPassword(account: keyID.uuidString, service: secureEnclaveTagService)
    }

    static func saveSecureEnclaveWrappedP256(_ wrapped: Data, keyTag: String, for keyID: UUID) throws {
        try saveGenericData(wrapped, account: keyID.uuidString, service: secureEnclaveSealedService)
        try saveGenericPassword(keyTag, account: keyID.uuidString, service: secureEnclaveTagService)
    }

    static func retrieveSecureEnclaveWrappedP256(for keyID: UUID) throws -> (wrapped: Data, keyTag: String) {
        let wrapped = try retrieveGenericData(account: keyID.uuidString, service: secureEnclaveSealedService)
        let keyTag = try retrieveGenericPassword(account: keyID.uuidString, service: secureEnclaveTagService)
        return (wrapped, keyTag)
    }

    private static func saveGenericPassword(_ value: String, account: String, service: String) throws {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: SecretStoreConstants.accessibility,
            kSecAttrComment as String: SecretStoreConstants.migrationMarkerComment,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave
        }
    }

    private static func retrieveGenericPassword(account: String, service: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        return value
    }

    private static func saveGenericData(_ data: Data, account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: SecretStoreConstants.accessibility,
            kSecAttrComment as String: SecretStoreConstants.migrationMarkerComment,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave
        }
    }

    private static func retrieveGenericData(account: String, service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.notFound
        }
        return data
    }

    private static func deleteGenericPassword(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete
        }
    }

    private static func deleteGenericData(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unableToDelete
        }
    }
    
    enum KeychainError: Error {
        case unableToSave
        case notFound
        case unableToDelete
        case unsupportedSSHKeyType
        case secureEnclaveUnavailable
        case secureEnclaveOperationFailed
    }
}

extension KeychainManager.KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unableToSave:
            return "Unable to save secure item in Keychain."
        case .notFound:
            return "Requested secure item was not found in Keychain."
        case .unableToDelete:
            return "Unable to delete secure item from Keychain."
        case .unsupportedSSHKeyType:
            return "Unsupported SSH key type. Use RSA or ED25519."
        case .secureEnclaveUnavailable:
            return "Secure Enclave is unavailable on this device."
        case .secureEnclaveOperationFailed:
            return "Secure Enclave operation failed."
        }
    }
}

// MARK: - Port Forward Manager

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
