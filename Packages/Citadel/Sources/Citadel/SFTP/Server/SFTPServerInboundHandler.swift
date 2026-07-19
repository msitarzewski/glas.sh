import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH
import Logging

struct SFTPDirectoryHandleIterator: Sendable {
    var listing = [SFTPFileListing]()
}

final class SFTPServerInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SFTPMessage

    private struct State: Sendable {
        var currentHandleID: UInt32 = 0
        var files = [UInt32: SFTPFileHandle]()
        var directories = [UInt32: SFTPDirectoryHandle]()
        var directoryListing = [UInt32: SFTPDirectoryHandleIterator]()
        var previousTask: EventLoopFuture<Void>
    }
    
    let logger: Logger
    let delegate: SFTPDelegate
    let initialized: EventLoopPromise<Void>
    private let state: NIOLockedValueBox<State>
    let username: String?

    private var currentHandleID: UInt32 {
        get { state.withLockedValue(\.currentHandleID) }
        set { state.withLockedValue { $0.currentHandleID = newValue } }
    }

    private var files: [UInt32: SFTPFileHandle] {
        get { state.withLockedValue(\.files) }
        set { state.withLockedValue { $0.files = newValue } }
    }

    private var directories: [UInt32: SFTPDirectoryHandle] {
        get { state.withLockedValue(\.directories) }
        set { state.withLockedValue { $0.directories = newValue } }
    }

    private var directoryListing: [UInt32: SFTPDirectoryHandleIterator] {
        get { state.withLockedValue(\.directoryListing) }
        set { state.withLockedValue { $0.directoryListing = newValue } }
    }

    private var previousTask: EventLoopFuture<Void> {
        get { state.withLockedValue(\.previousTask) }
        set { state.withLockedValue { $0.previousTask = newValue } }
    }
    
    init(logger: Logger, delegate: SFTPDelegate, eventLoop: EventLoop, username: String?) {
        self.logger = logger
        self.delegate = delegate
        self.initialized = eventLoop.makePromise()
        self.state = NIOLockedValueBox(State(previousTask: eventLoop.makeSucceededVoidFuture()))
        self.username = username
    }
    
    func initialize(command: SFTPMessage.Initialize, channel: Channel) {
        guard command.version >= .v3 else {
            initialized.fail(SFTPError.connectionClosed)
            return channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                channel.close(promise: nil)
            }
        }

        channel.writeAndFlush(
            SFTPMessage.version(
                .init(
                    version: .v3,
                    extensionData: []
                )
            ),
            promise: nil
        )
        initialized.succeed(())
    }
    
    func makeContext() -> SSHContext {
        SSHContext(username: self.username)
    }
    
    func openFile(command: SFTPMessage.OpenFile, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPFileHandle.self)
        promise.completeWithTask {
            try await self.delegate.openFile(
                command.filePath,
                withAttributes: command.attributes,
                flags: command.pFlags,
                context: self.makeContext()
            )
        }
        
        _ = promise.futureResult.map { file -> SFTPMessage in
            let handle = self.currentHandleID
            self.files[handle] = file
            self.currentHandleID &+= 1
            
            return SFTPMessage.handle(
                SFTPMessage.Handle(
                    requestId: command.requestId,
                    handle: ByteBuffer(integer: handle, endianness: .big)
                )
            )
        }.flatMap { handle in
            channel.writeAndFlush(handle)
        }
    }
    
    func closeFile(command: SFTPMessage.CloseFile, channel: Channel) {
        guard let id: UInt32 = command.handle.getInteger(at: 0) else {
            logger.error("bad SFTP file handle")
            return
        }
        
        if let file = files[id] {
            previousTask = previousTask.flatMap {
                let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
                promise.completeWithTask {
                    try await file.close()
                }
                self.files[id] = nil
                return promise.futureResult.flatMap { status in
                    channel.writeAndFlush(
                        SFTPMessage.status(
                            SFTPMessage.Status(
                                requestId: command.requestId,
                                errorCode: status,
                                message: "uploaded",
                                languageTag: "EN"
                            )
                        )
                    )
                }.flatMapError { _ in
                    channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                        channel.close()
                    }
                }
            }
        } else if directories[id] != nil {
            directories[id] = nil
            directoryListing[id] = nil
            
            previousTask = previousTask.flatMap {
                channel.writeAndFlush(
                    SFTPMessage.status(
                        SFTPMessage.Status(
                            requestId: command.requestId,
                            errorCode: .ok,
                            message: "closed",
                            languageTag: "EN"
                        )
                    )
                )
            }
        } else {
            logger.error("unknown SFTP handle")
        }
    }
    
    func readFile(command: SFTPMessage.ReadFile, channel: Channel) {
        previousTask = previousTask.flatMap {
            self.withFileHandle(command.handle, channel: channel) { file -> ByteBuffer in
                try await file.read(at: command.offset, length: command.length)
            }.flatMap { data -> EventLoopFuture<Void> in
                if data.readableBytes == 0 {
                    return channel.writeAndFlush(
                        SFTPMessage.status(
                            .init(
                                requestId: command.requestId,
                                errorCode: .eof,
                                message: "EOF",
                                languageTag: "EN"
                            )
                        )
                    )
                } else {
                    return channel.writeAndFlush(
                        SFTPMessage.data(
                            SFTPMessage.FileData(
                                requestId: command.requestId,
                                data: data
                            )
                        )
                    )
                }
            }.flatMapError { _ in
                channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                    channel.close()
                }
            }
        }
    }
    
    func writeFile(command: SFTPMessage.WriteFile, channel: Channel) {
        previousTask = previousTask.flatMap {
            self.withFileHandle(command.handle, channel: channel) { file -> SFTPStatusCode in
                try await file.write(command.data, atOffset: command.offset)
            }.flatMap { status -> EventLoopFuture<Void> in
                channel.writeAndFlush(
                    SFTPMessage.status(
                        SFTPMessage.Status(
                            requestId: command.requestId,
                            errorCode: status,
                            message: "",
                            languageTag: "EN"
                        )
                    )
                )
            }.flatMapError { _ in
                channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                    channel.close()
                }
            }
        }
    }
    
    func createDir(command: SFTPMessage.MkDir, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.createDirectory(
                command.filePath,
                withAttributes: command.attributes,
                context: self.makeContext()
            )
        }
        
        _ = promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapError { _ in
            channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                channel.close()
            }
        }
    }
    
    func removeDir(command: SFTPMessage.RmDir, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.removeDirectory(
                command.filePath,
                context: self.makeContext()
            )
        }
        
        _ =  promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapError { _ in
            channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                channel.close()
            }
        }
    }
    
    func stat(command: SFTPMessage.Stat, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPFileAttributes.self)
        promise.completeWithTask {
            try await self.delegate.fileAttributes(atPath: command.path, context: self.makeContext())
        }
        
        _ = promise.futureResult.flatMap { attributes -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.attributes(
                    .init(
                        requestId: command.requestId,
                        attributes: attributes
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }
    
    func lstat(command: SFTPMessage.LStat, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPFileAttributes.self)
        promise.completeWithTask {
            try await self.delegate.fileAttributes(atPath: command.path, context: self.makeContext())
        }
        
        _ = promise.futureResult.flatMap { attributes -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.attributes(
                    .init(
                        requestId: command.requestId,
                        attributes: attributes
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }
    
    func realPath(command: SFTPMessage.RealPath, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: [SFTPPathComponent].self)
        promise.completeWithTask {
            try await self.delegate.realPath(for: command.path, context: self.makeContext())
        }
        
        _ = promise.futureResult.flatMap { components -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.name(
                    .init(
                        requestId: command.requestId,
                        components: components
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }
    
    func openDir(command: SFTPMessage.OpenDir, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: (SFTPDirectoryHandle, SFTPDirectoryHandleIterator).self)
        promise.completeWithTask {
            let handle = try await self.delegate.openDirectory(atPath: command.handle, context: self.makeContext())
            let files = try await handle.listFiles(context: self.makeContext())
            let iterator = SFTPDirectoryHandleIterator(listing: files)
            return (handle, iterator)
        }
        
    _ = promise.futureResult.map { (directory, listing) -> SFTPMessage in
            let handle = self.currentHandleID
            self.directories[handle] = directory
            self.directoryListing[handle] = listing
            self.currentHandleID &+= 1
            
            return SFTPMessage.handle(
                SFTPMessage.Handle(
                    requestId: command.requestId,
                    handle: ByteBuffer(integer: handle, endianness: .big)
                )
            )
        }.flatMap { handle in
            channel.writeAndFlush(handle)
        }.flatMapErrorThrowing { _ in }
    }
    
    func readDir(command: SFTPMessage.ReadDir, channel: Channel) {
        guard
            let id: UInt32 = command.handle.getInteger(at: 0),
            var listing = directoryListing[id]
        else {
            logger.error("bad SFTP directory handle")
            return
        }
        
        let result: EventLoopFuture<Void>
        if listing.listing.isEmpty {
            self.directoryListing[id] = nil
            result = channel.writeAndFlush(SFTPMessage.status(
                SFTPMessage.Status(
                    requestId: command.requestId,
                    errorCode: .eof,
                    message: "",
                    languageTag: "EN"
                )
            ))
        } else {
            let file = listing.listing.removeFirst()
            result = channel.writeAndFlush(SFTPMessage.name(
                .init(
                    requestId: command.requestId,
                    components: file.path
                )
            ))
        }
        
        self.directoryListing[id] = listing
        _ = result.flatMapError { error -> EventLoopFuture<Void> in
            self.logger.error("\(error)")
            return channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: .failure,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }
    }
    
    func fileStat(command: SFTPMessage.FileStat, channel: Channel) {
        _ = self.withFileHandle(command.handle, channel: channel) { file in
            try await file.readFileAttributes()
        }.flatMap { attributes -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.attributes(
                    .init(
                        requestId: command.requestId,
                        attributes: attributes
                    )
                )
            )
        }.flatMapError { _ -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: .failure,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }
    }
    
    func removeFile(command: SFTPMessage.Remove, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.removeFile(command.filename, context: self.makeContext())
        }
        _ = promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }
    
    func fileSetStat(command: SFTPMessage.FileSetStat, channel: Channel) {
        _ = self.withFileHandle(command.handle, channel: channel) { handle in
            try await handle.setFileAttributes(to: command.attributes)
        }.flatMap { () -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: .ok,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapError { _ -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: .failure,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }
    }
    
    func setStat(command: SFTPMessage.SetStat, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.setFileAttributes(
                to: command.attributes,
                atPath: command.path,
                context: self.makeContext()
            )
        }
        _ = promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }
    
    func symlink(command: SFTPMessage.Symlink, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.addSymlink(
                linkPath: command.linkPath,
                targetPath: command.targetPath,
                context: self.makeContext()
            )
        }
        _ = promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }

    func rename(command: SFTPMessage.Rename, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: SFTPStatusCode.self)
        promise.completeWithTask {
            try await self.delegate.rename(
                oldPath: command.oldPath,
                newPath: command.newPath,
                flags: command.flags,
                context: self.makeContext()
            )
        }
        _ = promise.futureResult.flatMap { status -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: status,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }.flatMapErrorThrowing { _ in }
    }

    func readlink(command: SFTPMessage.Readlink, channel: Channel) {
        let promise = channel.eventLoop.makePromise(of: [SFTPPathComponent].self)
        promise.completeWithTask {
            try await self.delegate.readSymlink(
                atPath: command.path,
                context: self.makeContext()
            )
        }
        _ = promise.futureResult.flatMap { components -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.name(
                    SFTPMessage.Name(
                        requestId: command.requestId,
                        components: components
                    )
                )
            )
        }.flatMapError { _ -> EventLoopFuture<Void> in
            channel.writeAndFlush(
                SFTPMessage.status(
                    SFTPMessage.Status(
                        requestId: command.requestId,
                        errorCode: .failure,
                        message: "",
                        languageTag: "EN"
                    )
                )
            )
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = context.channel
        switch unwrapInboundIn(data) {
        case .initialize(let command):
            initialize(command: command, channel: channel)
        case .openFile(let command):
            openFile(command: command, channel: channel)
        case .closeFile(let command):
            closeFile(command: command, channel: channel)
        case .read(let command):
            readFile(command: command, channel: channel)
        case .write(let command):
            writeFile(command: command, channel: channel)
        case .mkdir(let command):
            createDir(command: command, channel: channel)
        case .opendir(let command):
            openDir(command: command, channel: channel)
        case .rmdir(let command):
            removeDir(command: command, channel: channel)
        case .stat(let command):
            stat(command: command, channel: channel)
        case .lstat(let command):
            lstat(command: command, channel: channel)
        case .realpath(let command):
            realPath(command: command, channel: channel)
        case .readdir(let command):
            readDir(command: command, channel: channel)
        case .fstat(let command):
            fileStat(command: command, channel: channel)
        case .remove(let command):
            removeFile(command: command, channel: channel)
        case .fsetstat(let command):
            fileSetStat(command: command, channel: channel)
        case .setstat(let command):
            setStat(command: command, channel: channel)
        case .symlink(let command):
            symlink(command: command, channel: channel)
        case .readlink(let command):
            readlink(command: command, channel: channel)
        case .rename(let command):
            rename(command: command, channel: channel)
        case .extended(let command):
            context.writeAndFlush(
                NIOAny(SFTPMessage.status(.init(
                    requestId: command.requestId,
                    errorCode: .unsupportedOperation,
                    message: "Unsupported SFTP extension",
                    languageTag: "EN"
                ))),
                promise: nil
            )
        case .version, .handle, .status, .data, .attributes, .name:
            // Client cannot send these messages
            channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
    
    func withFileHandle<T: Sendable>(_ handle: ByteBuffer, channel: Channel, perform: @Sendable @escaping (SFTPFileHandle) async throws -> T) -> EventLoopFuture<T> {
        guard
            let id: UInt32 = handle.getInteger(at: 0),
            let file = files[id]
        else {
            logger.error("bad SFTP file handle")
            return channel.eventLoop.makeFailedFuture(SFTPError.fileHandleInvalid)
        }
        
        let promise = channel.eventLoop.makePromise(of: T.self)
        promise.completeWithTask {
            try await perform(file)
        }
        return promise.futureResult
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            context.channel.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    deinit {
        initialized.fail(SFTPError.connectionClosed)
    }
}
