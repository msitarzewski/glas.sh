import Testing
import Foundation
import Security
@testable import GlasSecretStore

@Suite("SSHHostTrustKeychainStore")
struct SSHHostTrustKeychainStoreTests {

    private let config: SecretStoreConfiguration

    init() {
        let prefix = "test.SSHHostTrust.\(UUID().uuidString.prefix(8))"
        config = SecretStoreConfiguration(
            serviceNamePrefix: prefix,
            accessGroup: nil,
            legacyServiceNamePrefixes: []
        )
    }

    private func cleanupKeychain() {
        let services = [
            config.sshHostTrustService,
        ]
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    @Test("Pinned host key normalizes host and algorithm")
    func pinnedHostKeyNormalizesLookupFields() {
        let hostKey = PinnedSSHHostKey(
            host: " Example.COM ",
            port: 22,
            algorithm: " SSH-ED25519 ",
            publicKeyData: Data("server-key".utf8)
        )

        #expect(hostKey.host == "example.com")
        #expect(hostKey.algorithm == "ssh-ed25519")
        #expect(hostKey.lookupAccount == "example.com:22")
        #expect(hostKey.sha256Fingerprint.hasPrefix("SHA256:"))
    }

    @Test("Save and retrieve pinned host key by host and port")
    func roundTripByHostAndPort() throws {
        defer { cleanupKeychain() }
        let keyData = Data("server-key".utf8)
        try SSHHostTrustKeychainStore.save(
            host: "Example.COM",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: keyData,
            config: config
        )

        let retrieved = try SSHHostTrustKeychainStore.retrieve(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: keyData,
            config: config
        )
        #expect(retrieved.host == "example.com")
        #expect(retrieved.port == 22)
        #expect(retrieved.algorithm == "ssh-ed25519")
        #expect(retrieved.publicKeyData == keyData)
        #expect(retrieved.sha256Fingerprint == PinnedSSHHostKey.sha256Fingerprint(for: keyData))
    }

    @Test("Upsert replaces matching pinned host key")
    func upsertReplacesMatchingPinnedHostKey() throws {
        defer { cleanupKeychain() }
        let keyData = Data("same-key".utf8)
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        try SSHHostTrustKeychainStore.save(
            PinnedSSHHostKey(
                host: "db.example.com",
                port: 22,
                algorithm: "ssh-ed25519",
                publicKeyData: keyData,
                createdAt: oldDate,
                lastSeenAt: oldDate
            ),
            config: config
        )
        try SSHHostTrustKeychainStore.save(
            PinnedSSHHostKey(
                host: "DB.EXAMPLE.COM",
                port: 22,
                algorithm: "SSH-ED25519",
                publicKeyData: keyData,
                createdAt: oldDate,
                lastSeenAt: newDate
            ),
            config: config
        )

        let retrieved = try SSHHostTrustKeychainStore.retrieve(
            host: "db.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: keyData,
            config: config
        )
        #expect(retrieved.algorithm == "ssh-ed25519")
        #expect(retrieved.publicKeyData == keyData)
        #expect(retrieved.createdAt == oldDate)
        #expect(retrieved.lastSeenAt == newDate)
    }

    @Test("Port is part of host trust lookup")
    func portSpecificLookup() throws {
        defer { cleanupKeychain() }
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("port-22".utf8),
            config: config
        )
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 2222,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("port-2222".utf8),
            config: config
        )

        let defaultPort = try SSHHostTrustKeychainStore.retrieve(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("port-22".utf8),
            config: config
        )
        let alternatePort = try SSHHostTrustKeychainStore.retrieve(
            host: "example.com",
            port: 2222,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("port-2222".utf8),
            config: config
        )
        #expect(defaultPort.publicKeyData == Data("port-22".utf8))
        #expect(alternatePort.publicKeyData == Data("port-2222".utf8))
    }

    @Test("Delete removes pinned host key")
    func deleteRemovesPinnedHostKey() throws {
        defer { cleanupKeychain() }
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("server-key".utf8),
            config: config
        )

        try SSHHostTrustKeychainStore.delete(host: "example.com", port: 22, config: config)

        #expect(throws: SecretStoreError.self) {
            try SSHHostTrustKeychainStore.retrieve(
                host: "example.com",
                port: 22,
                algorithm: "ssh-ed25519",
                publicKeyData: Data("server-key".utf8),
                config: config
            )
        }
        #expect(!SSHHostTrustKeychainStore.contains(host: "example.com", port: 22, config: config))
    }

    @Test("Base64 initializer supports migration from encoded key data")
    func base64Initializer() throws {
        let keyData = Data("server-key".utf8)
        let hostKey = try PinnedSSHHostKey(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyDataBase64: keyData.base64EncodedString(),
            sha256Fingerprint: "SHA256:legacy"
        )

        #expect(hostKey.publicKeyData == keyData)
        #expect(hostKey.sha256Fingerprint == "SHA256:legacy")
    }

    @Test("Legacy records decode as active generation zero")
    func legacyRecordDecodingIsBackwardCompatible() throws {
        let keyData = Data("legacy-server-key".utf8)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastSeenAt = Date(timeIntervalSince1970: 1_700_000_100)
        let legacyPayload: [String: Any] = [
            "host": "Legacy.EXAMPLE.com",
            "port": 22,
            "algorithm": "SSH-ED25519",
            "publicKeyData": keyData.base64EncodedString(),
            "sha256Fingerprint": PinnedSSHHostKey.sha256Fingerprint(for: keyData),
            "createdAt": createdAt.timeIntervalSinceReferenceDate,
            "lastSeenAt": lastSeenAt.timeIntervalSinceReferenceDate,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)

        let decoded = try JSONDecoder().decode(PinnedSSHHostKey.self, from: data)

        #expect(decoded.host == "legacy.example.com")
        #expect(decoded.algorithm == "ssh-ed25519")
        #expect(decoded.generation == 0)
        #expect(decoded.state == .active)
        #expect(decoded.revokedAt == nil)
        #expect(decoded.replacedBySHA256Fingerprint == nil)
    }

    @Test("Rotation retains history without authorizing the previous key")
    func rotationRevokesPriorKey() throws {
        defer { cleanupKeychain() }
        let oldData = Data("old-server-key".utf8)
        let newData = Data("new-server-key".utf8)
        try SSHHostTrustKeychainStore.save(
            host: "rotate.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: oldData,
            config: config
        )
        let replacedAt = Date(timeIntervalSince1970: 1_700_000_200)

        let replacement = try SSHHostTrustKeychainStore.replace(
            with: PinnedSSHHostKey(
                host: "rotate.example.com",
                port: 22,
                algorithm: "ssh-ed25519",
                publicKeyData: newData
            ),
            config: config,
            replacedAt: replacedAt
        )

        #expect(replacement.generation == 1)
        #expect(replacement.state == .active)
        let authorized = try SSHHostTrustKeychainStore.authorizedRecords(
            host: "rotate.example.com",
            port: 22,
            config: config
        )
        #expect(authorized.map(\.publicKeyData) == [newData])
        let records = try SSHHostTrustKeychainStore.records(
            host: "rotate.example.com",
            port: 22,
            config: config
        )
        let history = try #require(records.first { $0.publicKeyData == oldData })
        #expect(history.state == .revoked)
        #expect(history.revokedAt == replacedAt)
        #expect(history.replacedBySHA256Fingerprint == replacement.sha256Fingerprint)

        let oldEvaluation = try SSHHostTrustKeychainStore.evaluate(
            host: "rotate.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: oldData,
            config: config
        )
        guard case .changed(let previous, _) = oldEvaluation else {
            Issue.record("A revoked key must be reported as changed, never trusted")
            return
        }
        #expect(previous.map(\.publicKeyData) == [newData])
    }

    @Test("Revoked history alone does not mark an endpoint trusted")
    func revokedHistoryDoesNotAuthorizeEndpoint() throws {
        defer { cleanupKeychain() }
        let revoked = PinnedSSHHostKey(
            host: "history-only.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("historical-key".utf8)
        ).revoked(
            at: Date(timeIntervalSince1970: 1_700_000_300),
            replacedBy: "SHA256:replacement"
        )
        try SSHHostTrustKeychainStore.save(revoked, config: config)

        #expect(!SSHHostTrustKeychainStore.contains(
            host: revoked.host,
            port: revoked.port,
            config: config
        ))
        #expect(try SSHHostTrustKeychainStore.authorizedRecords(
            host: revoked.host,
            port: revoked.port,
            config: config
        ).isEmpty)
    }

    @Test("Rotation history is bounded per endpoint")
    func rotationHistoryIsBounded() throws {
        defer { cleanupKeychain() }
        let host = "bounded-history.example.com"
        try SSHHostTrustKeychainStore.save(
            host: host,
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("key-0".utf8),
            config: config
        )

        for index in 1...6 {
            try SSHHostTrustKeychainStore.replace(
                with: PinnedSSHHostKey(
                    host: host,
                    port: 22,
                    algorithm: "ssh-ed25519",
                    publicKeyData: Data("key-\(index)".utf8)
                ),
                config: config,
                replacedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                historyLimit: 3
            )
        }

        let records = try SSHHostTrustKeychainStore.records(host: host, port: 22, config: config)
        #expect(records.count == 4)
        #expect(records.filter { $0.state == .revoked }.count == 3)
        let authorized = try SSHHostTrustKeychainStore.authorizedRecords(
            host: host,
            port: 22,
            config: config
        )
        #expect(authorized.count == 1)
        #expect(authorized.first?.publicKeyData == Data("key-6".utf8))
        #expect(authorized.first?.generation == 6)
    }

    @Test("Evaluate reports notPinned when no host key exists")
    func evaluateNotPinned() throws {
        defer { cleanupKeychain() }
        let result = try SSHHostTrustKeychainStore.evaluate(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("server-key".utf8),
            config: config
        )
        #expect(result == .notPinned)
    }

    @Test("Evaluate reports trusted for matching pinned host key")
    func evaluateTrusted() throws {
        defer { cleanupKeychain() }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let keyData = Data("server-key".utf8)
        try SSHHostTrustKeychainStore.save(
            PinnedSSHHostKey(
                host: "example.com",
                port: 22,
                algorithm: "ssh-ed25519",
                publicKeyData: keyData,
                createdAt: createdAt,
                lastSeenAt: createdAt
            ),
            config: config
        )

        let result = try SSHHostTrustKeychainStore.evaluate(
            host: "EXAMPLE.COM",
            port: 22,
            algorithm: "SSH-ED25519",
            publicKeyData: keyData,
            config: config,
            lastSeenAt: refreshedAt
        )

        guard case .trusted(let hostKey) = result else {
            Issue.record("Expected trusted evaluation")
            return
        }
        #expect(hostKey.host == "example.com")
        #expect(hostKey.createdAt == createdAt)
        #expect(hostKey.lastSeenAt == refreshedAt)
        let readback = try SSHHostTrustKeychainStore.retrieve(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: keyData,
            config: config
        )
        #expect(readback == hostKey)
    }

    @Test("Evaluate reports changed for mismatched host key data")
    func evaluateChangedKey() throws {
        defer { cleanupKeychain() }
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("old-key".utf8),
            config: config
        )

        let result = try SSHHostTrustKeychainStore.evaluate(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("new-key".utf8),
            config: config
        )

        guard case .changed(let previous, let current) = result else {
            Issue.record("Expected changed evaluation")
            return
        }
        #expect(previous.map(\.publicKeyData) == [Data("old-key".utf8)])
        #expect(current.publicKeyData == Data("new-key".utf8))
    }

    @Test("Multiple algorithms can be pinned for one host and port")
    func multipleAlgorithmsForSameHostPort() throws {
        defer { cleanupKeychain() }
        let ed25519 = Data("ed25519-key".utf8)
        let rsa = Data("rsa-key".utf8)
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: ed25519,
            config: config
        )
        try SSHHostTrustKeychainStore.save(
            host: "example.com",
            port: 22,
            algorithm: "ssh-rsa",
            publicKeyData: rsa,
            config: config
        )

        let records = try SSHHostTrustKeychainStore.records(host: "example.com", port: 22, config: config)
        #expect(Set(records.map(\.algorithm)) == ["ssh-ed25519", "ssh-rsa"])

        let result = try SSHHostTrustKeychainStore.evaluate(
            host: "example.com",
            port: 22,
            algorithm: "ssh-rsa",
            publicKeyData: rsa,
            config: config
        )
        guard case .trusted(let hostKey) = result else {
            Issue.record("Expected trusted evaluation")
            return
        }
        #expect(hostKey.publicKeyData == rsa)
    }

    @Test("List returns all pinned hosts sorted by host then port")
    func allPinnedHosts() throws {
        defer { cleanupKeychain() }
        try SSHHostTrustKeychainStore.save(
            host: "b.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("b".utf8),
            config: config
        )
        try SSHHostTrustKeychainStore.save(
            host: "a.example.com",
            port: 2222,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("a2".utf8),
            config: config
        )
        try SSHHostTrustKeychainStore.save(
            host: "a.example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            publicKeyData: Data("a1".utf8),
            config: config
        )

        let hosts = try SSHHostTrustKeychainStore.allPinnedHosts(config: config)
        #expect(hosts.map(\.lookupAccount) == [
            "a.example.com:22",
            "a.example.com:2222",
            "b.example.com:22",
        ])
    }
}
