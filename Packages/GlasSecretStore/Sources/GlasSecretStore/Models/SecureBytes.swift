//
//  SecureBytes.swift
//  GlasSecretStore
//
//  Zeroable byte buffer for sensitive key material.
//  Locks memory pages with mlock() and zeros on deallocation.
//

import Foundation

public final class SecureBytes: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {

    private let buffer: UnsafeMutableBufferPointer<UInt8>

    public var count: Int { buffer.count }

    public init(_ data: Data) {
        let count = data.count
        let pointer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
        _ = data.copyBytes(to: pointer)
        mlock(pointer.baseAddress!, count)
        self.buffer = pointer
    }

    deinit {
        let base = buffer.baseAddress!
        let count = buffer.count
        memset_s(base, count, 0, count)
        munlock(base, count)
        buffer.deallocate()
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(buffer))
    }

    public func toData() -> Data {
        Data(buffer)
    }

    public func toUTF8String() -> String? {
        String(bytes: buffer, encoding: .utf8)
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        "SecureBytes(\(buffer.count) bytes, redacted)"
    }

    public var debugDescription: String {
        "SecureBytes(\(buffer.count) bytes, redacted)"
    }
}
