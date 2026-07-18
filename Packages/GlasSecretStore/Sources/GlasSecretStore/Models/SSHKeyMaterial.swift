//
//  SSHKeyMaterial.swift
//  GlasSecretStore
//
//  Retrieved SSH key material (private key + optional passphrase).
//

import Foundation

public struct SSHKeyMaterial: @unchecked Sendable {
    public let privateKey: SecureBytes
    public let passphrase: SecureBytes?

    public init(privateKey: SecureBytes, passphrase: SecureBytes?) {
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}
