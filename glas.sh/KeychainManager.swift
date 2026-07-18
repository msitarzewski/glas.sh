//
//  KeychainManager.swift
//  glas.sh
//
//  Thin wrapper delegating to GlasSecretStore's KeychainOperations and SSHKeyKeychainStore.
//  Provides app-specific convenience methods while sharing Keychain with glassdb.
//

import Foundation
import GlasSecretStore
import os

struct CredentialMigrationReport: Codable, Equatable {
    enum State: String, Codable {
        case verified
        case completed
        case failed
    }

    let fromVersion: Int
    let toVersion: Int
    let state: State
    let serverProfileCount: Int
    let uniqueServerTupleCount: Int
    let duplicateServerProfileCount: Int
    let legacyServerSourceCount: Int
    let exclusiveServerTupleCount: Int
    let ambiguousServerTupleCount: Int
    let unavailableMetadataTupleCount: Int
    let migratedServerDestinationCount: Int
    let alreadyPresentDestinationCount: Int
    let conflictCount: Int
    let tailscaleLegacySourceCount: Int
    let tailscaleMigratedCredentialCount: Int
    let verifiedDestinationCount: Int
    let deletedLegacySourceCount: Int
    let failedCount: Int
    let failureCode: String?
    let recordedAt: Date
}

enum CredentialMigrationMetadata: Equatable {
    /// glassdb currently keeps its profiles in its private standard defaults,
    /// which glas.sh cannot inspect. `available` is reserved for an authoritative
    /// shared metadata snapshot once both apps publish one.
    case unavailable
    case available(glassDBLegacyPasswordAccounts: Set<String>)
}

struct CredentialMigrationStore {
    let read: (String) throws -> Data?
    let addIfAbsent: (Data, String) throws -> Bool
    let loadReport: () throws -> CredentialMigrationReport?
    let saveReport: (CredentialMigrationReport) throws -> Void
    let removeReport: () throws -> Void
    let loadVersion: () -> Int
    let saveVersion: (Int) throws -> Void

    static func live(defaults: UserDefaults) -> CredentialMigrationStore {
        CredentialMigrationStore(
            read: { account in
                do {
                    return try KeychainOperations.retrieveData(
                        account: account,
                        service: KeychainManager.config.passwordsService,
                        config: KeychainManager.config
                    )
                } catch SecretStoreError.notFound {
                    return nil
                }
            },
            addIfAbsent: { data, account in
                try KeychainOperations.addDataIfAbsent(
                    data,
                    account: account,
                    service: KeychainManager.config.passwordsService,
                    config: KeychainManager.config
                )
            },
            loadReport: {
                guard let data = defaults.data(forKey: UserDefaultsKeys.credentialMigrationReport) else {
                    return nil
                }
                return try JSONDecoder().decode(CredentialMigrationReport.self, from: data)
            },
            saveReport: { report in
                let data = try JSONEncoder().encode(report)
                defaults.set(data, forKey: UserDefaultsKeys.credentialMigrationReport)
                guard defaults.data(forKey: UserDefaultsKeys.credentialMigrationReport) == data else {
                    throw CredentialMigrationError.persistenceReadbackMismatch
                }
            },
            removeReport: {
                defaults.removeObject(forKey: UserDefaultsKeys.credentialMigrationReport)
                guard defaults.data(forKey: UserDefaultsKeys.credentialMigrationReport) == nil else {
                    throw CredentialMigrationError.persistenceReadbackMismatch
                }
            },
            loadVersion: {
                defaults.integer(forKey: UserDefaultsKeys.credentialMigrationVersion)
            },
            saveVersion: { version in
                defaults.set(version, forKey: UserDefaultsKeys.credentialMigrationVersion)
                guard defaults.integer(forKey: UserDefaultsKeys.credentialMigrationVersion) == version else {
                    throw CredentialMigrationError.persistenceReadbackMismatch
                }
            }
        )
    }
}

struct TailscaleOAuthCredentialStore {
    let read: (String) throws -> Data?
    let addIfAbsent: (Data, String) throws -> Bool
    let delete: (String) throws -> Void

    static let live = TailscaleOAuthCredentialStore(
        read: { account in
            do {
                return try KeychainOperations.retrieveData(
                    account: account,
                    service: KeychainManager.config.passwordsService,
                    config: KeychainManager.config
                )
            } catch SecretStoreError.notFound {
                return nil
            }
        },
        addIfAbsent: { data, account in
            try KeychainOperations.addDataIfAbsent(
                data,
                account: account,
                service: KeychainManager.config.passwordsService,
                config: KeychainManager.config
            )
        },
        delete: { account in
            try KeychainOperations.deleteItem(
                account: account,
                service: KeychainManager.config.passwordsService,
                config: KeychainManager.config
            )
        }
    )
}

enum CredentialMigrationError: LocalizedError {
    case keychainReadbackMismatch
    case persistenceReadbackMismatch
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .keychainReadbackMismatch:
            return "A migrated credential could not be verified in Keychain."
        case .persistenceReadbackMismatch:
            return "The credential migration report or version could not be verified."
        case .rollbackFailed:
            return "Credential migration failed and its rollback could not be fully verified."
        }
    }

    var code: String {
        switch self {
        case .keychainReadbackMismatch: return "keychain-readback-mismatch"
        case .persistenceReadbackMismatch: return "persistence-readback-mismatch"
        case .rollbackFailed: return "rollback-failed"
        }
    }
}

enum KeychainManager {

    private static let accessGroupInfoKey = "GlasKeychainAccessGroup"
    private static let terminalAccountPrefix = "terminal"
    static let currentCredentialMigrationVersion = 1
    static let legacyTailscaleAPIKeyAccount = "tailscale-api-key"
    static let legacyTailscaleOAuthClientIDAccount = "tailscale-oauth-client-id"
    static let legacyTailscaleOAuthClientSecretAccount = "tailscale-oauth-client-secret"

    static let config = SecretStoreConfiguration(
        serviceNamePrefix: "sh.glas",
        accessGroup: resolvedAccessGroup,
        useDataProtectionKeychain: true
    )

    private static var resolvedAccessGroup: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: accessGroupInfoKey) as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    // MARK: - Server Password

    static func savePassword(_ password: String, for server: ServerConfiguration) throws {
        let account = serverPasswordAccount(for: server.id)
        try KeychainOperations.savePassword(password, account: account, service: config.passwordsService, config: config)
    }

    static func retrievePassword(for server: ServerConfiguration) throws -> String {
        try KeychainOperations.retrievePassword(
            account: serverPasswordAccount(for: server.id),
            service: config.passwordsService,
            config: config
        )
    }

    static func deletePassword(for server: ServerConfiguration) throws {
        let account = serverPasswordAccount(for: server.id)
        try KeychainOperations.deletePassword(account: account, service: config.passwordsService, config: config)
    }

    /// Stable per-profile namespace. Deliberately does not use the legacy
    /// `username@host:port` tuple because that account may belong to glassdb in
    /// the shared Keychain service.
    static func serverPasswordAccount(for serverID: UUID) -> String {
        "\(terminalAccountPrefix).server-password.\(serverID.uuidString.lowercased())"
    }

    static func legacyServerPasswordAccount(for server: ServerConfiguration) -> String {
        "\(server.username)@\(server.host):\(server.port)"
    }

    // MARK: - SSH Keys

    static func saveSSHKey(_ privateKey: String, passphrase: String?, for keyID: UUID) throws {
        let secureKey = SecureBytes(Data(privateKey.utf8))
        let securePassphrase = passphrase.map { SecureBytes(Data($0.utf8)) }
        try SSHKeyKeychainStore.save(privateKey: secureKey, passphrase: securePassphrase, for: keyID, config: config)
    }

    static func retrieveSSHKey(for keyID: UUID) throws -> SSHKeyMaterial {
        try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
    }

    static func deleteSSHKey(for keyID: UUID) throws {
        try SSHKeyKeychainStore.delete(for: keyID, config: config)
    }

    // MARK: - SSH Host Trust

    static func saveHostKey(_ challenge: HostKeyTrustChallenge) throws {
        let publicKeyData = try validatedHostKeyData(
            base64: challenge.keyDataBase64,
            claimedFingerprint: challenge.fingerprintSHA256
        )
        let hostKey = PinnedSSHHostKey(
            host: challenge.host,
            port: challenge.port,
            algorithm: challenge.algorithm,
            publicKeyData: publicKeyData
        )
        try hostKey.validate()
        try SSHHostTrustKeychainStore.save(hostKey, config: config)
    }

    static func replaceHostKey(with challenge: HostKeyTrustChallenge) throws {
        let publicKeyData = try validatedHostKeyData(
            base64: challenge.keyDataBase64,
            claimedFingerprint: challenge.fingerprintSHA256
        )
        let replacement = PinnedSSHHostKey(
            host: challenge.host,
            port: challenge.port,
            algorithm: challenge.algorithm,
            publicKeyData: publicKeyData
        )
        try SSHHostTrustKeychainStore.replace(with: replacement, config: config)
    }

    static func saveHostKey(_ entry: TrustedHostKeyEntry) throws {
        try savePinnedHostKey(try pinnedHostKey(from: entry))
    }

    static func pinnedHostKey(from entry: TrustedHostKeyEntry) throws -> PinnedSSHHostKey {
        let publicKeyData = try validatedHostKeyData(
            base64: entry.keyDataBase64,
            claimedFingerprint: entry.fingerprintSHA256
        )
        let hostKey = PinnedSSHHostKey(
            host: entry.host,
            port: entry.port,
            algorithm: entry.algorithm,
            publicKeyData: publicKeyData,
            createdAt: entry.addedAt,
            lastSeenAt: entry.addedAt
        )
        try hostKey.validate()
        return hostKey
    }

    private static func validatedHostKeyData(base64: String, claimedFingerprint: String) throws -> Data {
        guard let publicKeyData = Data(base64Encoded: base64), !publicKeyData.isEmpty else {
            throw SecretStoreError.encodingFailed
        }
        let canonical = PinnedSSHHostKey.sha256Fingerprint(for: publicKeyData)
        let unpadded = String(canonical.dropFirst("SHA256:".count))
        let padded = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        guard claimedFingerprint == canonical
                || claimedFingerprint == unpadded
                || claimedFingerprint == padded else {
            throw SecretStoreError.encodingFailed
        }
        return publicKeyData
    }

    static func savePinnedHostKey(_ hostKey: PinnedSSHHostKey) throws {
        try SSHHostTrustKeychainStore.save(hostKey, config: config)
    }

    static func allPinnedHostKeys() throws -> [PinnedSSHHostKey] {
        try SSHHostTrustKeychainStore.allPinnedHosts(config: config)
    }

    static func trustedHostKeyBase64Set(host: String, port: Int) throws -> Set<String> {
        let records = try SSHHostTrustKeychainStore.authorizedRecords(host: host, port: port, config: config)
        return Set(records.map { $0.publicKeyData.base64EncodedString() })
    }

    // MARK: - Secure Enclave Wrapped P256

    static func saveSecureEnclaveWrappedP256(_ wrapped: Data, keyTag: String, for keyID: UUID) throws {
        try SSHKeyKeychainStore.saveSecureEnclaveWrapped(wrapped, keyTag: keyTag, for: keyID, config: config)
    }

    static func retrieveSecureEnclaveWrappedP256(for keyID: UUID) throws -> (wrapped: Data, keyTag: String) {
        try SSHKeyKeychainStore.retrieveSecureEnclaveWrapped(for: keyID, config: config)
    }

    // MARK: - Tailscale API Key

    static let tailscaleAPIKeyAccount = "\(terminalAccountPrefix).tailscale.api-key"

    static func saveTailscaleAPIKey(_ apiKey: String) throws {
        try KeychainOperations.savePassword(
            apiKey,
            account: tailscaleAPIKeyAccount,
            service: config.passwordsService,
            config: config
        )
    }

    static func retrieveTailscaleAPIKey() throws -> String {
        try KeychainOperations.retrievePassword(
            account: tailscaleAPIKeyAccount,
            service: config.passwordsService,
            config: config
        )
    }

    static func deleteTailscaleAPIKey() throws {
        try KeychainOperations.deletePassword(
            account: tailscaleAPIKeyAccount,
            service: config.passwordsService,
            config: config
        )
    }

    // MARK: - Tailscale OAuth Credentials

    static let tailscaleOAuthClientIDAccount = "\(terminalAccountPrefix).tailscale.oauth.client-id"
    static let tailscaleOAuthClientSecretAccount = "\(terminalAccountPrefix).tailscale.oauth.client-secret"
    static let tailscaleOAuthCredentialsAccount = "\(terminalAccountPrefix).tailscale.oauth.credentials"

    private struct TailscaleOAuthCredentials: Codable, Equatable {
        let clientID: String
        let clientSecret: String
    }

    static func saveTailscaleOAuthCredentials(clientID: String, clientSecret: String) throws {
        let credentials = TailscaleOAuthCredentials(clientID: clientID, clientSecret: clientSecret)
        let data = try JSONEncoder().encode(credentials)
        try KeychainOperations.saveData(
            data,
            account: tailscaleOAuthCredentialsAccount,
            service: config.passwordsService,
            config: config
        )
    }

    static func retrieveTailscaleOAuthCredentials() throws -> (clientID: String, clientSecret: String) {
        try retrieveTailscaleOAuthCredentials(store: .live)
    }

    static func deleteTailscaleOAuthCredentials() throws {
        try deleteTailscaleOAuthCredentials(store: .live)
    }

    static func retrieveTailscaleOAuthCredentials(
        store: TailscaleOAuthCredentialStore
    ) throws -> (clientID: String, clientSecret: String) {
        // Resolve all accounts before mutation. The live store maps only an
        // actual notFound to nil; access/query errors propagate unchanged.
        let bundledData = try store.read(tailscaleOAuthCredentialsAccount)
        let splitIDData = try store.read(tailscaleOAuthClientIDAccount)
        let splitSecretData = try store.read(tailscaleOAuthClientSecretAccount)

        let bundledCredentials: TailscaleOAuthCredentials?
        if let bundledData {
            guard let decoded = try? JSONDecoder().decode(
                TailscaleOAuthCredentials.self,
                from: bundledData
            ) else {
                throw SecretStoreError.encodingFailed
            }
            bundledCredentials = decoded
        } else {
            bundledCredentials = nil
        }

        let splitCredentials: TailscaleOAuthCredentials?
        if let splitIDData, let splitSecretData {
            guard let clientID = String(data: splitIDData, encoding: .utf8),
                  let clientSecret = String(data: splitSecretData, encoding: .utf8) else {
                throw SecretStoreError.encodingFailed
            }
            splitCredentials = .init(clientID: clientID, clientSecret: clientSecret)
        } else {
            splitCredentials = nil
        }

        let credentials: TailscaleOAuthCredentials
        if let bundledCredentials {
            credentials = bundledCredentials
        } else if let splitCredentials {
            credentials = splitCredentials
            let encoded = try JSONEncoder().encode(credentials)
            _ = try store.addIfAbsent(encoded, tailscaleOAuthCredentialsAccount)
            guard let stored = try store.read(tailscaleOAuthCredentialsAccount),
                  let storedCredentials = try? JSONDecoder().decode(
                    TailscaleOAuthCredentials.self,
                    from: stored
                  ),
                  storedCredentials == credentials else {
                throw CredentialMigrationError.keychainReadbackMismatch
            }
        } else {
            throw SecretStoreError.notFound
        }

        // Retain split sources after forward migration. Keychain offers no
        // atomic compare-and-delete operation, so deleting from an earlier
        // snapshot could erase a concurrent rotation by another app instance.
        return (credentials.clientID, credentials.clientSecret)
    }

    static func deleteTailscaleOAuthCredentials(
        store: TailscaleOAuthCredentialStore
    ) throws {
        let accounts = [
            tailscaleOAuthCredentialsAccount,
            tailscaleOAuthClientIDAccount,
            tailscaleOAuthClientSecretAccount,
        ]
        var firstFailure: Error?
        for account in accounts {
            do {
                try store.delete(account)
            } catch SecretStoreError.notFound {
                // Idempotent delete; absence is verified below.
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        for account in accounts {
            do {
                if try store.read(account) != nil {
                    firstFailure = firstFailure ?? CredentialMigrationError.keychainReadbackMismatch
                }
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Credential Namespace Migration

    /// Migrates only credentials whose ownership can be established without
    /// guessing. The report contains counts only; it never persists endpoint or
    /// credential material.
    @discardableResult
    static func runCredentialMigrationIfNeeded(
        servers: [ServerConfiguration],
        metadata: CredentialMigrationMetadata,
        store: CredentialMigrationStore
    ) throws -> CredentialMigrationReport {
        let previousVersion = store.loadVersion()
        if previousVersion >= currentCredentialMigrationVersion,
           let report = try store.loadReport(), report.state == .completed {
            return report
        }

        let previousReport = try store.loadReport()
        let passwordServers = servers
            .filter { $0.authMethod == .password }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var groupedServers: [String: [ServerConfiguration]] = [:]
        for server in passwordServers {
            groupedServers[legacyServerPasswordAccount(for: server), default: []].append(server)
        }
        let sortedTuples = groupedServers.keys.sorted()

        var legacyServerSourceCount = 0
        var exclusiveServerTupleCount = 0
        var ambiguousServerTupleCount = 0
        var unavailableMetadataTupleCount = 0
        var migratedServerDestinationCount = 0
        var alreadyPresentDestinationCount = 0
        var conflictCount = 0
        var tailscaleLegacySourceCount = 0
        var tailscaleMigratedCredentialCount = 0
        var verifiedDestinationCount = 0
        let deletedLegacySourceCount = 0

        var values: [String: Data] = [:]
        let serverAccounts = sortedTuples + passwordServers.map { serverPasswordAccount(for: $0.id) }
        let tailscaleAccounts = [
            legacyTailscaleAPIKeyAccount,
            legacyTailscaleOAuthClientIDAccount,
            legacyTailscaleOAuthClientSecretAccount,
            tailscaleAPIKeyAccount,
            tailscaleOAuthClientIDAccount,
            tailscaleOAuthClientSecretAccount,
            tailscaleOAuthCredentialsAccount
        ]

        func report(state: CredentialMigrationReport.State, failedCount: Int, failureCode: String?) -> CredentialMigrationReport {
            CredentialMigrationReport(
                fromVersion: previousVersion,
                toVersion: currentCredentialMigrationVersion,
                state: state,
                serverProfileCount: passwordServers.count,
                uniqueServerTupleCount: sortedTuples.count,
                duplicateServerProfileCount: passwordServers.count - sortedTuples.count,
                legacyServerSourceCount: legacyServerSourceCount,
                exclusiveServerTupleCount: exclusiveServerTupleCount,
                ambiguousServerTupleCount: ambiguousServerTupleCount,
                unavailableMetadataTupleCount: unavailableMetadataTupleCount,
                migratedServerDestinationCount: migratedServerDestinationCount,
                alreadyPresentDestinationCount: alreadyPresentDestinationCount,
                conflictCount: conflictCount,
                tailscaleLegacySourceCount: tailscaleLegacySourceCount,
                tailscaleMigratedCredentialCount: tailscaleMigratedCredentialCount,
                verifiedDestinationCount: verifiedDestinationCount,
                deletedLegacySourceCount: deletedLegacySourceCount,
                failedCount: failedCount,
                failureCode: failureCode,
                recordedAt: Date()
            )
        }

        func restorePersistence() throws {
            if let previousReport {
                try store.saveReport(previousReport)
            } else {
                try store.removeReport()
            }
            try store.saveVersion(previousVersion)
        }

        func rollback() throws {
            // Never delete a destination written earlier in this transaction.
            // Keychain has no atomic compare-and-delete primitive, so a
            // read-then-delete rollback could erase another process's rotation.
            // Keeping the verified forward copy is lossless and retryable.
            try restorePersistence()
        }

        do {
            // Resolve every possible source and destination before the first
            // mutation. Only an actual notFound is represented as nil by the
            // live store; access and query errors abort the migration.
            for account in Set(serverAccounts + tailscaleAccounts).sorted() {
                if let data = try store.read(account) {
                    values[account] = data
                }
            }

            var plannedWrites: [String: Data] = [:]

            for tuple in sortedTuples {
                guard let legacyValue = values[tuple], let profiles = groupedServers[tuple] else { continue }
                legacyServerSourceCount += 1

                let isExclusive: Bool
                switch metadata {
                case .unavailable:
                    unavailableMetadataTupleCount += 1
                    isExclusive = false
                case .available(let glassDBAccounts):
                    if glassDBAccounts.contains(tuple) {
                        ambiguousServerTupleCount += 1
                        isExclusive = false
                    } else {
                        exclusiveServerTupleCount += 1
                        isExclusive = true
                    }
                }

                guard isExclusive else { continue }
                var tupleHasConflict = false
                for profile in profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    let destination = serverPasswordAccount(for: profile.id)
                    if let existing = values[destination] {
                        if existing == legacyValue {
                            alreadyPresentDestinationCount += 1
                        } else {
                            conflictCount += 1
                            tupleHasConflict = true
                        }
                    } else {
                        plannedWrites[destination] = legacyValue
                    }
                }
                if tupleHasConflict {
                    for profile in profiles {
                        plannedWrites.removeValue(forKey: serverPasswordAccount(for: profile.id))
                    }
                }
            }

            func planSingleCredential(source: String, destination: String) {
                guard let sourceValue = values[source] else { return }
                tailscaleLegacySourceCount += 1
                if let destinationValue = values[destination] {
                    if destinationValue == sourceValue {
                        alreadyPresentDestinationCount += 1
                    } else {
                        conflictCount += 1
                    }
                } else {
                    plannedWrites[destination] = sourceValue
                    tailscaleMigratedCredentialCount += 1
                }
            }

            planSingleCredential(source: legacyTailscaleAPIKeyAccount, destination: tailscaleAPIKeyAccount)

            struct OAuthSplitSource {
                let credentials: TailscaleOAuthCredentials
            }

            let oauthAccountPairs = [
                (legacyTailscaleOAuthClientIDAccount, legacyTailscaleOAuthClientSecretAccount),
                (tailscaleOAuthClientIDAccount, tailscaleOAuthClientSecretAccount)
            ]
            var completeOAuthSources: [OAuthSplitSource] = []
            for (clientIDAccount, clientSecretAccount) in oauthAccountPairs {
                let clientIDData = values[clientIDAccount]
                let clientSecretData = values[clientSecretAccount]
                tailscaleLegacySourceCount += [clientIDData, clientSecretData].compactMap { $0 }.count

                guard let clientIDData, let clientSecretData else {
                    if clientIDData != nil || clientSecretData != nil {
                        conflictCount += 1
                    }
                    continue
                }
                guard let clientID = String(data: clientIDData, encoding: .utf8),
                      let clientSecret = String(data: clientSecretData, encoding: .utf8) else {
                    conflictCount += 1
                    continue
                }
                completeOAuthSources.append(OAuthSplitSource(
                    credentials: TailscaleOAuthCredentials(
                        clientID: clientID,
                        clientSecret: clientSecret
                    )
                ))
            }

            if let candidate = completeOAuthSources.first {
                let sourcesAgree = completeOAuthSources.dropFirst().allSatisfy {
                    $0.credentials == candidate.credentials
                }
                if !sourcesAgree {
                    conflictCount += 1
                } else {
                    if let destinationData = values[tailscaleOAuthCredentialsAccount] {
                        let destination = try? JSONDecoder().decode(
                            TailscaleOAuthCredentials.self,
                            from: destinationData
                        )
                        if destination == candidate.credentials {
                            alreadyPresentDestinationCount += 1
                        } else {
                            conflictCount += 1
                        }
                    } else {
                        plannedWrites[tailscaleOAuthCredentialsAccount] = try JSONEncoder().encode(candidate.credentials)
                        tailscaleMigratedCredentialCount += 1
                    }
                }
            }

            for account in plannedWrites.keys.sorted() {
                guard let data = plannedWrites[account] else { continue }
                let isServerDestination = account.hasPrefix(
                    "\(terminalAccountPrefix).server-password."
                )
                guard try store.addIfAbsent(data, account) else {
                    guard let concurrentValue = try store.read(account) else {
                        throw CredentialMigrationError.keychainReadbackMismatch
                    }
                    if concurrentValue == data {
                        alreadyPresentDestinationCount += 1
                    } else {
                        conflictCount += 1
                    }
                    if !isServerDestination {
                        tailscaleMigratedCredentialCount -= 1
                    }
                    continue
                }
                guard try store.read(account) == data else {
                    throw CredentialMigrationError.keychainReadbackMismatch
                }
                verifiedDestinationCount += 1
                if isServerDestination {
                    migratedServerDestinationCount += 1
                }
            }

            let verifiedReport = report(state: .verified, failedCount: 0, failureCode: nil)
            try store.saveReport(verifiedReport)
            guard try store.loadReport() == verifiedReport else {
                throw CredentialMigrationError.persistenceReadbackMismatch
            }

            // Source cleanup is deliberately forward-only. Retaining the
            // verified legacy records avoids deleting a credential rotated by
            // glassdb or another app instance after this process's preflight.

            let completedReport = report(state: .completed, failedCount: 0, failureCode: nil)
            try store.saveReport(completedReport)
            guard try store.loadReport() == completedReport else {
                throw CredentialMigrationError.persistenceReadbackMismatch
            }
            try store.saveVersion(currentCredentialMigrationVersion)
            guard store.loadVersion() == currentCredentialMigrationVersion else {
                throw CredentialMigrationError.persistenceReadbackMismatch
            }
            return completedReport
        } catch {
            do {
                try rollback()
            } catch {
                let failedReport = report(state: .failed, failedCount: 1, failureCode: CredentialMigrationError.rollbackFailed.code)
                try store.saveReport(failedReport)
                guard try store.loadReport() == failedReport else {
                    throw CredentialMigrationError.persistenceReadbackMismatch
                }
                throw CredentialMigrationError.rollbackFailed
            }
            let failureCode = (error as? CredentialMigrationError)?.code ?? "keychain-query-store-failure"
            let failedReport = report(state: .failed, failedCount: 1, failureCode: failureCode)
            try store.saveReport(failedReport)
            guard try store.loadReport() == failedReport else {
                throw CredentialMigrationError.persistenceReadbackMismatch
            }
            throw error
        }
    }

}
