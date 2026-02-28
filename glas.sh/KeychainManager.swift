//
//  KeychainManager.swift
//  glas.sh
//
//  Thin wrapper delegating to GlasSecretStore's KeychainOperations and SSHKeyKeychainStore.
//  Provides app-specific convenience methods while sharing Keychain with glassdb.
//

import Foundation
import GlasSecretStore

enum KeychainManager {

    static let config = SecretStoreConfiguration(
        serviceNamePrefix: "sh.glas",
        accessGroup: "7JQGQ7CRH8.sh.glas.shared"
    )

    // MARK: - Server Password

    static func savePassword(_ password: String, for server: ServerConfiguration) throws {
        let account = "\(server.username)@\(server.host):\(server.port)"
        try KeychainOperations.savePassword(password, account: account, service: config.passwordsService, config: config)
    }

    static func retrievePassword(for server: ServerConfiguration) throws -> String {
        let account = "\(server.username)@\(server.host):\(server.port)"
        return try KeychainOperations.retrievePasswordWithFallback(
            account: account,
            primaryService: config.passwordsService,
            legacySuffix: "passwords",
            config: config
        )
    }

    static func deletePassword(for server: ServerConfiguration) throws {
        let account = "\(server.username)@\(server.host):\(server.port)"
        try KeychainOperations.deletePassword(account: account, service: config.passwordsService, config: config)
    }

    // MARK: - SSH Keys

    static func saveSSHKey(_ privateKey: String, passphrase: String?, for keyID: UUID) throws {
        try SSHKeyKeychainStore.save(privateKey: privateKey, passphrase: passphrase, for: keyID, config: config)
    }

    static func retrieveSSHKey(for keyID: UUID) throws -> SSHKeyMaterial {
        try SSHKeyKeychainStore.retrieve(for: keyID, config: config)
    }

    static func deleteSSHKey(for keyID: UUID) throws {
        try SSHKeyKeychainStore.delete(for: keyID, config: config)
    }

    // MARK: - Secure Enclave Wrapped P256

    static func saveSecureEnclaveWrappedP256(_ wrapped: Data, keyTag: String, for keyID: UUID) throws {
        try SSHKeyKeychainStore.saveSecureEnclaveWrapped(wrapped, keyTag: keyTag, for: keyID, config: config)
    }

    static func retrieveSecureEnclaveWrappedP256(for keyID: UUID) throws -> (wrapped: Data, keyTag: String) {
        try SSHKeyKeychainStore.retrieveSecureEnclaveWrapped(for: keyID, config: config)
    }

    // MARK: - Migration

    static func runMigrationsIfNeeded() {
        let migrationManager = SecretStoreMigrationManager(config: config)
        migrationManager.runScaffoldIfNeeded()
    }

    static func currentStatus() -> SecretStoreMigrationStatus {
        let passwordCount = KeychainOperations.itemCount(
            service: config.passwordsService, legacyOnly: true, config: config
        )
        let privateKeyCount = KeychainOperations.itemCount(
            service: config.sshKeysPrivateService, legacyOnly: true, config: config
        )
        let passphraseCount = KeychainOperations.itemCount(
            service: config.sshKeysPassphraseService, legacyOnly: true, config: config
        )
        return SecretStoreMigrationStatus(
            passwordItemCount: passwordCount,
            sshPrivateKeyItemCount: privateKeyCount,
            sshPassphraseItemCount: passphraseCount
        )
    }
}

struct SecretStoreMigrationStatus {
    let passwordItemCount: Int
    let sshPrivateKeyItemCount: Int
    let sshPassphraseItemCount: Int

    var pendingItemCount: Int {
        passwordItemCount + sshPrivateKeyItemCount + sshPassphraseItemCount
    }

    var needsMigration: Bool {
        pendingItemCount > 0
    }
}
