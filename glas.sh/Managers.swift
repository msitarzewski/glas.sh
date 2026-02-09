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
    
    enum KeychainError: Error {
        case unableToSave
        case notFound
        case unableToDelete
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
