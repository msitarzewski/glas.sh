//
//  SSHKeyAlgorithmKind.swift
//  GlasSecretStore
//
//  SSH key algorithm classification.
//

import Foundation

public enum SSHKeyAlgorithmKind: String, Codable, CaseIterable, Sendable {
    case rsa
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case unknown

    public var badgeName: String {
        switch self {
        case .rsa: return "RSA"
        case .ed25519: return "ED25519"
        case .ecdsaP256: return "P-256"
        case .ecdsaP384: return "P-384"
        case .ecdsaP521: return "P-521"
        case .unknown: return "Unknown"
        }
    }

    public static func fromLegacyDescription(_ value: String) -> SSHKeyAlgorithmKind {
        switch value.lowercased() {
        case "rsa":
            return .rsa
        case "ed25519":
            return .ed25519
        case "ecdsa p-256", "ecdsa-p256", "ecdsa_p256":
            return .ecdsaP256
        case "ecdsa p-384", "ecdsa-p384", "ecdsa_p384":
            return .ecdsaP384
        case "ecdsa p-521", "ecdsa-p521", "ecdsa_p521":
            return .ecdsaP521
        default:
            return .unknown
        }
    }
}
