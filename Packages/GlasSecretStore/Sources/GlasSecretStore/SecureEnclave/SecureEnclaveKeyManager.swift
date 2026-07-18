//
//  SecureEnclaveKeyManager.swift
//  GlasSecretStore
//
//  P256 wrap/unwrap via Secure Enclave.
//  Lifted from glas.sh SecureEnclaveKeyManager.
//

import Foundation
import Security

public enum SecureEnclaveKeyManager: Sendable {

    public static func keyTag(for keyID: UUID) -> String {
        "sh.glas.secureenclave.p256.\(keyID.uuidString)"
    }

    public static func wrap(data: Data, keyTag: String) throws -> Data {
        guard let privateKey = try secureEnclavePrivateKey(keyTag: keyTag, createIfMissing: true) else {
            throw SecretStoreError.secureEnclaveUnavailable
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecretStoreError.secureEnclaveOperationFailed
        }
        let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw SecretStoreError.secureEnclaveOperationFailed
        }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, algorithm, data as CFData, &error) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? SecretStoreError.secureEnclaveOperationFailed
        }
        return wrapped
    }

    public static func unwrap(wrapped: Data, keyTag: String) throws -> Data {
        guard let privateKey = try secureEnclavePrivateKey(keyTag: keyTag, createIfMissing: false) else {
            throw SecretStoreError.secureEnclaveUnavailable
        }
        let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw SecretStoreError.secureEnclaveOperationFailed
        }
        var error: Unmanaged<CFError>?
        guard let unwrapped = SecKeyCreateDecryptedData(privateKey, algorithm, wrapped as CFData, &error) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? SecretStoreError.secureEnclaveOperationFailed
        }
        return unwrapped
    }

    public static func deleteKeyIfPresent(keyTag: String) throws {
        let tagData = keyTag.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unableToDelete
        }
    }

    public static func keyExists(keyTag: String) throws -> Bool {
        try secureEnclavePrivateKey(keyTag: keyTag, createIfMissing: false) != nil
    }

    // MARK: - Private

    private static func secureEnclavePrivateKey(keyTag: String, createIfMissing: Bool) throws -> SecKey? {
        let tagData = keyTag.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let ref = result {
            return (ref as! SecKey)
        }
        if status == errSecItemNotFound {
            if !createIfMissing { return nil }
        } else {
            throw SecretStoreError.queryFailed(status: status)
        }

        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &error
        )
        guard let access else {
            throw (error?.takeRetainedValue() as Error?) ?? SecretStoreError.secureEnclaveOperationFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessControl as String: access
            ]
        ]
        guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw (error?.takeRetainedValue() as Error?) ?? SecretStoreError.secureEnclaveUnavailable
        }
        return created
    }
}
