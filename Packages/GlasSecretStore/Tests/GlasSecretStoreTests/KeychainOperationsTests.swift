import Testing
import Foundation
import Security
@testable import GlasSecretStore

@Suite("KeychainOperations")
struct KeychainOperationsTests {

    private let config: SecretStoreConfiguration
    private let service: String

    init() {
        let prefix = "test.KeychainOps.\(UUID().uuidString.prefix(8))"
        config = SecretStoreConfiguration(
            serviceNamePrefix: prefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: []
        )
        service = config.passwordsService
    }

    // Cleanup helper — deletes all items for every derived service name.
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

    // MARK: - Password

    @Test("Save and retrieve password round-trip")
    func passwordRoundTrip() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.savePassword("secret123", account: "user1", service: service, config: config)
        let retrieved = try KeychainOperations.retrievePassword(account: "user1", service: service, config: config)
        #expect(retrieved == "secret123")
    }

    @Test("Overwrite password (upsert)")
    func passwordUpsert() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.savePassword("old", account: "user1", service: service, config: config)
        try KeychainOperations.savePassword("new", account: "user1", service: service, config: config)
        let retrieved = try KeychainOperations.retrievePassword(account: "user1", service: service, config: config)
        #expect(retrieved == "new")
    }

    @Test("Delete password then retrieve throws notFound")
    func deletePassword() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.savePassword("val", account: "user1", service: service, config: config)
        try KeychainOperations.deletePassword(account: "user1", service: service, config: config)
        #expect(throws: SecretStoreError.self) {
            try KeychainOperations.retrievePassword(account: "user1", service: service, config: config)
        }
    }

    @Test("Empty string throws encodingFailed")
    func emptyStringEncodingFailed() {
        defer { cleanupKeychain() }
        #expect(throws: SecretStoreError.self) {
            try KeychainOperations.savePassword("", account: "user1", service: service, config: config)
        }
    }

    // MARK: - Data

    @Test("Save and retrieve data round-trip")
    func dataRoundTrip() throws {
        defer { cleanupKeychain() }
        let data = Data([0x01, 0x02, 0x03])
        try KeychainOperations.saveData(data, account: "d1", service: service, config: config)
        let retrieved = try KeychainOperations.retrieveData(account: "d1", service: service, config: config)
        #expect(retrieved == data)
    }

    @Test("Overwrite data (upsert)")
    func dataUpsert() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.saveData(Data([0x01]), account: "d1", service: service, config: config)
        try KeychainOperations.saveData(Data([0x02]), account: "d1", service: service, config: config)
        let retrieved = try KeychainOperations.retrieveData(account: "d1", service: service, config: config)
        #expect(retrieved == Data([0x02]))
    }

    @Test("Add-if-absent preserves the first value")
    func dataAddIfAbsent() throws {
        defer { cleanupKeychain() }
        let inserted = try KeychainOperations.addDataIfAbsent(
            Data([0x01]),
            account: "d1",
            service: service,
            config: config
        )
        let duplicate = try KeychainOperations.addDataIfAbsent(
            Data([0x02]),
            account: "d1",
            service: service,
            config: config
        )
        let retrieved = try KeychainOperations.retrieveData(
            account: "d1",
            service: service,
            config: config
        )

        #expect(inserted)
        #expect(!duplicate)
        #expect(retrieved == Data([0x01]))
    }

    @Test("Payload over 1 MB throws payloadTooLarge")
    func payloadTooLarge() {
        defer { cleanupKeychain() }
        let oversized = Data(repeating: 0xAA, count: 1_048_576 + 1)
        #expect(throws: SecretStoreError.self) {
            try KeychainOperations.saveData(oversized, account: "big", service: service, config: config)
        }
    }

    @Test("Delete data then retrieve throws notFound")
    func deleteData() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.saveData(Data([0x01]), account: "d1", service: service, config: config)
        try KeychainOperations.deleteItem(account: "d1", service: service, config: config)
        #expect(throws: SecretStoreError.self) {
            try KeychainOperations.retrieveData(account: "d1", service: service, config: config)
        }
    }

    // MARK: - Fallback

    @Test("Fallback retrieval: primary miss, legacy hit")
    func fallbackLegacyHit() throws {
        let legacyPrefix = "test.legacy.\(UUID().uuidString.prefix(8))"
        let fallbackConfig = SecretStoreConfiguration(
            serviceNamePrefix: config.serviceNamePrefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: [legacyPrefix]
        )
        let legacyService = "\(legacyPrefix).passwords"

        defer {
            cleanupKeychain()
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
            ]
            SecItemDelete(q as CFDictionary)
        }

        // Save under legacy service only
        try KeychainOperations.savePassword(
            "legacy-value", account: "user1", service: legacyService, config: fallbackConfig
        )

        let result = try KeychainOperations.retrievePasswordWithFallback(
            account: "user1",
            primaryService: fallbackConfig.passwordsService,
            legacySuffix: "passwords",
            config: fallbackConfig
        )
        #expect(result == "legacy-value")
    }

    @Test("Fallback retrieval: both miss throws notFound")
    func fallbackBothMiss() {
        let fallbackConfig = SecretStoreConfiguration(
            serviceNamePrefix: config.serviceNamePrefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: ["nonexistent.prefix"]
        )

        #expect(throws: SecretStoreError.self) {
            try KeychainOperations.retrievePasswordWithFallback(
                account: "nobody",
                primaryService: fallbackConfig.passwordsService,
                legacySuffix: "passwords",
                config: fallbackConfig
            )
        }
    }

    // MARK: - itemCount

    @Test("itemCount is zero on empty keychain")
    func itemCountEmpty() {
        #expect(KeychainOperations.itemCount(service: service, legacyOnly: false, config: config) == 0)
    }

    @Test("itemCount correct after saves")
    func itemCountAfterSaves() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.savePassword("a", account: "u1", service: service, config: config)
        try KeychainOperations.savePassword("b", account: "u2", service: service, config: config)
        #expect(KeychainOperations.itemCount(service: service, legacyOnly: false, config: config) == 2)
    }

    @Test("itemCount legacyOnly excludes stamped items")
    func itemCountLegacyOnly() throws {
        defer { cleanupKeychain() }
        // saveData stamps with migrationMarkerComment, so these are NOT legacy
        try KeychainOperations.saveData(Data("a".utf8), account: "u1", service: service, config: config)
        try KeychainOperations.saveData(Data("b".utf8), account: "u2", service: service, config: config)
        #expect(KeychainOperations.itemCount(service: service, legacyOnly: false, config: config) == 2)
        #expect(KeychainOperations.itemCount(service: service, legacyOnly: true, config: config) == 0)
    }
}
