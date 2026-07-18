import Testing
import Foundation
@testable import GlasSecretStore

@Suite("SecureBytes")
struct SecureBytesTests {

    @Test("Init from Data sets correct count")
    func initFromData() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let secure = SecureBytes(data)
        #expect(secure.count == 4)
    }

    @Test("toData round-trips correctly")
    func toDataRoundTrip() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let secure = SecureBytes(original)
        #expect(secure.toData() == original)
    }

    @Test("toUTF8String with valid UTF-8")
    func toUTF8StringValid() {
        let text = "hello world"
        let secure = SecureBytes(Data(text.utf8))
        #expect(secure.toUTF8String() == text)
    }

    @Test("toUTF8String returns nil for invalid UTF-8")
    func toUTF8StringInvalid() {
        let secure = SecureBytes(Data([0xFF, 0xFE]))
        #expect(secure.toUTF8String() == nil)
    }

    @Test("withUnsafeBytes provides correct content")
    func withUnsafeBytes() {
        let data = Data([0x0A, 0x0B, 0x0C])
        let secure = SecureBytes(data)
        secure.withUnsafeBytes { buffer in
            #expect(buffer.count == 3)
            #expect(buffer[0] == 0x0A)
            #expect(buffer[1] == 0x0B)
            #expect(buffer[2] == 0x0C)
        }
    }

    @Test("description redacts content")
    func descriptionRedacts() {
        let secure = SecureBytes(Data([0x01, 0x02]))
        #expect(secure.description.contains("redacted"))
        #expect(!secure.description.contains("01"))
    }

    @Test("debugDescription redacts content")
    func debugDescriptionRedacts() {
        let secure = SecureBytes(Data([0x01, 0x02]))
        #expect(secure.debugDescription.contains("redacted"))
        #expect(!secure.debugDescription.contains("01"))
    }

    @Test("Empty data init produces count 0")
    func emptyDataInit() {
        let secure = SecureBytes(Data())
        #expect(secure.count == 0)
        #expect(secure.toData() == Data())
    }
}
