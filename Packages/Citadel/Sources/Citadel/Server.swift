import NIO
import Logging
@preconcurrency import NIOSSH
import NIOConcurrencyHelpers

final class CloseErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("SSH Server Error: \(error)")
        context.close(promise: nil)
    }
}

final class SubsystemHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    private struct State {
        var isConfigured = false
        var pendingReads = [SSHChannelData]()
    }

    let shell: ShellDelegate?
    let sftp: SFTPDelegate?
    let eventLoop: EventLoop
    private let state: NIOLoopBoundBox<State>
    
    init(sftp: SFTPDelegate?, shell: ShellDelegate?, eventLoop: EventLoop) {
        self.sftp = sftp
        self.shell = shell
        self.eventLoop = eventLoop
        self.state = NIOLoopBoundBox(State(), eventLoop: eventLoop)
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            channel.pipeline.fireErrorCaught(error)
        }
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        configurationSucceeded(channel: context.channel)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let channel = context.channel
        switch event {
        case let event as SSHChannelRequestEvent.ExecRequest:
            context.fireUserInboundEventTriggered(event)
        case is SSHChannelRequestEvent.ShellRequest:
            guard let shell = shell, let parent = channel.parent else {
                _ = channel.triggerUserOutboundEvent(ChannelFailureEvent()).flatMap {
                    self.configurationSucceeded(channel: channel)
                    return channel.close()
                }
                return
            }

            let setup: EventLoopFuture<Void>
            do {
                let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                setup = ShellServerSubsystem.setupChannelHanders(
                    channel: channel,
                    shell: shell,
                    logger: .init(label: "nl.orlandos.citadel.sftp-server"),
                    username: handler.username
                )
            } catch {
                setup = channel.eventLoop.makeFailedFuture(error)
            }
            setup.flatMap { () -> EventLoopFuture<Void> in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: promise)
                self.configurationSucceeded(channel: channel)
                return promise.futureResult
            }.whenFailure { _ in
                channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        case let event as SSHChannelRequestEvent.SubsystemRequest:
            switch event.subsystem {
            case "sftp":
                guard let sftp = sftp, let parent = channel.parent else {
                    channel.close(promise: nil)
                    configurationSucceeded(channel: channel)
                    return
                }

                let setup: EventLoopFuture<Void>
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    setup = SFTPServerSubsystem.setupChannelHanders(
                        channel: channel,
                        sftp: sftp,
                        logger: .init(label: "nl.orlandos.citadel.sftp-server"),
                        username: handler.username
                    )
                } catch {
                    setup = channel.eventLoop.makeFailedFuture(error)
                }
                setup.flatMap { () -> EventLoopFuture<Void> in
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: promise)
                    self.configurationSucceeded(channel: channel)
                    return promise.futureResult
                }.whenFailure { _ in
                    channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
            default:
                context.fireUserInboundEventTriggered(event)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        if state.value.isConfigured {
            context.fireChannelRead(wrapInboundOut(channelData))
        } else {
            state.value.pendingReads.append(channelData)
        }
    }

    private func configurationSucceeded(channel: Channel) {
        guard !state.value.isConfigured else { return }
        state.value.isConfigured = true
        let pendingReads = state.value.pendingReads
        state.value.pendingReads.removeAll(keepingCapacity: false)
        for data in pendingReads {
            channel.pipeline.fireChannelRead(data)
        }
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}

final class CitadelServerDelegate: Sendable, GlobalRequestDelegate {
    let _sftp = NIOLockedValueBox<SFTPDelegate?>(nil)
    let _exec = NIOLockedValueBox<ExecDelegate?>(nil)
    let _shell = NIOLockedValueBox<ShellDelegate?>(nil)
    let _directTCPIP = NIOLockedValueBox<DirectTCPIPDelegate?>(nil)
    let _remotePortForward = NIOLockedValueBox<RemotePortForwardDelegate?>(nil)

    var sftp: SFTPDelegate? {
        get { _sftp.withLockedValue { $0 } }
        set { _sftp.withLockedValue { $0 = newValue } }
    }
    var exec: ExecDelegate? {
        get { _exec.withLockedValue { $0 } }
        set { _exec.withLockedValue { $0 = newValue } }
    }
    var shell: ShellDelegate? {
        get { _shell.withLockedValue { $0 } }
        set { _shell.withLockedValue { $0 = newValue } }
    }
    var directTCPIP: DirectTCPIPDelegate? {
        get { _directTCPIP.withLockedValue { $0 } }
        set { _directTCPIP.withLockedValue { $0 = newValue } }
    }
    var remotePortForward: RemotePortForwardDelegate? {
        get { _remotePortForward.withLockedValue { $0 } }
        set { _remotePortForward.withLockedValue { $0 = newValue } }
    }

    public func initializeSshChildChannel(_ channel: Channel, _ channelType: SSHChannelType, username: String?) -> NIOCore.EventLoopFuture<Void> {
        switch channelType {
        case .session:
            var handlers = [ChannelHandler]()
            
            handlers.append(SubsystemHandler(
                sftp: self.sftp,
                shell: self.shell,
                eventLoop: channel.eventLoop
            ))
            
            handlers.append(ExecHandler(delegate: exec, username: username))
            
            do {
                try channel.pipeline.syncOperations.addHandlers(handlers)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        case .directTCPIP(let request):
            guard let delegate = directTCPIP else {
                return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
            }

            do {
                try channel.pipeline.syncOperations.addHandler(DataToBufferCodec())
                return delegate.initializeDirectTCPIPChannel(
                    channel,
                    request: request,
                    context: SSHContext(username: username)
                )
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        case .forwardedTCPIP:
            return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
        }
    }

    func tcpForwardingRequest(
        _ request: GlobalRequest.TCPForwardingRequest,
        handler: NIOSSHHandler,
        promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>
    ) {
        guard let delegate = remotePortForward else {
            promise.fail(CitadelError.unsupported)
            return
        }

        let context = SSHContext(username: handler.username)

        switch request {
        case .listen(let host, let port):
            delegate.startListening(
                host: host,
                port: port,
                handler: handler,
                eventLoop: promise.futureResult.eventLoop,
                context: context
            ).whenComplete { result in
                switch result {
                case .success(let boundPort):
                    if let boundPort = boundPort {
                        promise.succeed(GlobalRequest.TCPForwardingResponse(boundPort: boundPort))
                    } else {
                        promise.fail(CitadelError.unsupported)
                    }
                case .failure(let error):
                    promise.fail(error)
                }
            }

        case .cancel(let host, let port):
            delegate.stopListening(
                host: host,
                port: port,
                eventLoop: promise.futureResult.eventLoop,
                context: context
            ).whenComplete { result in
                switch result {
                case .success:
                    promise.succeed(GlobalRequest.TCPForwardingResponse(boundPort: nil))
                case .failure(let error):
                    promise.fail(error)
                }
            }
        }
    }
}

/// An SSH Server implementation.
/// This class is used to start an SSH server on a specified host and port.
/// The server can be closed using the `close()` method.
public final class SSHServer: Sendable {
    let channel: Channel
    let delegate: CitadelServerDelegate
    let logger: Logger
    public var closeFuture: EventLoopFuture<Void> {
        channel.closeFuture
    }
    
    init(channel: Channel, logger: Logger, delegate: CitadelServerDelegate) {
        self.channel = channel
        self.logger = logger
        self.delegate = delegate
    }

    
    /// Enables SFTP for SSH session targetting this SSH Server. 
    /// Once SFTP is enabled, the SSH session can be used to send and receive files.
    /// - Parameter delegate: The delegate object that will handle SFTP events.
    /// - Note: SFTP is disabled by default.
    public func enableSFTP(withDelegate delegate: SFTPDelegate) {
        self.delegate.sftp = delegate
    }
    
    /// Enables Exec for SSH session targetting this SSH Server.
    /// Once Exec is enabled, the SSH session can be used to execute commands.
    /// - Note: Exec is disabled by default.
    public func enableExec(withDelegate delegate: ExecDelegate) {
        self.delegate.exec = delegate
    }

    public func enableDirectTCPIP(withDelegate delegate: DirectTCPIPDelegate) {
        self.delegate.directTCPIP = delegate
    }
    
    public func enableShell(withDelegate delegate: ShellDelegate) {
        self.delegate.shell = delegate
    }

    /// Enables remote port forwarding for SSH sessions targeting this SSH Server.
    /// Once enabled, clients can request the server to listen on ports and forward connections.
    /// - Parameter delegate: The delegate object that will handle port forwarding requests.
    /// - Note: Remote port forwarding is disabled by default.
    public func enableRemotePortForward(withDelegate delegate: RemotePortForwardDelegate) {
        self.delegate.remotePortForward = delegate
    }

    /// Closes the SSH Server, stopping new connections from coming in.
    public func close() async throws {
        try await channel.close()
    }
    
    /// Starts a new SSH Server on the specified host and port.
    public static func host(
        host: String,
        port: Int,
        hostKeys: [NIOSSHPrivateKey],
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        logger: Logger = Logger(label: "nl.orlandos.citadel.server"),
        authenticationDelegate: NIOSSHServerUserAuthenticationDelegate & Sendable,
        group: MultiThreadedEventLoopGroup = .init(numberOfThreads: 1)
    ) async throws -> SSHServer {
        let delegate = CitadelServerDelegate()
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                var server = SSHServerConfiguration(
                    hostKeys: hostKeys,
                    userAuthDelegate: authenticationDelegate,
                    globalRequestDelegate: delegate
                )
                
                algorithms.apply(to: &server)
                
                logger.debug("New session being instantiated over TCP")
                
                for option in protocolOptions {
                    option.apply(to: &server)
                }
                
                do {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                        role: .server(server),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { childChannel, channelType in
                            channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler in
                                delegate.initializeSshChildChannel(childChannel, channelType, username: handler.username)
                            }
                        }
                        ),
                        CloseErrorHandler(logger: logger)
                    ])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        return try await bootstrap.bind(host: host, port: port).map { channel in
            SSHServer(channel: channel, logger: logger, delegate: delegate)
        }.get()
    }
}

/// A set of options that can be applied to the SSH protocol.
public struct SSHProtocolOption: Hashable, Sendable {
    internal enum Value: Hashable {
        case maximumPacketSize(Int)
    }
    
    internal let value: Value
    
    /// The maximum packet size that can be sent over the SSH connection.
    public static func maximumPacketSize(_ size: Int) -> Self {
        return .init(value: .maximumPacketSize(size))
    }
    
    func apply(to client: inout SSHClientConfiguration) {
        switch value {
        case .maximumPacketSize(let size):
            client.maximumPacketSize = size
        }
    }
    
    func apply(to server: inout SSHServerConfiguration) {
        switch value {
        case .maximumPacketSize(let size):
            server.maximumPacketSize = size
        }
    }
}
