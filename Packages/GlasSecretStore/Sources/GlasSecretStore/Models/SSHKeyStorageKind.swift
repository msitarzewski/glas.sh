//
//  SSHKeyStorageKind.swift
//  GlasSecretStore
//
//  How an SSH key is stored.
//

import Foundation

public enum SSHKeyStorageKind: String, Codable, CaseIterable, Sendable {
    case legacy
    case imported
    case secureEnclave

    public var badgePrefix: String {
        switch self {
        case .legacy: return "Legacy"
        case .imported: return "Imported"
        case .secureEnclave: return "Secure Enclave"
        }
    }
}
