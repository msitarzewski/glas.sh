//
//  ServerManager.swift
//  glas.sh
//
//  Manages server configurations persistence and lifecycle
//

import SwiftUI
import Foundation
import Observation
import WidgetKit
import os
import GlasSecretStore

struct HostTrustMigrationReport: Codable, Equatable {
    enum State: String, Codable {
        case verified
        case completed
        case failed
    }

    let fromVersion: Int
    let toVersion: Int
    let state: State
    let globalSourceCount: Int
    let serverSourceCount: Int
    let uniqueCandidateCount: Int
    let duplicateCount: Int
    let migratedCount: Int
    let alreadyPresentCount: Int
    let verifiedCount: Int
    let failedCount: Int
    let failureCode: String?
    let recordedAt: Date
}

@MainActor
struct HostTrustMigrationStore {
    let save: (PinnedSSHHostKey) throws -> Void
    let allRecords: () throws -> [PinnedSSHHostKey]

    static let live = HostTrustMigrationStore(
        save: KeychainManager.savePinnedHostKey,
        allRecords: KeychainManager.allPinnedHostKeys
    )
}

@MainActor
struct ServerPasswordStore {
    let retrieve: (UUID) throws -> String
    let save: (String, UUID) throws -> Void
    let delete: (UUID) throws -> Void

    static let live = ServerPasswordStore(
        retrieve: { serverID in
            try KeychainManager.retrievePassword(for: ServerPasswordStore.passwordReference(for: serverID))
        },
        save: { password, serverID in
            try KeychainManager.savePassword(password, for: ServerPasswordStore.passwordReference(for: serverID))
        },
        delete: { serverID in
            try KeychainManager.deletePassword(for: ServerPasswordStore.passwordReference(for: serverID))
        }
    )

    private static func passwordReference(for serverID: UUID) -> ServerConfiguration {
        ServerConfiguration(id: serverID, name: "Credential", host: "", username: "")
    }
}

struct ServerCredentialDeletionJournal: Codable, Equatable {
    enum Operation: String, Codable, Equatable {
        case deleteServer
        case removePasswordAuthentication
    }

    struct Entry: Codable, Equatable {
        let serverID: UUID
        let operation: Operation
        let createdAt: Date
    }

    static let currentVersion = 1
    let version: Int
    var entries: [Entry]
}

private enum HostTrustMigrationError: LocalizedError {
    case malformedGlobalSource
    case conflictingKeys
    case keychainReadbackMismatch
    case persistenceReadbackMismatch

    var errorDescription: String? {
        switch self {
        case .malformedGlobalSource:
            return "The global legacy host-trust source could not be decoded."
        case .conflictingKeys:
            return "Multiple different legacy host keys exist for one endpoint."
        case .keychainReadbackMismatch:
            return "A migrated host key could not be verified in Keychain."
        case .persistenceReadbackMismatch:
            return "A migration persistence write could not be verified."
        }
    }

    var code: String {
        switch self {
        case .malformedGlobalSource: return "malformed-global-source"
        case .conflictingKeys: return "conflicting-keys"
        case .keychainReadbackMismatch: return "keychain-readback-mismatch"
        case .persistenceReadbackMismatch: return "persistence-readback-mismatch"
        }
    }
}

@MainActor
@Observable
class ServerManager {
    var servers: [ServerConfiguration] = []
    private(set) var serverCatalogLoadError: ServerManagerError?

    static let currentHostTrustMigrationVersion = 1
    static let credentialDeletionJournalDefaultsKey = "serverCredentialDeletionJournal"
    static let maximumCredentialDeletionJournalEntries = 128
    static let maximumCredentialDeletionJournalBytes = 64 * 1024
    static let maximumServerCatalogBytes = 1024 * 1024

    private var hasLoadedServers = false
    private let defaults: UserDefaults
    private let hostTrustStore: HostTrustMigrationStore
    private let credentialMigrationStore: CredentialMigrationStore
    private let credentialMigrationMetadata: CredentialMigrationMetadata
    private let passwordStore: ServerPasswordStore
    private let serverDataWriter: (Data) -> Void

    init(
        loadImmediately: Bool = true,
        defaults: UserDefaults? = nil,
        hostTrustStore: HostTrustMigrationStore? = nil,
        credentialMigrationStore: CredentialMigrationStore? = nil,
        credentialMigrationMetadata: CredentialMigrationMetadata = .unavailable,
        passwordStore: ServerPasswordStore? = nil,
        serverDataWriter: ((Data) -> Void)? = nil
    ) {
        self.defaults = defaults ?? SharedDefaults.defaults
        self.hostTrustStore = hostTrustStore ?? .live
        self.credentialMigrationStore = credentialMigrationStore
            ?? .live(defaults: defaults ?? SharedDefaults.defaults)
        self.credentialMigrationMetadata = credentialMigrationMetadata
        self.passwordStore = passwordStore ?? .live
        let resolvedDefaults = defaults ?? SharedDefaults.defaults
        self.serverDataWriter = serverDataWriter ?? { data in
            resolvedDefaults.set(data, forKey: UserDefaultsKeys.servers)
        }
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
        do {
            let loadedServers: [ServerConfiguration]
            let persistedCatalogObject = defaults.object(forKey: UserDefaultsKeys.servers)
            let persistedCatalog = defaults.data(forKey: UserDefaultsKeys.servers)
            if let data = persistedCatalog {
                guard data.count <= Self.maximumServerCatalogBytes else {
                    throw ServerManagerError.invalidServerCatalog
                }
                loadedServers = try JSONDecoder().decode([ServerConfiguration].self, from: data)
            } else if persistedCatalogObject == nil {
                loadedServers = []
            } else {
                // UserDefaults returns nil from data(forKey:) for a value of the
                // wrong persisted type. That is corruption, not an empty catalog.
                throw ServerManagerError.invalidServerCatalog
            }
            servers = loadedServers
            serverCatalogLoadError = nil
            do {
                if defaults.data(forKey: Self.credentialDeletionJournalDefaultsKey) != nil,
                   persistedCatalog == nil {
                    throw ServerManagerError.invalidServerCatalog
                }
                try reconcileCredentialDeletionJournal()
            } catch {
                Logger.keychain.error("Server credential deletion recovery did not complete: \(error.localizedDescription)")
            }
            migrateLegacyCredentialsIfNeeded(from: servers)
            migrateLegacyHostTrustIfNeeded(from: servers)
        } catch {
            Logger.servers.error("Failed to load servers: \(error)")
            // Retain both the previously verified in-memory catalog and a durable
            // failure state. Mutations must not reinterpret unreadable bytes as []
            // and overwrite the only remaining copy.
            serverCatalogLoadError = .invalidServerCatalog
        }
    }

    private func migrateLegacyCredentialsIfNeeded(from loadedServers: [ServerConfiguration]) {
        do {
            _ = try KeychainManager.runCredentialMigrationIfNeeded(
                servers: loadedServers,
                metadata: credentialMigrationMetadata,
                store: credentialMigrationStore
            )
        } catch {
            Logger.keychain.error("Credential namespace migration did not complete: \(error.localizedDescription)")
        }
    }

    func saveServers() {
        do {
            try persistServersAndVerify(servers)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Logger.servers.error("Failed to save servers: \(error)")
        }
    }

    func persistServersOrThrow() throws {
        try persistServersAndVerify(servers)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func addServer(_ server: ServerConfiguration) {
        do {
            try addServerOrThrow(server)
        } catch {
            Logger.servers.error("Failed to add server: \(error.localizedDescription)")
        }
    }

    func updateServer(_ server: ServerConfiguration) {
        do {
            try updateServerOrThrow(server)
        } catch {
            Logger.servers.error("Failed to update server: \(error.localizedDescription)")
        }
    }

    func addServerOrThrow(_ server: ServerConfiguration, password: String? = nil) throws {
        try ensureServerCatalogAvailable()
        guard !servers.contains(where: { $0.id == server.id }) else {
            throw ServerManagerError.serverAlreadyExists
        }
        let candidateServers = servers + [server]
        if let password {
            try stagePasswordAndPersist(password, for: server, candidateServers: candidateServers)
        } else {
            try persistServerMutation(candidateServers)
        }
    }

    func updateServerOrThrow(_ server: ServerConfiguration, password: String? = nil) throws {
        try ensureServerCatalogAvailable()
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else {
            throw ServerManagerError.serverNotFound
        }
        let originalServer = servers[index]
        var candidateServers = servers
        candidateServers[index] = server

        if let password {
            try stagePasswordAndPersist(password, for: server, candidateServers: candidateServers)
        } else if originalServer.authMethod == .password && server.authMethod != .password {
            try removePasswordAndPersist(
                for: originalServer,
                candidateServers: candidateServers
            )
        } else {
            try persistServerMutation(candidateServers)
        }
    }

    func password(for server: ServerConfiguration) throws -> String {
        try passwordStore.retrieve(server.id)
    }

    func server(for id: UUID) -> ServerConfiguration? {
        servers.first { $0.id == id }
    }

    func deleteServer(_ server: ServerConfiguration) throws {
        try ensureServerCatalogAvailable()
        guard servers.contains(where: { $0.id == server.id }) else {
            throw ServerManagerError.serverNotFound
        }
        let originalServers = servers
        let remainingServers = servers.filter { $0.id != server.id }
        let passwordSnapshot = try snapshotPassword(for: server.id)
        var journal = try loadCredentialDeletionJournal()
        if let existing = journal.entries.first(where: { $0.serverID == server.id }) {
            guard existing.operation == .deleteServer else {
                throw ServerManagerError.invalidDeletionJournal
            }
        } else {
            guard journal.entries.count < Self.maximumCredentialDeletionJournalEntries else {
                throw ServerManagerError.deletionJournalFull
            }
            journal.entries.append(.init(
                serverID: server.id,
                operation: .deleteServer,
                createdAt: Date()
            ))
            try persistCredentialDeletionJournal(journal)
        }

        do {
            try persistServersAndVerify(remainingServers)
            try deletePasswordAndVerifyAbsence(for: server.id)
            journal.entries.removeAll { $0.serverID == server.id }
            try persistCredentialDeletionJournal(journal)
        } catch {
            do {
                try restorePassword(passwordSnapshot, for: server.id)
                try persistServersAndVerify(originalServers)
                journal.entries.removeAll { $0.serverID == server.id }
                try persistCredentialDeletionJournal(journal)
            } catch {
                throw ServerManagerError.rollbackFailed
            }
            throw error
        }
        servers = remainingServers
        WidgetCenter.shared.reloadAllTimelines()
    }

    func updateLastConnected(_ serverID: UUID) {
        do {
            try ensureServerCatalogAvailable()
            guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
            var candidateServers = servers
            candidateServers[index].lastConnected = Date()
            try persistServerMutation(candidateServers)
        } catch {
            Logger.servers.error("Failed to update recent server metadata: \(error.localizedDescription)")
        }
    }

    func toggleFavorite(_ server: ServerConfiguration) {
        do {
            try ensureServerCatalogAvailable()
            guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
            var candidateServers = servers
            candidateServers[index].isFavorite.toggle()
            try persistServerMutation(candidateServers)
        } catch {
            Logger.servers.error("Failed to update favorite server metadata: \(error.localizedDescription)")
        }
    }

    func trustHostKey(_ challenge: HostKeyTrustChallenge, for serverID: UUID) throws {
        try ensureServerCatalogAvailable()
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            throw ServerManagerError.serverNotFound
        }

        // Replacing trust for an endpoint must revoke every prior key for that
        // endpoint. Keeping an old key active after the user accepts a changed
        // fingerprint defeats the meaning of the warning.
        try KeychainManager.replaceHostKey(with: challenge)

        servers[index].trustedHostKeys = nil
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

    private enum PasswordSnapshot {
        case absent
        case value(String)
    }

    private func snapshotPassword(for serverID: UUID) throws -> PasswordSnapshot {
        do {
            return .value(try passwordStore.retrieve(serverID))
        } catch SecretStoreError.notFound {
            return .absent
        }
    }

    private func stagePasswordAndPersist(
        _ password: String,
        for server: ServerConfiguration,
        candidateServers: [ServerConfiguration]
    ) throws {
        let originalServers = servers
        let snapshot = try snapshotPassword(for: server.id)
        do {
            try passwordStore.save(password, server.id)
            guard try passwordStore.retrieve(server.id) == password else {
                throw ServerManagerError.credentialReadbackMismatch
            }
            try persistServersAndVerify(candidateServers)
        } catch {
            do {
                try restorePassword(snapshot, for: server.id)
                try persistServersAndVerify(originalServers)
            } catch {
                throw ServerManagerError.rollbackFailed
            }
            throw error
        }
        servers = candidateServers
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func removePasswordAndPersist(
        for server: ServerConfiguration,
        candidateServers: [ServerConfiguration]
    ) throws {
        let originalServers = servers
        let snapshot = try snapshotPassword(for: server.id)
        var journal = try loadCredentialDeletionJournal()
        if let existing = journal.entries.first(where: { $0.serverID == server.id }) {
            guard existing.operation == .removePasswordAuthentication else {
                throw ServerManagerError.invalidDeletionJournal
            }
        } else {
            guard journal.entries.count < Self.maximumCredentialDeletionJournalEntries else {
                throw ServerManagerError.deletionJournalFull
            }
            journal.entries.append(.init(
                serverID: server.id,
                operation: .removePasswordAuthentication,
                createdAt: Date()
            ))
            try persistCredentialDeletionJournal(journal)
        }
        do {
            try persistServersAndVerify(candidateServers)
            try deletePasswordAndVerifyAbsence(for: server.id)
            journal.entries.removeAll { $0.serverID == server.id }
            try persistCredentialDeletionJournal(journal)
        } catch {
            do {
                try restorePassword(snapshot, for: server.id)
                try persistServersAndVerify(originalServers)
                journal.entries.removeAll { $0.serverID == server.id }
                try persistCredentialDeletionJournal(journal)
            } catch {
                throw ServerManagerError.rollbackFailed
            }
            throw error
        }
        servers = candidateServers
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persistServerMutation(_ candidateServers: [ServerConfiguration]) throws {
        try ensureServerCatalogAvailable()
        let originalServers = servers
        do {
            try persistServersAndVerify(candidateServers)
        } catch {
            do {
                try persistServersAndVerify(originalServers)
            } catch {
                throw ServerManagerError.rollbackFailed
            }
            throw error
        }
        servers = candidateServers
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func restorePassword(_ snapshot: PasswordSnapshot, for serverID: UUID) throws {
        switch snapshot {
        case .absent:
            do {
                try passwordStore.delete(serverID)
            } catch SecretStoreError.notFound {
                break
            }
            do {
                _ = try passwordStore.retrieve(serverID)
                throw ServerManagerError.credentialReadbackMismatch
            } catch SecretStoreError.notFound {
                return
            }
        case .value(let password):
            try passwordStore.save(password, serverID)
            guard try passwordStore.retrieve(serverID) == password else {
                throw ServerManagerError.credentialReadbackMismatch
            }
        }
    }

    private func deletePasswordAndVerifyAbsence(for serverID: UUID) throws {
        do {
            try passwordStore.delete(serverID)
        } catch SecretStoreError.notFound {
            // Absence is verified below through the same UUID-scoped store.
        }
        do {
            _ = try passwordStore.retrieve(serverID)
            throw ServerManagerError.credentialReadbackMismatch
        } catch SecretStoreError.notFound {
            return
        }
    }

    private func loadCredentialDeletionJournal() throws -> ServerCredentialDeletionJournal {
        guard let data = defaults.data(forKey: Self.credentialDeletionJournalDefaultsKey) else {
            return .init(version: ServerCredentialDeletionJournal.currentVersion, entries: [])
        }
        guard data.count <= Self.maximumCredentialDeletionJournalBytes,
              let journal = try? JSONDecoder().decode(ServerCredentialDeletionJournal.self, from: data),
              journal.version == ServerCredentialDeletionJournal.currentVersion,
              journal.entries.count <= Self.maximumCredentialDeletionJournalEntries,
              Set(journal.entries.map(\.serverID)).count == journal.entries.count else {
            throw ServerManagerError.invalidDeletionJournal
        }
        return journal
    }

    private func persistCredentialDeletionJournal(
        _ journal: ServerCredentialDeletionJournal
    ) throws {
        guard journal.version == ServerCredentialDeletionJournal.currentVersion,
              journal.entries.count <= Self.maximumCredentialDeletionJournalEntries,
              Set(journal.entries.map(\.serverID)).count == journal.entries.count else {
            throw ServerManagerError.invalidDeletionJournal
        }
        if journal.entries.isEmpty {
            defaults.removeObject(forKey: Self.credentialDeletionJournalDefaultsKey)
            guard defaults.data(forKey: Self.credentialDeletionJournalDefaultsKey) == nil else {
                throw ServerManagerError.persistenceReadbackMismatch
            }
            return
        }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= Self.maximumCredentialDeletionJournalBytes else {
            throw ServerManagerError.deletionJournalFull
        }
        defaults.set(data, forKey: Self.credentialDeletionJournalDefaultsKey)
        guard let persistedData = defaults.data(forKey: Self.credentialDeletionJournalDefaultsKey),
              let persisted = try? JSONDecoder().decode(ServerCredentialDeletionJournal.self, from: persistedData),
              persisted == journal else {
            throw ServerManagerError.persistenceReadbackMismatch
        }
    }

    private func reconcileCredentialDeletionJournal() throws {
        var journal = try loadCredentialDeletionJournal()
        guard !journal.entries.isEmpty else { return }

        for entry in journal.entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            let persistedServer = servers.first { $0.id == entry.serverID }
            let metadataProvesCommit: Bool
            switch entry.operation {
            case .deleteServer:
                metadataProvesCommit = persistedServer == nil
            case .removePasswordAuthentication:
                metadataProvesCommit = persistedServer?.authMethod != .password
            }

            // Metadata is the commit marker. A journal interrupted before its
            // corresponding metadata change describes an aborted operation, so
            // the still-live password wins and the journal is cleared.
            if !metadataProvesCommit {
                journal.entries.removeAll { $0.serverID == entry.serverID }
                try persistCredentialDeletionJournal(journal)
                continue
            }

            try deletePasswordAndVerifyAbsence(for: entry.serverID)
            journal.entries.removeAll { $0.serverID == entry.serverID }
            try persistCredentialDeletionJournal(journal)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func migrateLegacyHostTrustIfNeeded(from loadedServers: [ServerConfiguration]) {
        let previousVersion = defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion)
        let globalData = defaults.data(forKey: UserDefaultsKeys.trustedHostKeys)
        let hasServerEntries = loadedServers.contains { $0.trustedHostKeys != nil }
        guard previousVersion < Self.currentHostTrustMigrationVersion || globalData != nil || hasServerEntries else {
            return
        }

        var globalSourceCount = 0
        let serverSourceCount = loadedServers.reduce(0) { $0 + ($1.trustedHostKeys?.count ?? 0) }
        var uniqueCandidateCount = 0
        var duplicateCount = 0
        var migratedCount = 0
        var alreadyPresentCount = 0
        var verifiedCount = 0

        do {
            let globalEntries: [TrustedHostKeyEntry]
            if let globalData {
                guard let decoded = try? JSONDecoder().decode([TrustedHostKeyEntry].self, from: globalData) else {
                    throw HostTrustMigrationError.malformedGlobalSource
                }
                globalEntries = decoded
            } else {
                globalEntries = []
            }
            globalSourceCount = globalEntries.count

            let allEntries = globalEntries + loadedServers.flatMap { $0.trustedHostKeys ?? [] }
            var candidatesByID: [String: PinnedSSHHostKey] = [:]
            for entry in allEntries {
                let candidate = try KeychainManager.pinnedHostKey(from: entry)
                if let existing = candidatesByID[candidate.storageAccount] {
                    duplicateCount += 1
                    let firstSeen = min(existing.createdAt, candidate.createdAt)
                    candidatesByID[candidate.storageAccount] = PinnedSSHHostKey(
                        host: existing.host,
                        port: existing.port,
                        algorithm: existing.algorithm,
                        publicKeyData: existing.publicKeyData,
                        sha256Fingerprint: existing.sha256Fingerprint,
                        createdAt: firstSeen,
                        lastSeenAt: max(existing.lastSeenAt, candidate.lastSeenAt)
                    )
                } else {
                    candidatesByID[candidate.storageAccount] = candidate
                }
            }

            let candidates = candidatesByID.values.sorted { $0.storageAccount < $1.storageAccount }
            uniqueCandidateCount = candidates.count
            let endpointGroups = Dictionary(grouping: candidates) { $0.lookupAccount }
            guard endpointGroups.values.allSatisfy({ $0.count <= 1 }) else {
                throw HostTrustMigrationError.conflictingKeys
            }

            let recordsBefore = try hostTrustStore.allRecords()
            guard candidates.allSatisfy({ candidate in
                recordsBefore.allSatisfy { record in
                    record.lookupAccount != candidate.lookupAccount
                        || record.storageAccount == candidate.storageAccount
                }
            }) else {
                throw HostTrustMigrationError.conflictingKeys
            }
            let recordIDsBefore = Set(recordsBefore.map(\.storageAccount))
            for candidate in candidates {
                if recordIDsBefore.contains(candidate.storageAccount) {
                    alreadyPresentCount += 1
                } else {
                    migratedCount += 1
                }
                try hostTrustStore.save(candidate)
            }

            let recordsAfter = try hostTrustStore.allRecords()
            for candidate in candidates {
                guard recordsAfter.contains(where: { record in
                    record.storageAccount == candidate.storageAccount
                        && record.host == candidate.host
                        && record.port == candidate.port
                        && record.algorithm == candidate.algorithm
                        && record.publicKeyData == candidate.publicKeyData
                        && record.sha256Fingerprint == candidate.sha256Fingerprint
                }) else {
                    throw HostTrustMigrationError.keychainReadbackMismatch
                }
                verifiedCount += 1
            }

            let verifiedReport = HostTrustMigrationReport(
                fromVersion: previousVersion,
                toVersion: Self.currentHostTrustMigrationVersion,
                state: .verified,
                globalSourceCount: globalSourceCount,
                serverSourceCount: serverSourceCount,
                uniqueCandidateCount: candidates.count,
                duplicateCount: duplicateCount,
                migratedCount: migratedCount,
                alreadyPresentCount: alreadyPresentCount,
                verifiedCount: verifiedCount,
                failedCount: 0,
                failureCode: nil,
                recordedAt: Date()
            )
            try persistReportAndVerify(verifiedReport)

            var sanitizedServers = loadedServers
            for index in sanitizedServers.indices {
                sanitizedServers[index].trustedHostKeys = nil
            }
            try commitLegacySourceRemoval(
                sanitizedServers: sanitizedServers,
                originalServers: loadedServers,
                originalGlobalData: globalData,
                originalMigrationVersion: previousVersion,
                verifiedReport: verifiedReport
            )
            servers = sanitizedServers
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            let failureCode = (error as? HostTrustMigrationError)?.code ?? "validation-or-store-failure"
            let failedReport = HostTrustMigrationReport(
                fromVersion: previousVersion,
                toVersion: Self.currentHostTrustMigrationVersion,
                state: .failed,
                globalSourceCount: globalSourceCount,
                serverSourceCount: serverSourceCount,
                uniqueCandidateCount: uniqueCandidateCount,
                duplicateCount: duplicateCount,
                migratedCount: migratedCount,
                alreadyPresentCount: alreadyPresentCount,
                verifiedCount: verifiedCount,
                failedCount: 1,
                failureCode: failureCode,
                recordedAt: Date()
            )
            do {
                try persistReportAndVerify(failedReport)
            } catch {
                Logger.servers.error("Host-trust migration failure report could not be persisted: \(error)")
            }
            Logger.servers.error("Host-trust migration did not complete: \(error)")
        }
    }

    private func commitLegacySourceRemoval(
        sanitizedServers: [ServerConfiguration],
        originalServers: [ServerConfiguration],
        originalGlobalData: Data?,
        originalMigrationVersion: Int,
        verifiedReport: HostTrustMigrationReport
    ) throws {
        let originalServersData = defaults.data(forKey: UserDefaultsKeys.servers)
        do {
            try persistServersAndVerify(sanitizedServers)
            defaults.removeObject(forKey: UserDefaultsKeys.trustedHostKeys)
            guard defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == nil else {
                throw HostTrustMigrationError.persistenceReadbackMismatch
            }

            let completedReport = HostTrustMigrationReport(
                fromVersion: verifiedReport.fromVersion,
                toVersion: verifiedReport.toVersion,
                state: .completed,
                globalSourceCount: verifiedReport.globalSourceCount,
                serverSourceCount: verifiedReport.serverSourceCount,
                uniqueCandidateCount: verifiedReport.uniqueCandidateCount,
                duplicateCount: verifiedReport.duplicateCount,
                migratedCount: verifiedReport.migratedCount,
                alreadyPresentCount: verifiedReport.alreadyPresentCount,
                verifiedCount: verifiedReport.verifiedCount,
                failedCount: 0,
                failureCode: nil,
                recordedAt: Date()
            )
            try persistReportAndVerify(completedReport)
            defaults.set(Self.currentHostTrustMigrationVersion, forKey: UserDefaultsKeys.hostTrustMigrationVersion)
            guard defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion)
                    == Self.currentHostTrustMigrationVersion else {
                throw HostTrustMigrationError.persistenceReadbackMismatch
            }
        } catch {
            if let originalServersData {
                defaults.set(originalServersData, forKey: UserDefaultsKeys.servers)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.servers)
            }
            if let originalGlobalData {
                defaults.set(originalGlobalData, forKey: UserDefaultsKeys.trustedHostKeys)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.trustedHostKeys)
            }
            if originalMigrationVersion > 0 {
                defaults.set(originalMigrationVersion, forKey: UserDefaultsKeys.hostTrustMigrationVersion)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.hostTrustMigrationVersion)
            }
            servers = originalServers
            throw error
        }
    }

    private func persistServersAndVerify(_ candidateServers: [ServerConfiguration]) throws {
        try ensureServerCatalogAvailable()
        let data = try JSONEncoder().encode(candidateServers)
        serverDataWriter(data)
        guard let persistedData = defaults.data(forKey: UserDefaultsKeys.servers),
              let persistedServers = try? JSONDecoder().decode([ServerConfiguration].self, from: persistedData),
              persistedServers == candidateServers else {
            throw ServerManagerError.persistenceReadbackMismatch
        }
        defaults.set(SharedDefaults.currentSchemaVersion, forKey: SharedDefaults.schemaVersionKey)
    }

    private func ensureServerCatalogAvailable() throws {
        if let serverCatalogLoadError {
            throw serverCatalogLoadError
        }
    }

    private func persistReportAndVerify(_ report: HostTrustMigrationReport) throws {
        let data = try JSONEncoder().encode(report)
        defaults.set(data, forKey: UserDefaultsKeys.hostTrustMigrationReport)
        guard let persistedData = defaults.data(forKey: UserDefaultsKeys.hostTrustMigrationReport),
              let persistedReport = try? JSONDecoder().decode(HostTrustMigrationReport.self, from: persistedData),
              persistedReport == report else {
            throw HostTrustMigrationError.persistenceReadbackMismatch
        }
    }
}

enum ServerManagerError: LocalizedError, Equatable {
    case serverNotFound
    case serverAlreadyExists
    case persistenceReadbackMismatch
    case credentialReadbackMismatch
    case invalidDeletionJournal
    case invalidServerCatalog
    case deletionJournalFull
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .serverNotFound:
            return "The server configuration is no longer available."
        case .serverAlreadyExists:
            return "A server configuration with this identifier already exists."
        case .persistenceReadbackMismatch:
            return "The saved server configuration could not be verified."
        case .credentialReadbackMismatch:
            return "The UUID-scoped server credential could not be verified."
        case .invalidDeletionJournal:
            return "The pending server credential deletion journal is invalid."
        case .invalidServerCatalog:
            return "The persisted server catalog is missing, malformed, or too large for credential recovery."
        case .deletionJournalFull:
            return "Too many server credential deletions are pending recovery."
        case .rollbackFailed:
            return "The server change failed and its credential or configuration rollback could not be verified."
        }
    }
}
