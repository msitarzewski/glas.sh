//
//  SSHKeyKeychainStore.swift
//  GlasSecretStore
//
//  Save/retrieve/delete SSH keys by UUID.
//  Supports plain keys (imported/legacy) and Secure Enclave P256.
//

import Foundation

// Production closures are stateless Security-framework adapters. Test probes
// remain synchronously confined to a single delete invocation.
struct SSHKeyDeletionOperations: @unchecked Sendable {
    let read: (String, String, SecretStoreConfiguration) throws -> Data?
    let delete: (String, String, SecretStoreConfiguration) throws -> Void
    let addIfAbsent: (Data, String, String, SecretStoreConfiguration) throws -> Bool
    let secureEnclaveKeyExists: (String) throws -> Bool
    let deleteSecureEnclaveKey: (String) throws -> Void

    static let live = SSHKeyDeletionOperations(
        read: { account, service, config in
            do {
                return try KeychainOperations.retrieveData(
                    account: account,
                    service: service,
                    config: config
                )
            } catch SecretStoreError.notFound {
                return nil
            }
        },
        delete: { account, service, config in
            try KeychainOperations.deleteItem(
                account: account,
                service: service,
                config: config
            )
        },
        addIfAbsent: { data, account, service, config in
            try KeychainOperations.addDataIfAbsent(
                data,
                account: account,
                service: service,
                config: config
            )
        },
        secureEnclaveKeyExists: { try SecureEnclaveKeyManager.keyExists(keyTag: $0) },
        deleteSecureEnclaveKey: { try SecureEnclaveKeyManager.deleteKeyIfPresent(keyTag: $0) }
    )
}

public enum SSHKeyKeychainStore: Sendable {

    // MARK: - Save

    public static func save(
        privateKey: SecureBytes,
        passphrase: SecureBytes?,
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws {
        let bundle = StoredSSHKeyBundle(
            privateKey: privateKey.toData(),
            passphrase: passphrase.flatMap { $0.count > 0 ? $0.toData() : nil }
        )
        try KeychainOperations.saveData(
            try JSONEncoder().encode(bundle),
            account: keyID.uuidString,
            service: config.sshKeysPrivateService,
            config: config
        )
    }

    /// Atomically creates the bundled imported-key record without replacing a
    /// concurrently created record for the same UUID.
    public static func addIfAbsent(
        privateKey: SecureBytes,
        passphrase: SecureBytes?,
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws -> Bool {
        let bundle = StoredSSHKeyBundle(
            privateKey: privateKey.toData(),
            passphrase: passphrase.flatMap { $0.count > 0 ? $0.toData() : nil }
        )
        return try KeychainOperations.addDataIfAbsent(
            try JSONEncoder().encode(bundle),
            account: keyID.uuidString,
            service: config.sshKeysPrivateService,
            config: config
        )
    }

    // MARK: - Retrieve

    public static func retrieve(
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws -> SSHKeyMaterial {
        // Try plain key first (retrieve as Data to avoid intermediate String)
        do {
            let privateKeyData = try KeychainOperations.retrieveData(
                account: keyID.uuidString,
                service: config.sshKeysPrivateService,
                config: config
            )
            if let bundle = try? JSONDecoder().decode(StoredSSHKeyBundle.self, from: privateKeyData) {
                return SSHKeyMaterial(
                    privateKey: SecureBytes(bundle.privateKey),
                    passphrase: bundle.passphrase.map(SecureBytes.init)
                )
            }
            let passphraseData: Data?
            do {
                passphraseData = try KeychainOperations.retrieveData(
                    account: keyID.uuidString,
                    service: config.sshKeysPassphraseService,
                    config: config
                )
            } catch SecretStoreError.notFound {
                passphraseData = nil
            }
            return SSHKeyMaterial(
                privateKey: SecureBytes(privateKeyData),
                passphrase: passphraseData.map { SecureBytes($0) }
            )
        } catch SecretStoreError.notFound {
            // Try the Secure Enclave representation below.
        }

        // Try Secure Enclave wrapped P256
        do {
            let (wrapped, keyTag) = try retrieveSecureEnclaveWrapped(for: keyID, config: config)
            let raw = try SecureEnclaveKeyManager.unwrap(wrapped: wrapped, keyTag: keyTag)
            let marker = "SECURE_ENCLAVE_P256:\(raw.base64EncodedString())"
            return SSHKeyMaterial(
                privateKey: SecureBytes(Data(marker.utf8)),
                passphrase: nil
            )
        } catch SecretStoreError.notFound {
            throw SecretStoreError.notFound
        }
    }

    // MARK: - Delete

    public static func delete(
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws {
        try delete(for: keyID, config: config, operations: .live)
    }

    static func delete(
        for keyID: UUID,
        config: SecretStoreConfiguration,
        operations: SSHKeyDeletionOperations
    ) throws {
        let account = keyID.uuidString
        let services = [
            config.sealedP256Service,
            config.sealedP256TagService,
            config.sshKeysPrivateService,
            config.sshKeysPassphraseService,
        ]
        var snapshots: [String: Data] = [:]
        for service in services {
            if let data = try operations.read(account, service, config) {
                snapshots[service] = data
            }
        }

        let secureEnclaveKeyTag: String?
        if let tagData = snapshots[config.sealedP256TagService] {
            guard let tag = String(data: tagData, encoding: .utf8), !tag.isEmpty else {
                throw SecretStoreError.encodingFailed
            }
            secureEnclaveKeyTag = tag
        } else {
            let deterministicTag = SecureEnclaveKeyManager.keyTag(for: keyID)
            secureEnclaveKeyTag = try operations.secureEnclaveKeyExists(deterministicTag)
                ? deterministicTag
                : nil
        }

        do {
            // Remove every recoverable artifact before the irreversible
            // hardware key. A failure restores the exact snapshot below.
            for service in services {
                try operations.delete(account, service, config)
            }
            if let secureEnclaveKeyTag {
                try operations.deleteSecureEnclaveKey(secureEnclaveKeyTag)
            }
        } catch let deletionError {
            // If deletion of the hardware key reported failure after actually
            // removing it, its wrapped bytes cannot be made usable again.
            if let secureEnclaveKeyTag {
                let hardwareKeyExists: Bool
                do {
                    hardwareKeyExists = try operations.secureEnclaveKeyExists(secureEnclaveKeyTag)
                } catch {
                    // An indeterminate query must preserve encrypted artifacts;
                    // it is not proof that the hardware key is absent.
                    try restoreDeletionSnapshots(
                        snapshots,
                        expectedServices: services,
                        account: account,
                        config: config,
                        operations: operations
                    )
                    throw deletionError
                }
                guard hardwareKeyExists else { throw deletionError }
            }
            try restoreDeletionSnapshots(
                snapshots,
                expectedServices: services,
                account: account,
                config: config,
                operations: operations
            )
            throw deletionError
        }
    }

    private static func restoreDeletionSnapshots(
        _ snapshots: [String: Data],
        expectedServices: [String],
        account: String,
        config: SecretStoreConfiguration,
        operations: SSHKeyDeletionOperations
    ) throws {
        for service in snapshots.keys.sorted() {
            guard let original = snapshots[service] else { continue }
            if let current = try operations.read(account, service, config) {
                guard current == original else { throw SecretStoreError.unableToSave }
                continue
            }
            _ = try operations.addIfAbsent(original, account, service, config)
            guard try operations.read(account, service, config) == original else {
                throw SecretStoreError.unableToSave
            }
        }
        for service in expectedServices where snapshots[service] == nil {
            guard try operations.read(account, service, config) == nil else {
                throw SecretStoreError.unableToSave
            }
        }
    }

    private struct StoredSSHKeyBundle: Codable {
        let privateKey: Data
        let passphrase: Data?
    }

    // MARK: - Secure Enclave Wrapped P256

    public static func saveSecureEnclaveWrapped(
        _ wrapped: Data,
        keyTag: String,
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws {
        try KeychainOperations.saveData(
            wrapped,
            account: keyID.uuidString,
            service: config.sealedP256Service,
            config: config
        )
        try KeychainOperations.savePassword(
            keyTag,
            account: keyID.uuidString,
            service: config.sealedP256TagService,
            config: config
        )
    }

    public static func retrieveSecureEnclaveWrapped(
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws -> (wrapped: Data, keyTag: String) {
        let wrapped = try KeychainOperations.retrieveData(
            account: keyID.uuidString,
            service: config.sealedP256Service,
            config: config
        )
        let keyTag = try KeychainOperations.retrievePassword(
            account: keyID.uuidString,
            service: config.sealedP256TagService,
            config: config
        )
        return (wrapped, keyTag)
    }

    public static func verifiesLegacySecureEnclaveBacking(
        _ material: SSHKeyMaterial,
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws -> Bool {
        guard material.passphrase == nil,
              let expected = material.privateKey.toUTF8String(),
              expected.hasPrefix("SECURE_ENCLAVE_P256:") else {
            return false
        }
        for service in [config.sshKeysPrivateService, config.sshKeysPassphraseService] {
            do {
                _ = try KeychainOperations.retrieveData(
                    account: keyID.uuidString,
                    service: service,
                    config: config
                )
                return false
            } catch SecretStoreError.notFound {
                // A hardware-backed legacy representation has no imported record.
            }
        }
        do {
            let (wrapped, keyTag) = try retrieveSecureEnclaveWrapped(for: keyID, config: config)
            guard try SecureEnclaveKeyManager.keyExists(keyTag: keyTag) else { return false }
            let raw = try SecureEnclaveKeyManager.unwrap(wrapped: wrapped, keyTag: keyTag)
            return expected == "SECURE_ENCLAVE_P256:\(raw.base64EncodedString())"
        } catch SecretStoreError.notFound {
            return false
        }
    }

    public static func hasAnyArtifacts(
        for keyID: UUID,
        config: SecretStoreConfiguration
    ) throws -> Bool {
        let services = [
            config.sealedP256Service,
            config.sealedP256TagService,
            config.sshKeysPrivateService,
            config.sshKeysPassphraseService,
        ]
        for service in services {
            do {
                _ = try KeychainOperations.retrieveData(
                    account: keyID.uuidString,
                    service: service,
                    config: config
                )
                return true
            } catch SecretStoreError.notFound {
                // Continue through every representation.
            }
        }
        return try SecureEnclaveKeyManager.keyExists(
            keyTag: SecureEnclaveKeyManager.keyTag(for: keyID)
        )
    }
}
