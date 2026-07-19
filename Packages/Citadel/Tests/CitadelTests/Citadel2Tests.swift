import Crypto
import BigInt
import NIO
import XCTest
import Logging
@preconcurrency @testable import Citadel
import NIOSSH

final class Citadel2Tests: XCTestCase {
    private enum EmbeddedSFTPTestError: Error {
        case unexpectedOutbound(String)
    }

    func testAuthenticationMethodConsumesEachOfferExactlyOnce() throws {
        let eventLoop = EmbeddedEventLoop()
        let authentication = SSHAuthenticationMethod.passwordBased(
            username: "test-user",
            password: "test-password"
        )

        let firstChallenge = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        authentication.nextAuthenticationType(
            availableMethods: .password,
            nextChallengePromise: firstChallenge
        )
        let offer = try XCTUnwrap(firstChallenge.futureResult.wait())
        XCTAssertEqual(offer.username, "test-user")
        guard case .password(let password) = offer.offer else {
            return XCTFail("Expected the configured password offer")
        }
        XCTAssertEqual(password.password, "test-password")

        let exhaustedChallenge = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        authentication.nextAuthenticationType(
            availableMethods: .password,
            nextChallengePromise: exhaustedChallenge
        )
        XCTAssertThrowsError(try exhaustedChallenge.futureResult.wait()) { error in
            guard case SSHClientError.allAuthenticationOptionsFailed = error else {
                return XCTFail("Unexpected exhaustion error: \(error)")
            }
        }
    }

    private func makeEmbeddedSFTPClient() throws -> (EmbeddedChannel, SFTPClient) {
        let channel = EmbeddedChannel()
        let responses = SFTPResponses(sftpVersion: channel.eventLoop.makePromise())
        responses.isInitialized = true
        try channel.pipeline.addHandler(
            SFTPClientInboundHandler(
                responses: responses,
                logger: Logger(label: "CitadelTests.SFTP")
            )
        ).wait()
        return (
            channel,
            SFTPClient(
                channel: channel,
                responses: responses,
                logger: Logger(label: "CitadelTests.SFTP")
            )
        )
    }

    private func makeAsyncTestingSFTPClient() async throws -> (NIOAsyncTestingChannel, SFTPClient) {
        let channel = NIOAsyncTestingChannel()
        let responses = SFTPResponses(sftpVersion: channel.eventLoop.makePromise())
        responses.isInitialized = true
        try await channel.pipeline.addHandler(
            SFTPClientInboundHandler(
                responses: responses,
                logger: Logger(label: "CitadelTests.SFTP")
            )
        ).get()
        try await channel.register().get()
        return (
            channel,
            SFTPClient(
                channel: channel,
                responses: responses,
                logger: Logger(label: "CitadelTests.SFTP")
            )
        )
    }

    private func nextSFTPOutboundMessage(
        from channel: NIOAsyncTestingChannel
    ) async throws -> SFTPMessage {
        try await channel.waitForOutboundWrite(as: SFTPMessage.self)
    }

    private func openDirectoryForEmbeddedListing(
        on channel: NIOAsyncTestingChannel,
        path: String,
        handleBytes: [UInt8]
    ) async throws -> ByteBuffer {
        let realPathMessage = try await nextSFTPOutboundMessage(from: channel)
        guard case .realpath(let realPath) = realPathMessage else {
            throw EmbeddedSFTPTestError.unexpectedOutbound(realPathMessage.debugDescription)
        }
        XCTAssertEqual(realPath.path, path)
        let realPathResponse = try await channel.writeInbound(SFTPMessage.name(.init(
            requestId: realPath.requestId,
            components: [.init(filename: path, longname: path, attributes: .none)]
        )))
        XCTAssertTrue(realPathResponse.isEmpty)

        let openDirectoryMessage = try await nextSFTPOutboundMessage(from: channel)
        guard case .opendir(let openDirectory) = openDirectoryMessage else {
            throw EmbeddedSFTPTestError.unexpectedOutbound(openDirectoryMessage.debugDescription)
        }
        XCTAssertEqual(openDirectory.handle, path)
        let handle = ByteBuffer(bytes: handleBytes)
        let openDirectoryResponse = try await channel.writeInbound(SFTPMessage.handle(.init(
            requestId: openDirectory.requestId,
            handle: handle
        )))
        XCTAssertTrue(openDirectoryResponse.isEmpty)
        return handle
    }

    private func nextReadDirectoryRequest(
        from channel: NIOAsyncTestingChannel,
        expectedHandle: ByteBuffer
    ) async throws -> SFTPMessage.ReadDir {
        let message = try await nextSFTPOutboundMessage(from: channel)
        guard case .readdir(let readDirectory) = message else {
            throw EmbeddedSFTPTestError.unexpectedOutbound(message.debugDescription)
        }
        XCTAssertEqual(
            Array(readDirectory.handle.readableBytesView),
            Array(expectedHandle.readableBytesView)
        )
        return readDirectory
    }

    private func expectAndAcknowledgeDirectoryClose(
        on channel: NIOAsyncTestingChannel,
        expectedHandle: ByteBuffer
    ) async throws {
        let message = try await nextSFTPOutboundMessage(from: channel)
        guard case .closeFile(let close) = message else {
            throw EmbeddedSFTPTestError.unexpectedOutbound(message.debugDescription)
        }
        XCTAssertEqual(
            Array(close.handle.readableBytesView),
            Array(expectedHandle.readableBytesView)
        )
        let closeResponse = try await channel.writeInbound(SFTPMessage.status(.init(
            requestId: close.requestId,
            errorCode: .ok,
            message: "closed",
            languageTag: "en"
        )))
        XCTAssertTrue(closeResponse.isEmpty)
    }

    func testSFTPHandleDebugDescriptionUsesTwoLowercaseHexDigitsPerByte() {
        var handle = ByteBuffer()
        handle.writeBytes([0x00, 0xAF, 0x10, 0xFF])

        XCTAssertEqual(handle.sftpHandleDebugDescription, "00af10ff")
    }

    func testSFTPParserRejectsZeroPacketLength() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        var packet = channel.allocator.buffer(capacity: 4)
        packet.writeInteger(UInt32(0))

        XCTAssertThrowsError(try channel.writeInbound(packet)) { error in
            guard case SFTPError.invalidPacketLength(0) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try channel.finish())
    }

    func testSFTPParserRejectsOversizedDeclaredPacketLengthWithoutWaitingForBody() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        let oversized = SFTPMessageParser.maximumPacketLength + 1
        var packet = channel.allocator.buffer(capacity: 4)
        packet.writeInteger(oversized)

        XCTAssertThrowsError(try channel.writeInbound(packet)) { error in
            guard case SFTPError.invalidPacketLength(oversized) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try channel.finish())
    }

    func testSFTPParserBuffersIncompleteValidPacketUntilRemainderArrives() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        var packet = channel.allocator.buffer(capacity: 9)
        packet.writeInteger(UInt32(5))
        packet.writeInteger(SFTPMessageType.initialize.rawValue)
        packet.writeInteger(UInt32(3))

        let firstFragment = packet.readSlice(length: 7)!
        XCTAssertTrue(try channel.writeInbound(firstFragment).isEmpty)
        XCTAssertNil(try channel.readInbound(as: SFTPMessage.self))

        XCTAssertTrue(try channel.writeInbound(packet).isFull)
        let decoded = try XCTUnwrap(channel.readInbound(as: SFTPMessage.self))
        guard case .initialize(let initialize) = decoded else {
            return XCTFail("Expected initialize message, got \(decoded)")
        }
        XCTAssertEqual(initialize.version.rawValue, 3)
        XCTAssertNoThrow(try channel.finish())
    }

    func testOpenSSHExtendedRequestSerialization() throws {
        var extensionPayload = ByteBuffer()
        extensionPayload.writeSSHString("/.hidden.partial")
        extensionPayload.writeSSHString("/final.txt")
        let message = SFTPMessage.extended(.init(
            requestId: 42,
            requestName: "hardlink@openssh.com",
            payload: extensionPayload
        ))

        var encoded = ByteBuffer()
        try SFTPMessageSerializer().encode(data: message, out: &encoded)

        let packetLength = try XCTUnwrap(encoded.readInteger(as: UInt32.self))
        XCTAssertEqual(packetLength, UInt32(encoded.readableBytes))
        XCTAssertEqual(encoded.readInteger(as: UInt8.self), SFTPMessageType.extended.rawValue)
        XCTAssertEqual(encoded.readInteger(as: UInt32.self), 42)
        XCTAssertEqual(encoded.readSSHString(), "hardlink@openssh.com")
        XCTAssertEqual(encoded.readSSHString(), "/.hidden.partial")
        XCTAssertEqual(encoded.readSSHString(), "/final.txt")
        XCTAssertEqual(encoded.readableBytes, 0)
    }

    func testFStatAndLStatPacketsSerializeAndParseWithExactPayloads() throws {
        var handle = ByteBuffer()
        handle.writeBytes([0x00, 0xAF, 0x10])
        let messages: [SFTPMessage] = [
            .fstat(.init(requestId: 71, handle: handle)),
            .lstat(.init(requestId: 72, path: "/partial-link")),
        ]

        for message in messages {
            var encoded = ByteBuffer()
            try SFTPMessageSerializer().encode(data: message, out: &encoded)
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
            XCTAssertTrue(try channel.writeInbound(encoded).isFull)
            let decoded = try XCTUnwrap(channel.readInbound(as: SFTPMessage.self))

            switch decoded {
            case .fstat(let request):
                XCTAssertEqual(request.requestId, 71)
                XCTAssertEqual(Array(request.handle.readableBytesView), [0x00, 0xAF, 0x10])
            case .lstat(let request):
                XCTAssertEqual(request.requestId, 72)
                XCTAssertEqual(request.path, "/partial-link")
            default:
                XCTFail("Unexpected decoded packet: \(decoded)")
            }
            XCTAssertNoThrow(try channel.finish())
        }
    }

    func testTypedAttributePacketRoundTripPreservesFileTypeAndExtendedMetadata() throws {
        var attributes = SFTPFileAttributes(size: 4_096)
        attributes.permissions = 0o100640
        attributes.extended = [("vendor-checksum", "sha256:abc")]
        let message = SFTPMessage.attributes(.init(requestId: 88, attributes: attributes))
        var encoded = ByteBuffer()
        try SFTPMessageSerializer().encode(data: message, out: &encoded)

        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        XCTAssertTrue(try channel.writeInbound(encoded).isFull)
        let decoded = try XCTUnwrap(channel.readInbound(as: SFTPMessage.self))
        guard case .attributes(let reply) = decoded else {
            return XCTFail("Expected typed attributes reply")
        }
        XCTAssertEqual(reply.requestId, 88)
        XCTAssertEqual(reply.attributes, attributes)
        XCTAssertEqual(reply.attributes.fileType, .regular)
        XCTAssertTrue(reply.attributes.isRegularFile)
        XCTAssertNoThrow(try channel.finish())
    }

    func testTypedFileAttributesFailClosedForMissingAndNonRegularModes() {
        var attributes = SFTPFileAttributes()
        XCTAssertNil(attributes.fileType)
        XCTAssertFalse(attributes.isRegularFile)

        attributes.permissions = 0o120777
        XCTAssertEqual(attributes.fileType, .symbolicLink)
        XCTAssertFalse(attributes.isRegularFile)

        attributes.permissions = 0o040755
        XCTAssertEqual(attributes.fileType, .directory)
        XCTAssertFalse(attributes.isRegularFile)

        attributes.permissions = 0o100600
        XCTAssertEqual(attributes.fileType, .regular)
        XCTAssertTrue(attributes.isRegularFile)
    }

    func testOpenWithCreateAndExclusiveFlagsSerializesExistingTargetFailurePolicy() throws {
        let message = SFTPMessage.openFile(.init(
            requestId: 91,
            filePath: "/must-not-exist",
            pFlags: [.write, .create, .forceCreate],
            attributes: .none
        ))
        var encoded = ByteBuffer()
        try SFTPMessageSerializer().encode(data: message, out: &encoded)

        _ = encoded.readInteger(as: UInt32.self)
        XCTAssertEqual(encoded.readInteger(as: UInt8.self), SFTPMessageType.openFile.rawValue)
        XCTAssertEqual(encoded.readInteger(as: UInt32.self), 91)
        XCTAssertEqual(encoded.readSSHString(), "/must-not-exist")
        let flags = try XCTUnwrap(encoded.readInteger(as: UInt32.self))
        XCTAssertEqual(
            flags,
            SFTPOpenFileFlags.write.rawValue
                | SFTPOpenFileFlags.create.rawValue
                | SFTPOpenFileFlags.forceCreate.rawValue
        )
    }

    func testOpenFileReadAttributesBuildsFStatWithExactHandle() throws {
        let (channel, client) = try makeEmbeddedSFTPClient()
        var handle = ByteBuffer()
        handle.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let file = SFTPFile(client: client, path: "/path-can-change", handle: handle)

        let request = try file.makeReadAttributesRequest()
        guard case .fstat(let fstat) = request else {
            return XCTFail("Expected FSTAT for an open file handle")
        }
        XCTAssertEqual(Array(fstat.handle.readableBytesView), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertNoThrow(try channel.finish())
    }

    func testLStatBuildsPathRequestAndInboundStatusErrorIsPropagated() throws {
        let (channel, client) = try makeEmbeddedSFTPClient()
        let request = client.makeLStatRequest(at: "/retained.partial")
        guard case .lstat(let lstat) = request else {
            return XCTFail("Expected LSTAT request")
        }
        XCTAssertEqual(lstat.path, "/retained.partial")

        let response = channel.eventLoop.makePromise(of: SFTPResponse.self)
        client.responses.responses[lstat.requestId] = response
        XCTAssertTrue(try channel.writeInbound(SFTPMessage.status(.init(
            requestId: lstat.requestId,
            errorCode: .noSuchFile,
            message: "No such file",
            languageTag: "en"
        ))).isEmpty)
        XCTAssertThrowsError(try response.futureResult.wait()) { error in
            guard let status = error as? SFTPMessage.Status else {
                return XCTFail("Expected SFTP status, got \(error)")
            }
            XCTAssertEqual(status.errorCode, .noSuchFile)
            XCTAssertEqual(status.message, "No such file")
        }
        XCTAssertNoThrow(try channel.finish())
    }

    func testOpenSSHExtensionsRequireAdvertisedVersionOneAndPreservePayloads() throws {
        let (channel, client) = try makeEmbeddedSFTPClient()
        client.setServerExtensions([
            ("hardlink@openssh.com", "1"),
            ("fsync@openssh.com", "1"),
        ])
        XCTAssertEqual(client.serverExtensionVersion(for: "hardlink@openssh.com"), "1")
        XCTAssertTrue(client.supportsExtension("hardlink@openssh.com", version: "1"))
        XCTAssertFalse(client.supportsExtension("hardlink@openssh.com", version: "2"))

        let hardLinkRequest = try client.makeHardLinkRequest(
            at: "/retained.partial",
            to: "/existing-target"
        )
        guard case .extended(var hardLink) = hardLinkRequest else {
            return XCTFail("Expected hardlink extension request")
        }
        XCTAssertEqual(hardLink.requestName, "hardlink@openssh.com")
        XCTAssertEqual(hardLink.payload.readSSHString(), "/retained.partial")
        XCTAssertEqual(hardLink.payload.readSSHString(), "/existing-target")

        var handle = ByteBuffer()
        handle.writeBytes([0xCA, 0xFE])
        let file = SFTPFile(client: client, path: "/retained.partial", handle: handle)
        let fsyncRequest = try file.makeSynchronizeRequest()
        guard case .extended(var fsync) = fsyncRequest else {
            return XCTFail("Expected fsync extension request")
        }
        XCTAssertEqual(fsync.requestName, "fsync@openssh.com")
        XCTAssertEqual(Array(try XCTUnwrap(fsync.payload.readSSHBuffer()).readableBytesView), [0xCA, 0xFE])
        XCTAssertNoThrow(try channel.finish())
    }

    func testOpenSSHExtensionsRejectUnadvertisedOrWrongVersionsWithoutSending() throws {
        let (channel, client) = try makeEmbeddedSFTPClient()
        client.setServerExtensions([
            ("hardlink@openssh.com", "2"),
            ("fsync@openssh.com", "0"),
        ])

        do {
            _ = try client.makeHardLinkRequest(at: "/old", to: "/new")
            XCTFail("Wrong hardlink version must be rejected")
        } catch SFTPError.unsupportedExtension(let name) {
            XCTAssertEqual(name, "hardlink@openssh.com")
        }

        let file = SFTPFile(client: client, path: "/old", handle: ByteBuffer(bytes: [1]))
        do {
            _ = try file.makeSynchronizeRequest()
            XCTFail("Wrong fsync version must be rejected")
        } catch SFTPError.unsupportedExtension(let name) {
            XCTAssertEqual(name, "fsync@openssh.com")
        }
        XCTAssertNil(try channel.readOutbound(as: SFTPMessage.self))
        XCTAssertNoThrow(try channel.finish())
    }

    func testExistingHardLinkTargetStatusFailsThePendingRequest() throws {
        let (channel, client) = try makeEmbeddedSFTPClient()
        let requestID: UInt32 = 109
        let response = channel.eventLoop.makePromise(of: SFTPResponse.self)
        client.responses.responses[requestID] = response

        XCTAssertTrue(try channel.writeInbound(SFTPMessage.status(.init(
            requestId: requestID,
            errorCode: .failure,
            message: "File exists",
            languageTag: "en"
        ))).isEmpty)
        XCTAssertThrowsError(try response.futureResult.wait()) { error in
            guard let status = error as? SFTPMessage.Status else {
                return XCTFail("Expected SFTP status, got \(error)")
            }
            XCTAssertEqual(status.errorCode, .failure)
            XCTAssertEqual(status.message, "File exists")
        }
        XCTAssertNoThrow(try channel.finish())
    }

    func testListDirectorySendsCloseAfterReadAndEOF() async throws {
        let (channel, client) = try await makeAsyncTestingSFTPClient()
        let listing = Task { try await client.listDirectory(atPath: "/reports") }
        defer { listing.cancel() }

        let handle = try await openDirectoryForEmbeddedListing(
            on: channel,
            path: "/reports",
            handleBytes: [0x10, 0x20, 0x30]
        )
        let firstRead = try await nextReadDirectoryRequest(
            from: channel,
            expectedHandle: handle
        )
        let nameResponse = try await channel.writeInbound(SFTPMessage.name(.init(
            requestId: firstRead.requestId,
            components: [.init(
                filename: "report.txt",
                longname: "-rw------- report.txt",
                attributes: .init(size: 64)
            )]
        )))
        XCTAssertTrue(nameResponse.isEmpty)

        let terminalRead = try await nextReadDirectoryRequest(
            from: channel,
            expectedHandle: handle
        )
        let eofResponse = try await channel.writeInbound(SFTPMessage.status(.init(
            requestId: terminalRead.requestId,
            errorCode: .eof,
            message: "end of directory",
            languageTag: "en"
        )))
        XCTAssertTrue(eofResponse.isEmpty)
        try await expectAndAcknowledgeDirectoryClose(on: channel, expectedHandle: handle)

        let names = try await listing.value
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names[0].components.map(\.filename), ["report.txt"])
        XCTAssertTrue(client.responses.responses.isEmpty)
        let unexpectedSuccessOutbound = try await channel.readOutbound(as: SFTPMessage.self)
        XCTAssertNil(unexpectedSuccessOutbound)
        let finishState = try await channel.finish()
        XCTAssertTrue(finishState.isClean)
    }

    func testListDirectorySendsCloseWhenReadFailsAndPreservesStatus() async throws {
        let (channel, client) = try await makeAsyncTestingSFTPClient()
        let listing = Task { try await client.listDirectory(atPath: "/restricted") }
        defer { listing.cancel() }

        let handle = try await openDirectoryForEmbeddedListing(
            on: channel,
            path: "/restricted",
            handleBytes: [0xBA, 0xD0]
        )
        let read = try await nextReadDirectoryRequest(from: channel, expectedHandle: handle)
        let failureResponse = try await channel.writeInbound(SFTPMessage.status(.init(
            requestId: read.requestId,
            errorCode: .permissionDenied,
            message: "permission denied",
            languageTag: "en"
        )))
        XCTAssertTrue(failureResponse.isEmpty)
        try await expectAndAcknowledgeDirectoryClose(on: channel, expectedHandle: handle)

        do {
            _ = try await listing.value
            XCTFail("A non-EOF read status must fail the directory listing")
        } catch let status as SFTPMessage.Status {
            XCTAssertEqual(status.errorCode, .permissionDenied)
            XCTAssertEqual(status.message, "permission denied")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(client.responses.responses.isEmpty)
        let unexpectedFailureOutbound = try await channel.readOutbound(as: SFTPMessage.self)
        XCTAssertNil(unexpectedFailureOutbound)
        let finishState = try await channel.finish()
        XCTAssertTrue(finishState.isClean)
    }

    func testListDirectoryRejectsNonEOFTerminalOKAndStillCloses() async throws {
        let (channel, client) = try await makeAsyncTestingSFTPClient()
        let listing = Task { try await client.listDirectory(atPath: "/malformed") }
        defer { listing.cancel() }

        let handle = try await openDirectoryForEmbeddedListing(
            on: channel,
            path: "/malformed",
            handleBytes: [0xFE, 0xED]
        )
        let read = try await nextReadDirectoryRequest(from: channel, expectedHandle: handle)
        let terminalResponse = try await channel.writeInbound(SFTPMessage.status(.init(
            requestId: read.requestId,
            errorCode: .ok,
            message: "not EOF",
            languageTag: "en"
        )))
        XCTAssertTrue(terminalResponse.isEmpty)
        try await expectAndAcknowledgeDirectoryClose(on: channel, expectedHandle: handle)

        do {
            _ = try await listing.value
            XCTFail("SSH_FX_OK is not a valid terminal READDIR status")
        } catch SFTPError.errorStatus(let status) {
            XCTAssertEqual(status.errorCode, .ok)
            XCTAssertEqual(status.message, "not EOF")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(client.responses.responses.isEmpty)
        let unexpectedTerminalOutbound = try await channel.readOutbound(as: SFTPMessage.self)
        XCTAssertNil(unexpectedTerminalOutbound)
        let finishState = try await channel.finish()
        XCTAssertTrue(finishState.isClean)
    }

    func withDisconnectTest(perform: (SSHServer, SSHClient) async throws -> ()) async throws {
        struct AuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
            let password: String
            
            var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
                .password
            }
            
            func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
                switch request.request {
                case .password(.init(password: password)):
                    responsePromise.succeed(.success)
                default:
                    responsePromise.succeed(.failure)
                }
            }
        }
        
        actor CloseHelper {
            var isClosed = false
            
            func close() {
                isClosed = true
            }
        }
        
        let hostKey = NIOSSHPrivateKey(p521Key: .init())
        let password = UUID().uuidString
        
        let server = try await SSHServer.host(
            host: "0.0.0.0",
            port: 2345,
            hostKeys: [
                hostKey
            ],
            authenticationDelegate: AuthDelegate(password: password)
        )
        
        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: 2345,
            authenticationMethod: .passwordBased(
                username: "test",
                password: password
            ),
            hostKeyValidator: .trustedKeys([hostKey.publicKey]),
            reconnect: .never
        )
        
        XCTAssertTrue(client.isConnected, "Client is not active")
        
        let helper = CloseHelper()
        client.onDisconnect {
            Task {
                await helper.close()
            }
        }
        
        // Make an exec call that's not handled
        _ = try? await client.executeCommand("test")
        
        try await perform(server, client)
        
        if #available(macOS 13, *) {
            try await Task.sleep(for: .seconds(1))
        } else {
            sleep(1)
        }
        
        let isClosed = await helper.isClosed
        XCTAssertTrue(isClosed, "Connection did not close")
    }
    
    func testOnDisconnectClient() async throws {
        try await withDisconnectTest { server, client in
            try await client.close()
        }
    }
    
    func testSFTPUpload() async throws {
        enum DelegateError: Error {
            case unsupported
        }
        
        final class TestData: @unchecked /* for testing */ Sendable {
            var allDataSent = ByteBuffer()
        }
        
        struct TestError: Error { }
        
        struct SFTPFile: SFTPFileHandle {
            func readFileAttributes() async throws -> Citadel.SFTPFileAttributes {
                return SFTPFileAttributes(size: .init(testData.allDataSent.readableBytes))
            }
            
            func setFileAttributes(to attributes: Citadel.SFTPFileAttributes) async throws {
                throw DelegateError.unsupported
            }
            
            func read(at offset: UInt64, length: UInt32) async throws -> NIOCore.ByteBuffer {
                throw DelegateError.unsupported
            }
            
            let testData: TestData
            
            func close() async throws -> SFTPStatusCode {
                .ok
            }
            
            func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
                testData.allDataSent.writeImmutableBuffer(data)
                return .ok
            }
        }
        
        struct SFTP: SFTPDelegate {
            func removeFile(_ filePath: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                .permissionDenied
            }
            
            func setFileAttributes(to attributes: Citadel.SFTPFileAttributes, atPath path: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                throw DelegateError.unsupported
            }
            
            func addSymlink(linkPath: String, targetPath: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                throw DelegateError.unsupported
            }

            func rename(oldPath: String, newPath: String, flags: UInt32, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                throw DelegateError.unsupported
            }

            func readSymlink(atPath path: String, context: Citadel.SSHContext) async throws -> [Citadel.SFTPPathComponent] {
                throw DelegateError.unsupported
            }
            
            func realPath(for canonicalUrl: String, context: Citadel.SSHContext) async throws -> [Citadel.SFTPPathComponent] {
                throw TestError()
            }
            
            func openDirectory(atPath path: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPDirectoryHandle {
                throw TestError()
            }
            
            func createDirectory(_ filePath: String, withAttributes: Citadel.SFTPFileAttributes, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                .permissionDenied
            }
            
            func removeDirectory(_ filePath: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPStatusCode {
                .permissionDenied
            }
            
            let testData: TestData
            
            func fileAttributes(atPath path: String, context: Citadel.SSHContext) async throws -> Citadel.SFTPFileAttributes {
                .all
            }
            
            func openFile(_ filePath: String, withAttributes: Citadel.SFTPFileAttributes, flags: Citadel.SFTPOpenFileFlags, context: Citadel.SSHContext) async throws -> Citadel.SFTPFileHandle {
                SFTPFile(testData: testData)
            }
        }
        
        struct AuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
            let supportedKey: NIOSSHPublicKey
            
            let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey]
            
            func requestReceived(request: NIOSSH.NIOSSHUserAuthenticationRequest, responsePromise: NIOCore.EventLoopPromise<NIOSSH.NIOSSHUserAuthenticationOutcome>) {
                switch request.request {
                case .hostBased, .none, .password:
                    return responsePromise.succeed(.failure)
                case .publicKey(let key):
                    guard key.publicKey == supportedKey else {
                        return responsePromise.succeed(.failure)
                    }
                    
                    responsePromise.succeed(.success)
                }
            }
        }
        
        let clientKey = P521.Signing.PrivateKey()
        let clientPrivateKey = NIOSSHPrivateKey(p521Key: clientKey)
        let clientPublicKey = clientPrivateKey.publicKey
        let server = try await SSHServer.host(
            host: "0.0.0.0",
            port: 2222,
            hostKeys: [
                .init(p521Key: P521.Signing.PrivateKey())
            ],
            authenticationDelegate: AuthDelegate(supportedKey: clientPublicKey)
        )
        
        let testData = TestData()
        server.enableSFTP(withDelegate: SFTP(testData: testData))
        
        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: 2222,
            authenticationMethod: SSHAuthenticationMethod.p521(
                username: "Joannis",
                privateKey: clientKey
            ),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile(filePath: "/kaas", flags: [.create, .write])
        
        let start: UInt8 = 0x00
        let end: UInt8 = 0x05
        
        for i in start ..< end {
            try await file.write(ByteBuffer(repeating: i, count: 1000))
        }
        
        try await file.close()
        
        for i in start ..< end {
            guard testData.allDataSent.readBytes(length: 1000) == .init(repeating: i, count: 1000) else {
                return XCTFail()
            }
        }
        
        try await client.close()
        try await server.close()
    }
    
    func testRebex() async throws {
        let client = try await SSHClient.connect(
            host: "test.rebex.net",
            authenticationMethod: .passwordBased(username: "demo", password: "password"),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        
        let sftp = try await client.openSFTP()
        
        let file = try await sftp.openFile(filePath: "/readme.txt", flags: .read)
        var i = 0
        for _ in 0..<10 {
            _ = try await file.read(from: UInt64(i * 32_768), length: 32_768)
            i += 1
        }
        try await file.close()
    }

    func testConnectToOpenSSHServer() async throws {
        guard
            let host = ProcessInfo.processInfo.environment["SSH_HOST"],
            let _port = ProcessInfo.processInfo.environment["SSH_PORT"],
            let port = Int(_port),
            let username = ProcessInfo.processInfo.environment["SSH_USERNAME"],
            let password = ProcessInfo.processInfo.environment["SSH_PASSWORD"]
        else {
            throw XCTSkip()
        }

        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        let output = try await client.executeCommand("ls /")
        XCTAssertFalse(String(buffer: output).isEmpty)

        try await client.close()
    }

    @available(macOS 15.0, *)
    func testStdinStream() async throws {
        guard
            let host = ProcessInfo.processInfo.environment["SSH_HOST"],
            let _port = ProcessInfo.processInfo.environment["SSH_PORT"],
            let port = Int(_port),
            let username = ProcessInfo.processInfo.environment["SSH_USERNAME"],
            let password = ProcessInfo.processInfo.environment["SSH_PASSWORD"]
        else {
            throw XCTSkip()
        }

        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        try await client.withTTY { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "cat"))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var a = UInt8(ascii: "a")
                    for try await value in inbound {
                        switch value {
                        case .stdout(let value):
                            for byte in value.readableBytesView {
                                XCTAssertEqual(byte, a)
                                a = a &+ 1
                            }
                        case .stderr(let value):
                            XCTFail("Unexpected stderr: \(String(buffer: value))")
                        }
                    }
                }

                group.addTask {
                    for i: UInt8 in UInt8(ascii: "a") ... UInt8(ascii: "z") {
                        let value = ByteBufferAllocator().buffer(integer: i)
                        try await outbound.write(value)
                    }
                }

                try await group.next()
                group.cancelAll()
            }
        }

        try await client.close()
    }
}
