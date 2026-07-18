import Testing
import Foundation
import Security
@testable import GlasSecretStore

@Suite("SecureEnclaveKeyManager")
struct SecureEnclaveKeyManagerTests {

    @Test("keyTag format is correct")
    func keyTagFormat() {
        let id = UUID()
        let tag = SecureEnclaveKeyManager.keyTag(for: id)
        #expect(tag == "sh.glas.secureenclave.p256.\(id.uuidString)")
    }

    @Test("wrap throws secureEnclaveUnavailable on Simulator")
    func wrapThrowsOnSimulator() {
        let tag = "test.se.\(UUID().uuidString.prefix(8))"
        defer { try? SecureEnclaveKeyManager.deleteKeyIfPresent(keyTag: tag) }
        #expect(throws: (any Error).self) {
            try SecureEnclaveKeyManager.wrap(data: Data("test".utf8), keyTag: tag)
        }
    }

    @Test("deleteKeyIfPresent does not throw on non-existent tag")
    func deleteNonExistent() throws {
        try SecureEnclaveKeyManager.deleteKeyIfPresent(keyTag: "nonexistent.tag.\(UUID().uuidString)")
    }
}
