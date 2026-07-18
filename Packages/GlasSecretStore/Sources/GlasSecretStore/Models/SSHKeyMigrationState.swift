//
//  SSHKeyMigrationState.swift
//  GlasSecretStore
//
//  Per-key migration tracking.
//

import Foundation

public enum SSHKeyMigrationState: String, Codable, CaseIterable, Sendable {
    case notNeeded
    case pending
    case migrated
    case failed
}
