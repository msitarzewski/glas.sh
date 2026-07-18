//
//  SecretStoreMigrationManager.swift
//  GlasSecretStore
//
//  v0 -> v1 scaffold migration: stamps legacy Keychain items
//  with the migration marker comment and correct accessibility level.
//

import Foundation
import Security

public struct SecretStoreMigrationReport: Codable, Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let discoveredPasswordItemCount: Int
    public let discoveredSSHPrivateKeyItemCount: Int
    public let discoveredSSHPassphraseItemCount: Int
    public let migratedItemCount: Int
    public let failedItemCount: Int
    public let completedAt: Date

    public init(
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
        case fromVersion, toVersion
        case discoveredPasswordItemCount, discoveredSSHPrivateKeyItemCount, discoveredSSHPassphraseItemCount
        case migratedItemCount, failedItemCount, completedAt
    }

    public init(from decoder: Decoder) throws {
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

public final class SecretStoreMigrationManager: @unchecked Sendable {
    private let config: SecretStoreConfiguration
    private nonisolated(unsafe) let defaults: UserDefaults
    private let migrationVersionKey: String
    private let migrationReportKey: String
    private let scaffoldVersion = 1

    public init(config: SecretStoreConfiguration, defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        self.migrationVersionKey = "\(config.serviceNamePrefix).secretStoreMigrationVersion"
        self.migrationReportKey = "\(config.serviceNamePrefix).secretStoreMigrationReport"
    }

    @discardableResult
    public func runScaffoldIfNeeded() -> SecretStoreMigrationReport? {
        let previousVersion = defaults.integer(forKey: migrationVersionKey)
        guard previousVersion < scaffoldVersion else { return nil }
        let migrationResult = runLegacyMigration()

        let report = SecretStoreMigrationReport(
            fromVersion: previousVersion,
            toVersion: scaffoldVersion,
            discoveredPasswordItemCount: KeychainOperations.itemCount(
                service: config.passwordsService, legacyOnly: true, config: config
            ),
            discoveredSSHPrivateKeyItemCount: KeychainOperations.itemCount(
                service: config.sshKeysPrivateService, legacyOnly: true, config: config
            ),
            discoveredSSHPassphraseItemCount: KeychainOperations.itemCount(
                service: config.sshKeysPassphraseService, legacyOnly: true, config: config
            ),
            migratedItemCount: migrationResult.migrated,
            failedItemCount: migrationResult.failed,
            completedAt: Date()
        )

        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: migrationReportKey)
        }
        if report.failedItemCount == 0 {
            defaults.set(scaffoldVersion, forKey: migrationVersionKey)
        }
        return report
    }

    // MARK: - Private

    private func runLegacyMigration() -> (migrated: Int, failed: Int) {
        var migrated = 0
        var failed = 0
        let services = [
            config.passwordsService,
            config.sshPasswordsService,
            config.sshKeysPrivateService,
            config.sshKeysPassphraseService
        ]
        for service in services {
            let result = migrateServiceToMarkedItems(service: service)
            migrated += result.migrated
            failed += result.failed
        }
        return (migrated, failed)
    }

    private func migrateServiceToMarkedItems(service: String) -> (migrated: Int, failed: Int) {
        let items: [[String: Any]]
        do {
            items = try KeychainOperations.allItems(service: service, config: config)
        } catch {
            return (0, 1)
        }
        var migrated = 0
        var failed = 0
        for item in items {
            let comment = item[kSecAttrComment as String] as? String
            if comment == config.migrationMarkerComment { continue }
            guard
                let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data
            else {
                failed += 1
                continue
            }
            do {
                try KeychainOperations.updateItem(
                    account: account, service: service, data: data, config: config
                )
                migrated += 1
            } catch {
                failed += 1
            }
        }
        return (migrated, failed)
    }
}
