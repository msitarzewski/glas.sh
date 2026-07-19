import NIO
import Crypto
import Logging
import NIOSSH
import NIOConcurrencyHelpers

extension SSHAlgorithms.Modification<NIOSSHTransportProtection.Type> {
    func apply(to configuration: inout [any NIOSSHTransportProtection.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)
            
            for algorithm: any NIOSSHTransportProtection.Type in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type> {
    func apply(to configuration: inout [any NIOSSHKeyExchangeAlgorithmProtocol.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms
            
            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>{
    func register() {
        switch self {
        case .add(let algorithms):
            for (publicKey, signature) in algorithms {
                NIOSSHAlgorithms.register(publicKey: publicKey, signature: signature)
            }
        case .replace(with: let algorithms):
            for (publicKey, signature) in algorithms {
                NIOSSHAlgorithms.register(publicKey: publicKey, signature: signature)
            }
        }
    }
}

// NIOSSH exposes algorithm metatypes without Sendable annotations. Metatypes are
// immutable process-wide identities, so this container is safe to transfer even
// though the upstream protocol declarations have not adopted Sendable yet.
public struct SSHAlgorithms: @unchecked Sendable {
    /// Represents a modification to a list of items.
    ///
    /// - replace: Replaces the existing list of items with the given list of items.
    /// - add: Adds the given list of items to the list of items.
    public enum Modification<T>: @unchecked Sendable {
        case replace(with: [T])
        case add([T])
    }
    
    /// The enabled TransportProtectionSchemes.
    public var transportProtectionSchemes: Modification<NIOSSHTransportProtection.Type>?
    
    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type>?

    public var publicKeyAlgorihtms: Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>?

    func apply(to clientConfiguration: inout SSHClientConfiguration) {
        transportProtectionSchemes?.apply(to: &clientConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &clientConfiguration.keyExchangeAlgorithms)
        publicKeyAlgorihtms?.register()
    }
    
    func apply(to serverConfiguration: inout SSHServerConfiguration) {
        transportProtectionSchemes?.apply(to: &serverConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &serverConfiguration.keyExchangeAlgorithms)
        publicKeyAlgorihtms?.register()
    }
    
    public init() {}

    public static let all: SSHAlgorithms = {
        var algorithms = SSHAlgorithms()

        algorithms.transportProtectionSchemes = .add([
            AES128CTR.self
        ])

        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha1.self,
            DiffieHellmanGroup14Sha256.self
        ])

        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self),
        ])

        return algorithms
    }()
}

/// Represents an SSH connection.
public final class SSHClient: Sendable {
    private struct State: Sendable {
        var session: SSHClientSession
        var userInitiatedClose = false
        var reconnect = _SSHReconnectMode.never
        var onDisconnect: (@Sendable () -> Void)?
        var reconnectTask: Task<Void, Never>?
    }

    private let state: NIOLockedValueBox<State>
    private(set) var session: SSHClientSession {
        get { state.withLockedValue(\.session) }
        set { state.withLockedValue { $0.session = newValue } }
    }
    let authenticationMethod: @Sendable () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    private let algorithms: SSHAlgorithms
    private let protocolOptions: Set<SSHProtocolOption>
    public let logger = Logger(label: "nl.orlandos.citadel.client")
    public var isConnected: Bool {
        session.channel.isActive
    }
    
    /// The event loop that this SSH connection is running on.
    public var eventLoop: EventLoop {
        session.channel.eventLoop
    }
    
    init(
        session: SSHClientSession,
        authenticationMethod: @escaping @Sendable @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption>
    ) {
        self.state = NIOLockedValueBox(State(session: session))
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.algorithms = algorithms
        self.protocolOptions = protocolOptions
        
        onNewSession(session)
    }
    
    public func onDisconnect(perform onDisconnect: @escaping @Sendable () -> ()) {
        state.withLockedValue { $0.onDisconnect = onDisconnect }
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        to settings: SSHClientSettings
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(settings: settings)
        
        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        settings: SSHClientSettings
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            inboundChannelHandler: inboundChannelHandler,
            settings: settings
        ).get()
        
        let session = try await SSHClientSession.established(
            on: channel,
            inboundChannelHandler: inboundChannelHandler
        )

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    public func jump(to settings: SSHClientSettings) async throws -> SSHClient {
        let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        let channel = try await self.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: settings.host,
                targetPort: settings.port,
                originatorAddress: originatorAddress
            )
        ) { channel in
            SSHClientSession.addHandlers(
                on: channel,
                inboundChannelHandler: inboundChannelHandler,
                settings: settings
            )
        }
        
        let session = try await SSHClientSession.established(
            on: channel,
            inboundChannelHandler: inboundChannelHandler
        )

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    ///  - channel: The channel to use for the connection.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        authenticationMethod: @escaping @Sendable @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            authenticationMethod: authenticationMethod(),
            inboundChannelHandler: inboundChannelHandler,
            hostKeyValidator: hostKeyValidator,
            protocolOptions: protocolOptions
        ).get()
        
        let session = try await SSHClientSession.established(
            on: channel,
            inboundChannelHandler: inboundChannelHandler,
            awaitingHandshake: false
        )
        
        return SSHClient(
            session: session,
            authenticationMethod: authenticationMethod(),
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    /// - host: The host to connect to.
    /// - port: The port to connect to. Defaults to 22.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - reconnect: The reconnect mode to use. See `SSHReconnectMode` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - group: The event loop group to use. Defaults to a single-threaded event loop group.
    /// - channelHandlers: Pass in an array of channel prehandlers that execute first. Default empty array
    /// - connectTimeout: Pass in the time before the connection times out. Default 30 seconds.
    /// - Returns: An SSH client.
    public static func connect(
        host: String,
        port: Int = 22,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        reconnect: SSHReconnectMode,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        group: MultiThreadedEventLoopGroup = .singleton,
        channelHandlers: [ChannelHandler & Sendable] = [],
        connectTimeout:TimeAmount = .seconds(30)
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions,
            group: group,
            channelHandlers: channelHandlers,
            connectTimeout: connectTimeout
        )
        
        let client = SSHClient(
            session: session,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
        
        switch reconnect.mode {
        case .always:
            client.state.withLockedValue { $0.reconnect = .always(to: host, port: port) }
        case .once:
            client.state.withLockedValue { $0.reconnect = .once(to: host, port: port) }
        case .never:
            client.state.withLockedValue { $0.reconnect = .never }
        }
        
        return client
    }
    
    private func onNewSession(_ session: SSHClientSession) {
        session.channel.closeFuture.whenComplete { [weak self] _ in
            self?.onClose()
        }
    }
    
    private func onClose() {
        let reconnectTask = Task { [weak self] in
            guard let self else { return }
            let state = self.state.withLockedValue {
                ($0.onDisconnect, $0.reconnect.mode, $0.userInitiatedClose)
            }
            state.0?()
            guard !state.2, !Task.isCancelled else { return }

            switch state.1 {
            case .never:
                return
            case .once(let host, let port):
                _ = try? await self.recreateSession(host: host, port: port)
            case .always(let host, let port):
                var retryDelayMilliseconds: Int64 = 250
                while !Task.isCancelled {
                    do {
                        try await self.recreateSession(host: host, port: port)
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        let jitter = Int64.random(
                            in: 0...max(1, retryDelayMilliseconds / 4)
                        )
                        do {
                            try await Task.sleep(
                                for: .milliseconds(retryDelayMilliseconds + jitter)
                            )
                        } catch {
                            return
                        }
                        retryDelayMilliseconds = min(
                            retryDelayMilliseconds * 2,
                            30_000
                        )
                    }
                }
            }
        }
        let previousTask = self.state.withLockedValue { state in
            let previousTask = state.reconnectTask
            state.reconnectTask = reconnectTask
            return previousTask
        }
        previousTask?.cancel()
    }
    
    private func recreateSession(host: String, port: Int) async throws {
        try Task.checkCancellation()
        if state.withLockedValue(\.userInitiatedClose) {
            return
        }

        let newSession = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: self.authenticationMethod(),
            hostKeyValidator: self.hostKeyValidator,
            protocolOptions: protocolOptions,
            group: session.channel.eventLoop
        )

        guard !Task.isCancelled,
              !state.withLockedValue(\.userInitiatedClose) else {
            try? await newSession.channel.close()
            try Task.checkCancellation()
            return
        }

        self.session = newSession
        onNewSession(newSession)
    }
    
    /// Sends a keepalive@openssh.com global request to keep the connection alive.
    public func sendKeepAlive() async throws {
        let session = self.session
        guard session.channel.isActive else { return }
        try await session.channel.eventLoop.submit { [sshHandler = session.sshHandler] in
            sshHandler.value.sendKeepAlive()
        }.get()
    }

    public func close() async throws {
        let (session, reconnectTask) = state.withLockedValue { state in
            state.userInitiatedClose = true
            let reconnectTask = state.reconnectTask
            state.reconnectTask = nil
            return (state.session, reconnectTask)
        }
        reconnectTask?.cancel()
        try await session.channel.close()
    }
}
