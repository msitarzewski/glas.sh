//
//  PinnedSSHHostKey.swift
//  GlasSecretStore
//
//  Persisted SSH server host-key trust record.
//

import CryptoKit
import Foundation

public enum PinnedSSHHostKeyState: String, Codable, Hashable, Sendable {
    case active
    case revoked
}

public struct PinnedSSHHostKey: Codable, Identifiable, Hashable, Sendable {
    public var id: String { storageAccount }

    public let host: String
    public let port: Int
    public let algorithm: String
    public let publicKeyData: Data
    public let sha256Fingerprint: String
    public let createdAt: Date
    public var lastSeenAt: Date
    /// Monotonically increasing per endpoint. Only active records in the highest
    /// generation authorize a connection; lower generations are history even if
    /// an interrupted rotation has not rewritten their lifecycle state yet.
    public let generation: UInt64
    public let state: PinnedSSHHostKeyState
    public let revokedAt: Date?
    public let replacedBySHA256Fingerprint: String?

    public init(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyData: Data,
        sha256Fingerprint: String? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        generation: UInt64 = 0,
        state: PinnedSSHHostKeyState = .active,
        revokedAt: Date? = nil,
        replacedBySHA256Fingerprint: String? = nil
    ) {
        self.host = Self.normalizedHost(host)
        self.port = port
        self.algorithm = Self.normalizedAlgorithm(algorithm)
        self.publicKeyData = publicKeyData
        self.sha256Fingerprint = sha256Fingerprint ?? Self.sha256Fingerprint(for: publicKeyData)
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.generation = generation
        self.state = state
        self.revokedAt = revokedAt
        self.replacedBySHA256Fingerprint = replacedBySHA256Fingerprint
    }

    public init(
        host: String,
        port: Int,
        algorithm: String,
        publicKeyDataBase64: String,
        sha256Fingerprint: String? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        generation: UInt64 = 0,
        state: PinnedSSHHostKeyState = .active,
        revokedAt: Date? = nil,
        replacedBySHA256Fingerprint: String? = nil
    ) throws {
        guard let publicKeyData = Data(base64Encoded: publicKeyDataBase64) else {
            throw SecretStoreError.encodingFailed
        }
        self.init(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData,
            sha256Fingerprint: sha256Fingerprint,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            generation: generation,
            state: state,
            revokedAt: revokedAt,
            replacedBySHA256Fingerprint: replacedBySHA256Fingerprint
        )
    }

    public var lookupAccount: String {
        Self.lookupAccount(host: host, port: port)
    }

    public var storageAccount: String {
        Self.storageAccount(host: host, port: port, algorithm: algorithm, publicKeyData: publicKeyData)
    }

    public func matches(algorithm: String, publicKeyData: Data) -> Bool {
        self.algorithm == Self.normalizedAlgorithm(algorithm) && self.publicKeyData == publicKeyData
    }

    public func refreshed(lastSeenAt: Date = Date()) -> PinnedSSHHostKey {
        PinnedSSHHostKey(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData,
            sha256Fingerprint: sha256Fingerprint,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            generation: generation,
            state: state,
            revokedAt: revokedAt,
            replacedBySHA256Fingerprint: replacedBySHA256Fingerprint
        )
    }

    public func activated(generation: UInt64, activatedAt: Date = Date()) -> PinnedSSHHostKey {
        PinnedSSHHostKey(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData,
            sha256Fingerprint: sha256Fingerprint,
            createdAt: activatedAt,
            lastSeenAt: activatedAt,
            generation: generation
        )
    }

    public func revoked(at revokedAt: Date, replacedBy fingerprint: String) -> PinnedSSHHostKey {
        PinnedSSHHostKey(
            host: host,
            port: port,
            algorithm: algorithm,
            publicKeyData: publicKeyData,
            sha256Fingerprint: sha256Fingerprint,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            generation: generation,
            state: .revoked,
            revokedAt: revokedAt,
            replacedBySHA256Fingerprint: fingerprint
        )
    }

    public static func lookupAccount(host: String, port: Int) -> String {
        "\(normalizedHost(host)):\(port)"
    }

    public static func storageAccount(host: String, port: Int, algorithm: String, publicKeyData: Data) -> String {
        "\(lookupAccount(host: host, port: port)):\(normalizedAlgorithm(algorithm)):\(sha256Fingerprint(for: publicKeyData))"
    }

    public static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizedAlgorithm(_ algorithm: String) -> String {
        algorithm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func sha256Fingerprint(for publicKeyData: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKeyData))
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digest)"
    }

    public func validate() throws {
        guard !host.isEmpty else {
            throw SecretStoreError.encodingFailed
        }
        guard (1...65535).contains(port) else {
            throw SecretStoreError.encodingFailed
        }
        guard !algorithm.isEmpty else {
            throw SecretStoreError.encodingFailed
        }
        guard !publicKeyData.isEmpty else {
            throw SecretStoreError.encodingFailed
        }
        switch state {
        case .active:
            guard revokedAt == nil, replacedBySHA256Fingerprint == nil else {
                throw SecretStoreError.encodingFailed
            }
        case .revoked:
            guard revokedAt != nil,
                  let replacedBySHA256Fingerprint,
                  !replacedBySHA256Fingerprint.isEmpty else {
                throw SecretStoreError.encodingFailed
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case algorithm
        case publicKeyData
        case sha256Fingerprint
        case createdAt
        case lastSeenAt
        case generation
        case state
        case revokedAt
        case replacedBySHA256Fingerprint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = Self.normalizedHost(try container.decode(String.self, forKey: .host))
        port = try container.decode(Int.self, forKey: .port)
        algorithm = Self.normalizedAlgorithm(try container.decode(String.self, forKey: .algorithm))
        publicKeyData = try container.decode(Data.self, forKey: .publicKeyData)
        sha256Fingerprint = try container.decode(String.self, forKey: .sha256Fingerprint)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        state = try container.decodeIfPresent(PinnedSSHHostKeyState.self, forKey: .state) ?? .active
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        replacedBySHA256Fingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .replacedBySHA256Fingerprint
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(publicKeyData, forKey: .publicKeyData)
        try container.encode(sha256Fingerprint, forKey: .sha256Fingerprint)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(generation, forKey: .generation)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
        try container.encodeIfPresent(
            replacedBySHA256Fingerprint,
            forKey: .replacedBySHA256Fingerprint
        )
    }
}

public enum SSHHostTrustEvaluation: Codable, Hashable, Sendable {
    case notPinned
    case trusted(PinnedSSHHostKey)
    case changed(previous: [PinnedSSHHostKey], current: PinnedSSHHostKey)
}
