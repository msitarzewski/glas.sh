//
//  StoredSSHKey.swift
//  GlasSecretStore
//
//  SSH key metadata (persisted to UserDefaults).
//  Backward-compatible with glas.sh v1 format — missing fields get defaults.
//

import Foundation

public struct StoredSSHKey: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let algorithm: String
    public var storageKind: SSHKeyStorageKind
    public var algorithmKind: SSHKeyAlgorithmKind
    public var migrationState: SSHKeyMigrationState
    public var keyTag: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: String,
        storageKind: SSHKeyStorageKind = .imported,
        algorithmKind: SSHKeyAlgorithmKind = .unknown,
        migrationState: SSHKeyMigrationState = .notNeeded,
        keyTag: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.storageKind = storageKind
        self.algorithmKind = algorithmKind
        self.migrationState = migrationState
        self.keyTag = keyTag
        self.createdAt = createdAt
    }

    public var keyTypeBadge: String {
        "\(storageKind.badgePrefix) \(algorithmKind.badgeName)"
    }

    // MARK: - Backward-Compatible Codable

    enum CodingKeys: String, CodingKey {
        case id, name, algorithm, storageKind, algorithmKind, migrationState, keyTag, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Fields added after v1 — decode with defaults for backward compatibility
        storageKind = try container.decodeIfPresent(SSHKeyStorageKind.self, forKey: .storageKind) ?? .legacy
        algorithmKind = try container.decodeIfPresent(SSHKeyAlgorithmKind.self, forKey: .algorithmKind)
            ?? SSHKeyAlgorithmKind.fromLegacyDescription(algorithm)
        migrationState = try container.decodeIfPresent(SSHKeyMigrationState.self, forKey: .migrationState) ?? .notNeeded
        keyTag = try container.decodeIfPresent(String.self, forKey: .keyTag)
    }
}
