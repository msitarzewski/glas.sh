import Testing
import Foundation
import Security
@testable import GlasSecretStore

@Suite("SSHKeyKeychainStore")
struct SSHKeyKeychainStoreTests {

    private let config: SecretStoreConfiguration
    private let keyID: UUID

    init() {
        let prefix = "test.SSHKeyStore.\(UUID().uuidString.prefix(8))"
        config = SecretStoreConfiguration(
            serviceNamePrefix: prefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: []
        )
        keyID = UUID()
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

    // MARK: - Save + Retrieve

    @Test("Save and retrieve round-trip with passphrase")
    func roundTripWithPassphrase() throws {
        defer { cleanupKeychain() }
        let pk = SecureBytes(Data("private-key-data".utf8))
        let pp = SecureBytes(Data("my-passphrase".utf8))
        try SSHKeyKeychainStore.save(privateKey: pk, passphrase: pp, for: keyID, config: config)

        let material = try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
        #expect(material.privateKey.toUTF8String() == "private-key-data")
        #expect(material.passphrase?.toUTF8String() == "my-passphrase")
    }

    @Test("Save and retrieve with nil passphrase")
    func roundTripNilPassphrase() throws {
        defer { cleanupKeychain() }
        let pk = SecureBytes(Data("key-only".utf8))
        try SSHKeyKeychainStore.save(privateKey: pk, passphrase: nil, for: keyID, config: config)

        let material = try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
        #expect(material.privateKey.toUTF8String() == "key-only")
        #expect(material.passphrase == nil)
    }

    @Test("Retrieve legacy raw private key and separate passphrase")
    func retrieveLegacyRawKeyAndPassphrase() throws {
        defer { cleanupKeychain() }
        let privateKey = Data("legacy-openssh-rsa-private-key".utf8)
        let passphrase = Data("legacy-passphrase".utf8)
        try KeychainOperations.saveData(
            privateKey,
            account: keyID.uuidString,
            service: config.sshKeysPrivateService,
            config: config
        )
        try KeychainOperations.saveData(
            passphrase,
            account: keyID.uuidString,
            service: config.sshKeysPassphraseService,
            config: config
        )

        let material = try SSHKeyKeychainStore.retrieve(for: keyID, config: config)

        #expect(material.privateKey.toData() == privateKey)
        #expect(material.passphrase?.toData() == passphrase)
    }

    @Test("Re-save with nil passphrase clears stale passphrase")
    func clearStalePassphrase() throws {
        defer { cleanupKeychain() }
        let pk = SecureBytes(Data("key".utf8))
        let pp = SecureBytes(Data("pass".utf8))
        try SSHKeyKeychainStore.save(privateKey: pk, passphrase: pp, for: keyID, config: config)

        // Re-save without passphrase
        let pk2 = SecureBytes(Data("key-v2".utf8))
        try SSHKeyKeychainStore.save(privateKey: pk2, passphrase: nil, for: keyID, config: config)

        let material = try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
        #expect(material.privateKey.toUTF8String() == "key-v2")
        #expect(material.passphrase == nil)
    }

    @Test("Add-if-absent preserves an existing imported key")
    func addIfAbsentPreservesExistingKey() throws {
        defer { cleanupKeychain() }
        let first = try SSHKeyKeychainStore.addIfAbsent(
            privateKey: SecureBytes(Data("first-key".utf8)),
            passphrase: nil,
            for: keyID,
            config: config
        )
        let duplicate = try SSHKeyKeychainStore.addIfAbsent(
            privateKey: SecureBytes(Data("replacement-key".utf8)),
            passphrase: SecureBytes(Data("replacement-passphrase".utf8)),
            for: keyID,
            config: config
        )
        let material = try SSHKeyKeychainStore.retrieve(for: keyID, config: config)

        #expect(first)
        #expect(!duplicate)
        #expect(material.privateKey.toUTF8String() == "first-key")
        #expect(material.passphrase == nil)
    }

    @Test("Delete restores every artifact when any step fails before hardware removal")
    func deleteRestoresArtifactsAfterEachFailureStep() throws {
        let services = [
            config.sealedP256Service,
            config.sealedP256TagService,
            config.sshKeysPrivateService,
            config.sshKeysPassphraseService,
        ]
        let keyTag = "test.secure-enclave.\(keyID.uuidString)"
        let originals = Dictionary(uniqueKeysWithValues: services.enumerated().map { index, service in
            let value = service == config.sealedP256TagService
                ? Data(keyTag.utf8)
                : Data("artifact-\(index)".utf8)
            return (service, value)
        })

        for failingService in services {
            var values = originals
            var hardwareKeyExists = true
            var hardwareDeleteCount = 0
            let operations = SSHKeyDeletionOperations(
                read: { _, service, _ in values[service] },
                delete: { _, service, _ in
                    values.removeValue(forKey: service)
                    if service == failingService {
                        throw SecretStoreError.unableToDelete
                    }
                },
                addIfAbsent: { data, _, service, _ in
                    guard values[service] == nil else { return false }
                    values[service] = data
                    return true
                },
                secureEnclaveKeyExists: { _ in hardwareKeyExists },
                deleteSecureEnclaveKey: { _ in
                    hardwareDeleteCount += 1
                    hardwareKeyExists = false
                }
            )

            #expect(throws: SecretStoreError.self) {
                try SSHKeyKeychainStore.delete(
                    for: keyID,
                    config: config,
                    operations: operations
                )
            }
            #expect(values == originals)
            #expect(hardwareKeyExists)
            #expect(hardwareDeleteCount == 0)
        }
    }

    @Test("Delete restores artifacts when hardware deletion fails without mutation")
    func deleteRestoresArtifactsAfterHardwareFailure() throws {
        let keyTag = "test.secure-enclave.\(keyID.uuidString)"
        let originals: [String: Data] = [
            config.sealedP256Service: Data("wrapped".utf8),
            config.sealedP256TagService: Data(keyTag.utf8),
        ]
        var values = originals
        let operations = SSHKeyDeletionOperations(
            read: { _, service, _ in values[service] },
            delete: { _, service, _ in _ = values.removeValue(forKey: service) },
            addIfAbsent: { data, _, service, _ in
                guard values[service] == nil else { return false }
                values[service] = data
                return true
            },
            secureEnclaveKeyExists: { _ in true },
            deleteSecureEnclaveKey: { _ in throw SecretStoreError.unableToDelete }
        )

        #expect(throws: SecretStoreError.self) {
            try SSHKeyKeychainStore.delete(
                for: keyID,
                config: config,
                operations: operations
            )
        }
        #expect(values == originals)
    }

    @Test("Delete restores encrypted artifacts when hardware status is indeterminate")
    func deleteRestoresArtifactsWhenHardwareStatusIsIndeterminate() throws {
        let keyTag = "test.secure-enclave.\(keyID.uuidString)"
        let originals: [String: Data] = [
            config.sealedP256Service: Data("wrapped".utf8),
            config.sealedP256TagService: Data(keyTag.utf8),
        ]
        var values = originals
        let operations = SSHKeyDeletionOperations(
            read: { _, service, _ in values[service] },
            delete: { _, service, _ in _ = values.removeValue(forKey: service) },
            addIfAbsent: { data, _, service, _ in
                guard values[service] == nil else { return false }
                values[service] = data
                return true
            },
            secureEnclaveKeyExists: { _ in
                throw SecretStoreError.queryFailed(status: errSecInteractionNotAllowed)
            },
            deleteSecureEnclaveKey: { _ in throw SecretStoreError.unableToDelete }
        )

        #expect(throws: SecretStoreError.self) {
            try SSHKeyKeychainStore.delete(
                for: keyID,
                config: config,
                operations: operations
            )
        }
        #expect(values == originals)
    }

    @Test("Legacy Secure Enclave provenance rejects a preferred imported record")
    func legacySecureEnclaveProvenanceRejectsImportedRecord() throws {
        defer { cleanupKeychain() }
        let marker = "SECURE_ENCLAVE_P256:dmVyaWZpZWQ="
        let material = SSHKeyMaterial(
            privateKey: SecureBytes(Data(marker.utf8)),
            passphrase: nil
        )
        #expect(try SSHKeyKeychainStore.addIfAbsent(
            privateKey: material.privateKey,
            passphrase: nil,
            for: keyID,
            config: config
        ))

        #expect(try !SSHKeyKeychainStore.verifiesLegacySecureEnclaveBacking(
            material,
            for: keyID,
            config: config
        ))
    }

    @Test("Artifact presence detects an orphaned passphrase without private material")
    func artifactPresenceDetectsPassphraseOnly() throws {
        defer { cleanupKeychain() }
        try KeychainOperations.saveData(
            Data("orphaned-passphrase".utf8),
            account: keyID.uuidString,
            service: config.sshKeysPassphraseService,
            config: config
        )

        #expect(try SSHKeyKeychainStore.hasAnyArtifacts(for: keyID, config: config))
        try SSHKeyKeychainStore.delete(for: keyID, config: config)
        #expect(try !SSHKeyKeychainStore.hasAnyArtifacts(for: keyID, config: config))
    }

    @Test("Delete removes all artifacts")
    func deleteRemovesAll() throws {
        defer { cleanupKeychain() }
        let pk = SecureBytes(Data("key".utf8))
        let pp = SecureBytes(Data("pass".utf8))
        try SSHKeyKeychainStore.save(privateKey: pk, passphrase: pp, for: keyID, config: config)

        try SSHKeyKeychainStore.delete(for: keyID, config: config)

        #expect(throws: SecretStoreError.self) {
            try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
        }
    }

    @Test("Retrieve non-existent key throws notFound")
    func retrieveNonExistent() {
        #expect(throws: SecretStoreError.self) {
            try SSHKeyKeychainStore.retrieve(for: UUID(), config: config)
        }
    }
}
