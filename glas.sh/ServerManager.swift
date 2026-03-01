//
//  ServerManager.swift
//  glas.sh
//
//  Manages server configurations persistence and lifecycle
//

import SwiftUI
import Foundation
import Observation
import os

@MainActor
@Observable
class ServerManager {
    var servers: [ServerConfiguration] = []

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
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.servers) else {
            servers = []
            return
        }

        do {
            servers = try JSONDecoder().decode([ServerConfiguration].self, from: data)
        } catch {
            Logger.servers.error("Failed to load servers: \(error)")
            servers = []
        }
    }

    func saveServers() {
        do {
            let data = try JSONEncoder().encode(servers)
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.servers)
        } catch {
            Logger.servers.error("Failed to save servers: \(error)")
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
