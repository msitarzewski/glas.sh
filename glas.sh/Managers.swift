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
    let createdAt: Date
}

struct SSHKeyMaterial {
    let privateKey: String
    let passphrase: String?
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
    private var hasLoadedPersistentState = false
    
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
        if keyType == .rsa {
            throw KeychainManager.KeychainError.rsaSupportComingSoon
        }
        guard keyType == .ed25519 else {
            throw KeychainManager.KeychainError.unsupportedSSHKeyType
        }
        let key = StoredSSHKey(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: keyType.description,
            createdAt: Date()
        )
        try KeychainManager.saveSSHKey(privateKey, passphrase: passphrase, for: key.id)
        sshKeys.append(key)
        saveSSHKeys()
        return key
    }

    func renameSSHKey(_ keyID: UUID, name: String) {
        guard let index = sshKeys.firstIndex(where: { $0.id == keyID }) else { return }
        sshKeys[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSSHKeys()
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

// MARK: - Keychain Manager

enum KeychainManager {
    
    static func savePassword(_ password: String, for server: ServerConfiguration) throws {
        let account = "\(server.username)@\(server.host):\(server.port)"
        let data = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "sh.glas.passwords",
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
        let privateKey = try retrieveGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.private")
        let passphrase = try? retrieveGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
        return SSHKeyMaterial(privateKey: privateKey, passphrase: passphrase)
    }

    static func deleteSSHKey(for keyID: UUID) throws {
        try deleteGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.private")
        try? deleteGenericPassword(account: keyID.uuidString, service: "sh.glas.sshkeys.passphrase")
    }

    private static func saveGenericPassword(_ value: String, account: String, service: String) throws {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
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
    
    enum KeychainError: Error {
        case unableToSave
        case notFound
        case unableToDelete
        case unsupportedSSHKeyType
        case rsaSupportComingSoon
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
            return "Unsupported SSH key type. Use ED25519."
        case .rsaSupportComingSoon:
            return "RSA key auth support is coming soon. Please use an ED25519 key for now."
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
