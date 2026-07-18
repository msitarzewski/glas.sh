//
//  SSHHostTrustKeychainStore.swift
//  GlasSecretStore
//
//  Save/retrieve/delete pinned SSH server host keys by host and port.
//

import Foundation
import Security

public enum SSHHostTrustKeychainStore: Sendable {

    public static let defaultRotationHistoryLimit = 8

    public static func save(
        _ hostKey: PinnedSSHHostKey,
        config: SecretStoreConfiguration
    ) throws {
        try hostKey.validate()
        let data = try JSONEncoder().encode(hostKey)
        try KeychainOperations.saveData(
            data,
            account: hostKey.storageAccount,
            service: config.sshHostTrustService,
            config: config
        )
    }

    public static func save(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyData: Data,
        config: SecretStoreConfiguration
    ) throws {
        try save(
            PinnedSSHHostKey(
                host: host,
                port: port,
                algorithm: algorithm,
                publicKeyData: publicKeyData
            ),
            config: config
        )
    }

    public static func retrieve(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyData: Data,
        config: SecretStoreConfiguration
    ) throws -> PinnedSSHHostKey {
        let storageAccount = PinnedSSHHostKey.storageAccount(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData
        )
        let data = try KeychainOperations.retrieveData(
            account: storageAccount,
            service: config.sshHostTrustService,
            config: config
        )
        let hostKey = try JSONDecoder().decode(PinnedSSHHostKey.self, from: data)
        guard hostKey.matches(algorithm: algorithm, publicKeyData: publicKeyData) else {
            throw SecretStoreError.notFound
        }
        return hostKey
    }

    public static func records(
        host: String,
        port: Int,
        config: SecretStoreConfiguration
    ) throws -> [PinnedSSHHostKey] {
        let normalizedHost = PinnedSSHHostKey.normalizedHost(host)
        return try allPinnedHosts(config: config)
            .filter { $0.host == normalizedHost && $0.port == port }
    }

    /// Returns the only records permitted to authorize this endpoint. Legacy
    /// records decode as active generation zero, preserving existing pins until
    /// the first explicit rotation advances the endpoint generation.
    public static func authorizedRecords(
        host: String,
        port: Int,
        config: SecretStoreConfiguration
    ) throws -> [PinnedSSHHostKey] {
        let active = try records(host: host, port: port, config: config)
            .filter { $0.state == .active }
        guard let newestGeneration = active.map(\.generation).max() else {
            return []
        }
        return active.filter { $0.generation == newestGeneration }
    }

    /// Saves and verifies the replacement before superseding the prior active
    /// generation. Once readback succeeds, lower generations cannot authorize,
    /// even if a later history rewrite or pruning operation is interrupted.
    @discardableResult
    public static func replace(
        with hostKey: PinnedSSHHostKey,
        config: SecretStoreConfiguration,
        replacedAt: Date = Date(),
        historyLimit: Int = defaultRotationHistoryLimit
    ) throws -> PinnedSSHHostKey {
        guard historyLimit >= 0 else {
            throw SecretStoreError.encodingFailed
        }
        try hostKey.validate()
        let previous = try records(host: hostKey.host, port: hostKey.port, config: config)
        let greatestGeneration = previous.map(\.generation).max() ?? 0
        guard greatestGeneration < UInt64.max else {
            throw SecretStoreError.encodingFailed
        }

        let replacement = hostKey.activated(
            generation: greatestGeneration + 1,
            activatedAt: replacedAt
        )
        try save(replacement, config: config)
        let replacementReadback = try retrieve(
            host: replacement.host,
            port: replacement.port,
            algorithm: replacement.algorithm,
            publicKeyData: replacement.publicKeyData,
            config: config
        )
        guard replacementReadback == replacement else {
            throw SecretStoreError.unableToSave
        }

        for record in previous where record.state == .active && record.storageAccount != replacement.storageAccount {
            let revoked = record.revoked(
                at: replacedAt,
                replacedBy: replacement.sha256Fingerprint
            )
            try save(revoked, config: config)
            let readback = try retrieve(
                host: revoked.host,
                port: revoked.port,
                algorithm: revoked.algorithm,
                publicKeyData: revoked.publicKeyData,
                config: config
            )
            guard readback == revoked else {
                throw SecretStoreError.unableToSave
            }
        }

        let history = try records(host: replacement.host, port: replacement.port, config: config)
            .filter { $0.state == .revoked }
            .sorted { lhs, rhs in
                let lhsDate = lhs.revokedAt ?? lhs.lastSeenAt
                let rhsDate = rhs.revokedAt ?? rhs.lastSeenAt
                if lhsDate == rhsDate {
                    return lhs.sha256Fingerprint > rhs.sha256Fingerprint
                }
                return lhsDate > rhsDate
            }
        for expired in history.dropFirst(historyLimit) {
            try delete(expired, config: config)
        }

        let authorized = try authorizedRecords(
            host: replacement.host,
            port: replacement.port,
            config: config
        )
        guard authorized == [replacementReadback] else {
            throw SecretStoreError.unableToSave
        }
        return replacementReadback
    }

    public static func contains(
        host: String,
        port: Int,
        config: SecretStoreConfiguration
    ) -> Bool {
        (try? authorizedRecords(host: host, port: port, config: config).isEmpty) == false
    }

    public static func delete(
        host: String,
        port: Int,
        config: SecretStoreConfiguration
    ) throws {
        try KeychainOperations.deleteItem(
            account: PinnedSSHHostKey.lookupAccount(host: host, port: port),
            service: config.sshHostTrustService,
            config: config
        )
        for hostKey in try records(host: host, port: port, config: config) {
            try KeychainOperations.deleteItem(
                account: hostKey.storageAccount,
                service: config.sshHostTrustService,
                config: config
            )
        }
    }

    private static func delete(
        _ hostKey: PinnedSSHHostKey,
        config: SecretStoreConfiguration
    ) throws {
        try KeychainOperations.deleteItem(
            account: hostKey.storageAccount,
            service: config.sshHostTrustService,
            config: config
        )
    }

    public static func allPinnedHosts(config: SecretStoreConfiguration) throws -> [PinnedSSHHostKey] {
        try KeychainOperations.allItems(service: config.sshHostTrustService, config: config)
            .map { item in
                guard let data = item[kSecValueData as String] as? Data else {
                    throw SecretStoreError.encodingFailed
                }
                return try JSONDecoder().decode(PinnedSSHHostKey.self, from: data)
            }
            .sorted { lhs, rhs in
                if lhs.host == rhs.host && lhs.port == rhs.port {
                    if lhs.algorithm == rhs.algorithm {
                        return lhs.sha256Fingerprint < rhs.sha256Fingerprint
                    }
                    return lhs.algorithm < rhs.algorithm
                }
                if lhs.host == rhs.host { return lhs.port < rhs.port }
                return lhs.host < rhs.host
            }
    }

    public static func evaluate(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyData: Data,
        config: SecretStoreConfiguration,
        lastSeenAt: Date = Date()
    ) throws -> SSHHostTrustEvaluation {
        let current = PinnedSSHHostKey(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData
        )
        try current.validate()
        let previous = try authorizedRecords(host: host, port: port, config: config)
        guard !previous.isEmpty else {
            return .notPinned
        }
        if let matched = previous.first(where: { $0.matches(algorithm: algorithm, publicKeyData: publicKeyData) }) {
            let refreshed = matched.refreshed(lastSeenAt: lastSeenAt)
            try save(refreshed, config: config)
            let readback = try retrieve(
                host: refreshed.host,
                port: refreshed.port,
                algorithm: refreshed.algorithm,
                publicKeyData: refreshed.publicKeyData,
                config: config
            )
            guard readback == refreshed else {
                throw SecretStoreError.unableToSave
            }
            return .trusted(readback)
        }
        return .changed(previous: previous, current: current)
    }
}
