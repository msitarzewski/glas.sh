import Testing
import Foundation
@testable import GlasSecretStore

// MARK: - SecretStoreError

@Suite("SecretStoreError")
struct SecretStoreErrorTests {

    @Test("Every case has a non-empty errorDescription")
    func allCasesHaveDescription() {
        let cases: [SecretStoreError] = [
            .unableToSave,
            .notFound,
            .unableToDelete,
            .unsupportedSSHKeyType,
            .secureEnclaveUnavailable,
            .secureEnclaveOperationFailed,
            .encodingFailed,
            .updateFailed(account: "test-account", status: -25300),
            .payloadTooLarge(2_000_000),
        ]
        for error in cases {
            let desc = error.errorDescription
            #expect(desc != nil, "Missing errorDescription for \(error)")
            #expect(desc?.isEmpty == false, "Empty errorDescription for \(error)")
        }
    }

    @Test("updateFailed includes account string")
    func updateFailedIncludesAccount() {
        let error = SecretStoreError.updateFailed(account: "my-acct", status: -25300)
        #expect(error.errorDescription?.contains("my-acct") == true)
    }

    @Test("payloadTooLarge includes size")
    func payloadTooLargeIncludesSize() {
        let error = SecretStoreError.payloadTooLarge(2_000_000)
        #expect(error.errorDescription?.contains("2000000") == true)
    }
}

// MARK: - SSHKeyMaterial

@Suite("SSHKeyMaterial")
struct SSHKeyMaterialTests {

    @Test("Init with privateKey and passphrase")
    func initWithPassphrase() {
        let pk = SecureBytes(Data("private".utf8))
        let pp = SecureBytes(Data("pass".utf8))
        let material = SSHKeyMaterial(privateKey: pk, passphrase: pp)
        #expect(material.privateKey.toUTF8String() == "private")
        #expect(material.passphrase?.toUTF8String() == "pass")
    }

    @Test("Init with nil passphrase")
    func initNilPassphrase() {
        let pk = SecureBytes(Data("key".utf8))
        let material = SSHKeyMaterial(privateKey: pk, passphrase: nil)
        #expect(material.passphrase == nil)
    }
}

// MARK: - SSHKeyAlgorithmKind

@Suite("SSHKeyAlgorithmKind")
struct SSHKeyAlgorithmKindTests {

    @Test("badgeName for all cases")
    func badgeNames() {
        #expect(SSHKeyAlgorithmKind.rsa.badgeName == "RSA")
        #expect(SSHKeyAlgorithmKind.ed25519.badgeName == "ED25519")
        #expect(SSHKeyAlgorithmKind.ecdsaP256.badgeName == "P-256")
        #expect(SSHKeyAlgorithmKind.ecdsaP384.badgeName == "P-384")
        #expect(SSHKeyAlgorithmKind.ecdsaP521.badgeName == "P-521")
        #expect(SSHKeyAlgorithmKind.unknown.badgeName == "Unknown")
    }

    @Test("fromLegacyDescription exact matches")
    func fromLegacyExact() {
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("rsa") == .rsa)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("ed25519") == .ed25519)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("ecdsa p-256") == .ecdsaP256)
    }

    @Test("fromLegacyDescription fuzzy variants")
    func fromLegacyFuzzy() {
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("ECDSA-P256") == .ecdsaP256)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("ecdsa_p384") == .ecdsaP384)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("ECDSA-P521") == .ecdsaP521)
    }

    @Test("fromLegacyDescription unknown fallback")
    func fromLegacyUnknown() {
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("dsa") == .unknown)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("") == .unknown)
        #expect(SSHKeyAlgorithmKind.fromLegacyDescription("blah") == .unknown)
    }
}

// MARK: - SSHKeyStorageKind

@Suite("SSHKeyStorageKind")
struct SSHKeyStorageKindTests {

    @Test("badgePrefix for all cases")
    func badgePrefixes() {
        #expect(SSHKeyStorageKind.legacy.badgePrefix == "Legacy")
        #expect(SSHKeyStorageKind.imported.badgePrefix == "Imported")
        #expect(SSHKeyStorageKind.secureEnclave.badgePrefix == "Secure Enclave")
    }
}

// MARK: - SSHKeyMigrationState

@Suite("SSHKeyMigrationState")
struct SSHKeyMigrationStateTests {

    @Test("CaseIterable count is 4")
    func allCasesCount() {
        #expect(SSHKeyMigrationState.allCases.count == 4)
    }
}

// MARK: - StoredSSHKey

@Suite("StoredSSHKey")
struct StoredSSHKeyTests {

    @Test("Init with defaults")
    func initDefaults() {
        let key = StoredSSHKey(name: "my-key", algorithm: "ed25519")
        #expect(key.name == "my-key")
        #expect(key.algorithm == "ed25519")
        #expect(key.storageKind == .imported)
        #expect(key.algorithmKind == .unknown)
        #expect(key.migrationState == .notNeeded)
        #expect(key.keyTag == nil)
    }

    @Test("keyTypeBadge concatenation")
    func keyTypeBadge() {
        let key = StoredSSHKey(
            name: "test",
            algorithm: "ed25519",
            storageKind: .secureEnclave,
            algorithmKind: .ed25519
        )
        #expect(key.keyTypeBadge == "Secure Enclave ED25519")
    }

    @Test("Backward-compatible Codable decode with missing new fields")
    func backwardCompatibleDecode() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let v1JSON: [String: Any] = [
            "id": id.uuidString,
            "name": "old-key",
            "algorithm": "ed25519",
            "createdAt": date.timeIntervalSinceReferenceDate,
        ]
        let data = try JSONSerialization.data(withJSONObject: v1JSON)
        let decoder = JSONDecoder()
        let key = try decoder.decode(StoredSSHKey.self, from: data)
        #expect(key.id == id)
        #expect(key.name == "old-key")
        #expect(key.algorithm == "ed25519")
        #expect(key.storageKind == .legacy)
        #expect(key.algorithmKind == .ed25519)
        #expect(key.migrationState == .notNeeded)
        #expect(key.keyTag == nil)
    }
}
