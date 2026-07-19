//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if swift(>=5.6)
@preconcurrency import NIOCore
#else
import NIOCore
#endif // swift(>=5.6)

/// `SSHChannelData` is the data type that is passed around in `SSHChildChannel` objects.
///
/// This is the baseline kind of data available for `SSHChildChannel` objects. It encapsulates
/// the difference between `SSH_MSG_CHANNEL_DATA` and `SSH_MSG_CHANNEL_EXTENDED_DATA` by storing
/// them both in a single data type that marks this difference.
public struct SSHChannelData {
    public var type: DataType

    public var data: IOData

    public init(type: DataType, data: IOData) {
        self.type = type
        self.data = data
    }
}

extension SSHChannelData: Equatable {}

extension SSHChannelData: Sendable {}

public extension SSHChannelData {
    /// The type of this channel data. Regular `.channel` data is the standard type of data on an `SSHChannel`,
    /// but extended data types (such as `.stderr`) are available as well.
    struct DataType {
        internal var _baseType: UInt32

        /// Regular channel data.
        public static let channel = DataType(_baseType: 0)

        /// Extended data associated with stderr.
        public static let stdErr = DataType(_baseType: 1)

        /// Construct an `SSHChannelData` for an unknown type of extended data.
        ///
        /// Returns `nil` for the reserved channel-data code (`0`) and for values
        /// outside the unsigned 32-bit range used by the SSH wire format.
        public init?(extended: Int) {
            guard let extended = UInt32(exactly: extended), extended != 0 else {
                return nil
            }
            self._baseType = extended
        }

        private init(_baseType: UInt32) {
            self._baseType = _baseType
        }
    }
}

extension SSHChannelData.DataType: Hashable {}

extension SSHChannelData.DataType: Sendable {}

extension SSHChannelData.DataType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .channel:
            return "SSHChannelData.channel"
        case .stdErr:
            return "SSHChannelData.stdErr"
        default:
            return "SSHChannelData(extended: \(self._baseType))"
        }
    }
}

extension SSHChannelData {
    internal func validateForSerialization() throws {
        guard case .byteBuffer = self.data else {
            throw ChannelError.operationUnsupported
        }

        guard self.type == .channel || self.type == .stdErr else {
            throw ChannelError.operationUnsupported
        }
    }

    internal init(_ message: SSHMessage.ChannelDataMessage) {
        self = .init(type: .channel, data: .byteBuffer(message.data))
    }

    internal init(_ message: SSHMessage.ChannelExtendedDataMessage) {
        self = .init(type: .init(message.dataTypeCode), data: .byteBuffer(message.data))
    }
}

extension SSHChannelData.DataType {
    internal init(_ code: SSHMessage.ChannelExtendedDataMessage.Code) {
        switch code {
        case .stderr:
            self = .stdErr
        }
    }
}

extension SSHMessage {
    internal init(_ channelData: SSHChannelData, recipientChannel: UInt32) throws {
        try channelData.validateForSerialization()

        guard case .byteBuffer(let bb) = channelData.data else {
            throw ChannelError.operationUnsupported
        }

        switch channelData.type {
        case .channel:
            self = .channelData(.init(recipientChannel: recipientChannel, data: bb))
        case .stdErr:
            self = .channelExtendedData(.init(recipientChannel: recipientChannel, dataTypeCode: .stderr, data: bb))
        default:
            throw ChannelError.operationUnsupported
        }
    }
}
