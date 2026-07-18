import Testing
import Foundation
import Security
@testable import GlasSecretStore

@Suite("SecretStoreMigrationManager")
struct MigrationManagerTests {

    private let config: SecretStoreConfiguration
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let prefix = "test.Migration.\(UUID().uuidString.prefix(8))"
        config = SecretStoreConfiguration(
            serviceNamePrefix: prefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: []
        )
        suiteName = "test.MigrationDefaults.\(UUID().uuidString.prefix(8))"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func cleanupKeychain() {
        let services = [
            config.passwordsService,
            config.sshPasswordsService,
            config.sshKeysPrivateService,
            config.sshKeysPassphraseService,
            config.sealedP256Service,
            config.sealedP256TagService,
        ]
        for svc in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private func cleanupDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Tests

    @Test("First run returns report with fromVersion 0, toVersion 1")
    func firstRunReport() {
        defer { cleanupDefaults() }
        let manager = SecretStoreMigrationManager(config: config, defaults: defaults)
        let report = manager.runScaffoldIfNeeded()
        #expect(report != nil)
        #expect(report?.fromVersion == 0)
        #expect(report?.toVersion == 1)
    }

    @Test("Second run returns nil (already at version 1)")
    func secondRunNil() {
        defer { cleanupDefaults() }
        let manager = SecretStoreMigrationManager(config: config, defaults: defaults)
        _ = manager.runScaffoldIfNeeded()
        let second = manager.runScaffoldIfNeeded()
        #expect(second == nil)
    }

    @Test("Report Codable round-trip")
    func reportCodable() throws {
        let report = SecretStoreMigrationReport(
            fromVersion: 0,
            toVersion: 1,
            discoveredPasswordItemCount: 3,
            discoveredSSHPrivateKeyItemCount: 2,
            discoveredSSHPassphraseItemCount: 1,
            migratedItemCount: 6,
            failedItemCount: 0,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SecretStoreMigrationReport.self, from: data)
        #expect(decoded.fromVersion == 0)
        #expect(decoded.toVersion == 1)
        #expect(decoded.discoveredPasswordItemCount == 3)
        #expect(decoded.discoveredSSHPrivateKeyItemCount == 2)
        #expect(decoded.discoveredSSHPassphraseItemCount == 1)
        #expect(decoded.migratedItemCount == 6)
        #expect(decoded.failedItemCount == 0)
    }

    @Test("Migration stamps Keychain items when zero failures")
    func migrationStampsItems() throws {
        defer {
            cleanupKeychain()
            cleanupDefaults()
        }

        // Insert item via the library but with a different migration marker.
        // This simulates a "legacy" item that the migration should re-stamp.
        let legacyConfig = SecretStoreConfiguration(
            serviceNamePrefix: config.serviceNamePrefix,
            accessGroup: nil,
            migrationMarkerComment: "old.legacy.marker.v0"
        )
        try KeychainOperations.saveData(
            Data("legacy-pw".utf8),
            account: "legacy-user",
            service: config.passwordsService,
            config: legacyConfig
        )

        // Verify it's counted as legacy (marker doesn't match real config)
        #expect(KeychainOperations.itemCount(service: config.passwordsService, legacyOnly: true, config: config) == 1)

        // Run migration
        let manager = SecretStoreMigrationManager(config: config, defaults: defaults)
        let report = manager.runScaffoldIfNeeded()
        #expect(report != nil)
        #expect(report?.failedItemCount == 0)
        #expect(report?.migratedItemCount == 1)

        // After migration, the item should be stamped (no longer legacy)
        #expect(KeychainOperations.itemCount(service: config.passwordsService, legacyOnly: true, config: config) == 0)
        #expect(KeychainOperations.itemCount(service: config.passwordsService, legacyOnly: false, config: config) == 1)

        // Version should be bumped
        let version = defaults.integer(forKey: "\(config.serviceNamePrefix).secretStoreMigrationVersion")
        #expect(version == 1)
    }
}
