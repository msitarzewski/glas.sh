//
//  PortForwardManager.swift
//  glas.sh
//
//  Manages port forwarding state and tunnel lifecycle per session.
//  Supports local (-L), remote (-R), and dynamic/SOCKS5 (-D) forwarding.
//

import SwiftUI
import Observation
import NIOCore
import NIOPosix
import NIOSSH
import os

struct SOCKS5Target: Equatable, Sendable {
    let host: String
    let port: Int
}

enum SOCKS5GreetingParseResult: Equatable, Sendable {
    case incomplete
    case selectUsernamePassword
    case rejectAuthenticationMethods
    case invalidVersion
}

struct SOCKS5CredentialBytes: Equatable, Sendable {
    let username: [UInt8]
    let password: [UInt8]
}

enum SOCKS5AuthenticationParseResult: Equatable, Sendable {
    case incomplete
    case authenticate(SOCKS5CredentialBytes)
    case invalidVersion
    case invalidCredentials
}

enum SOCKS5RequestParseResult: Equatable, Sendable {
    case incomplete
    case connect(SOCKS5Target)
    case invalidVersion
    case invalidReservedByte
    case unsupportedCommand
    case unsupportedAddressType
    case invalidAddress
}

actor SOCKS5ConnectionLimiter {
    private let maximumConnections: Int
    private var activeConnections = 0

    init(maximumConnections: Int) {
        self.maximumConnections = max(1, maximumConnections)
    }

    func acquire() -> Bool {
        guard activeConnections < maximumConnections else { return false }
        activeConnections += 1
        return true
    }

    func release() {
        activeConnections = max(0, activeConnections - 1)
    }
}

/// An idempotent permit keeps failed and cancelled handshakes from leaking a
/// limiter slot while allowing established tunnels to run independently of the
/// pre-authentication cap.
actor SOCKS5ConnectionPermit {
    private let limiter: SOCKS5ConnectionLimiter
    private var isReleased = false

    init(limiter: SOCKS5ConnectionLimiter) {
        self.limiter = limiter
    }

    func release() async {
        guard !isReleased else { return }
        isReleased = true
        await limiter.release()
    }
}

/// Tracks accepted local sockets separately from the listening socket. Closing
/// only the listener prevents new accepts, but does not terminate clients that
/// are already blocked in a forwarding pipe. Lifecycle shutdown drains this
/// registry before awaiting the owning tunnel task.
nonisolated final class PortForwardChildChannelRegistry: Sendable {
    private struct State {
        var channels: [ObjectIdentifier: any Channel] = [:]
        var isClosing = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns false after shutdown begins so an accept racing listener closure
    /// cannot escape the shutdown drain.
    func insert(_ channel: any Channel) -> Bool {
        state.withLock {
            guard !$0.isClosing else { return false }
            $0.channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    func remove(_ channel: any Channel) {
        state.withLock {
            _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func closeAllWithoutWaiting() {
        let channelsToClose = removeAll()
        for channel in channelsToClose {
            channel.close(promise: nil)
        }
    }

    func closeAllAndWait() async {
        let channelsToClose = removeAll()
        let failureCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for channel in channelsToClose {
                group.addTask {
                    do {
                        try await channel.close()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var failures = 0
            for await closed in group where !closed {
                failures += 1
            }
            return failures
        }
        if failureCount > 0 {
            Logger.ssh.error("Failed to close \(failureCount, privacy: .public) accepted port-forward channel(s) during shutdown")
        }
    }

    private func removeAll() -> [any Channel] {
        state.withLock {
            $0.isClosing = true
            let existing = Array($0.channels.values)
            $0.channels.removeAll(keepingCapacity: false)
            return existing
        }
    }
}

/// Manages SSH port forward tunnels across all active sessions.
///
/// - **Local (-L)**: Binds 127.0.0.1:<localPort>, tunnels each connection through
///   SSH direct-tcpip to <remoteHost>:<remotePort>.
/// - **Remote (-R)**: Asks the SSH server to listen on <remoteHost>:<remotePort>
///   and forward connections back to <localHost>:<localPort>.
/// - **Dynamic (-D)**: Binds a local SOCKS5 proxy on 127.0.0.1:<localPort>,
///   tunnels each connection through SSH direct-tcpip to the SOCKS-requested target.
@MainActor
@Observable
class PortForwardManager {
    nonisolated static let maximumConcurrentSOCKS5Connections = 64
    nonisolated static let socks5HandshakeTimeout: Duration = .seconds(15)
    var forwards: [UUID: [PortForward]] = [:] // sessionID -> forwards

    /// Running tunnel tasks keyed by forward ID.
    private var runningTunnels: [UUID: Task<Void, Never>] = [:]

    /// Identifies the current tunnel attempt for each persisted forward.
    /// A stopped attempt must not update a later restart that reuses the same ID.
    private var forwardRunIDs: [UUID: UUID] = [:]

    /// Bound server channels keyed by forward ID, used for shutdown.
    private var listenerChannels: [UUID: any Channel] = [:]

    /// Accepted local clients must close before the SSH transport is detached.
    private var childChannelRegistries: [UUID: PortForwardChildChannelRegistry] = [:]

    /// RFC 1929 credentials are deliberately process-memory-only and are never
    /// encoded into `PortForward`, UserDefaults, logs, or release diagnostics.
    private var socks5CredentialsByForwardID: [UUID: SOCKS5CredentialBytes] = [:]

    nonisolated private static let logger = Logger(subsystem: "sh.glas", category: "PortForwardManager")

    nonisolated private static func initializeAcceptedClient(
        _ childChannel: any Channel,
        continuation: AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.Continuation,
        registry: PortForwardChildChannelRegistry
    ) -> EventLoopFuture<Void> {
        childChannel.eventLoop.makeCompletedFuture {
            let asyncChild = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: childChannel
            )
            guard registry.insert(childChannel) else {
                childChannel.close(promise: nil)
                return
            }
            if case .terminated = continuation.yield(asyncChild) {
                registry.remove(childChannel)
                childChannel.close(promise: nil)
            }
        }
    }

    // MARK: - CRUD

    func addForward(_ forward: PortForward, to sessionID: UUID) {
        // Preserve source compatibility for local/remote callers. A legacy dynamic
        // caller may create the row, but it cannot start until credentials are set.
        if forwards[sessionID] == nil {
            forwards[sessionID] = []
        }
        socks5CredentialsByForwardID.removeValue(forKey: forward.id)
        var storedForward = forward
        if forward.type == .dynamic {
            storedForward.status = .error
            storedForward.errorMessage = "SOCKS5 username and password are required for this session."
        }
        forwards[sessionID]?.append(storedForward)
    }

    @discardableResult
    func addForward(
        _ forward: PortForward,
        to sessionID: UUID,
        socks5Username: String,
        socks5Password: String
    ) -> Bool {
        guard forward.type == .dynamic,
              let credentials = Self.socks5Credentials(
                username: socks5Username,
                password: socks5Password
              ) else {
            return false
        }
        if forwards[sessionID] == nil {
            forwards[sessionID] = []
        }
        socks5CredentialsByForwardID[forward.id] = credentials
        forwards[sessionID]?.append(forward)
        return true
    }

    @discardableResult
    func configureSOCKS5Credentials(
        for forwardID: UUID,
        username: String,
        password: String
    ) -> Bool {
        guard let sessionID = forwards.first(where: { _, sessionForwards in
            sessionForwards.contains(where: {
                $0.id == forwardID && $0.type == .dynamic && !$0.isActive
            })
        })?.key, let credentials = Self.socks5Credentials(username: username, password: password) else {
            return false
        }
        socks5CredentialsByForwardID[forwardID] = credentials
        if let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
            forwards[sessionID]?[index].status = .inactive
            forwards[sessionID]?[index].errorMessage = nil
        }
        return true
    }

    func removeForward(_ forward: PortForward, from sessionID: UUID) {
        stopForward(forward.id)
        socks5CredentialsByForwardID.removeValue(forKey: forward.id)
        forwards[sessionID]?.removeAll { $0.id == forward.id }
    }

    func forwards(for sessionID: UUID) -> [PortForward] {
        forwards[sessionID] ?? []
    }

    func hasSOCKS5Credentials(for forwardID: UUID) -> Bool {
        socks5CredentialsByForwardID[forwardID] != nil
    }

    // MARK: - Toggle

    func toggleForward(_ forward: PortForward, in sessionID: UUID, session: TerminalSession) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forward.id }) else {
            return
        }

        if forward.isActive {
            stopForward(forward.id)
            forwards[sessionID]?[index].status = .inactive
            forwards[sessionID]?[index].errorMessage = nil
        } else {
            guard let connection = session.getSSHConnection() else {
                forwards[sessionID]?[index].status = .error
                forwards[sessionID]?[index].errorMessage = "No active SSH connection."
                return
            }
            switch forward.type {
            case .local:
                startLocalForward(forwardID: forward.id, sessionID: sessionID, connection: connection)
            case .remote:
                startRemoteForward(forwardID: forward.id, sessionID: sessionID, connection: connection)
            case .dynamic:
                guard socks5CredentialsByForwardID[forward.id] != nil else {
                    forwards[sessionID]?[index].status = .error
                    forwards[sessionID]?[index].errorMessage = "SOCKS5 username and password are required for this session."
                    return
                }
                startDynamicForward(forwardID: forward.id, sessionID: sessionID, connection: connection)
            }
        }
    }

    // MARK: - Start Local Forward

    /// Bind a local TCP listener and tunnel each connection through SSH direct-tcpip.
    private func startLocalForward(forwardID: UUID, sessionID: UUID, connection: SSHConnection) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) else { return }

        let localPort = forwards[sessionID]![index].localPort
        let remoteHost = forwards[sessionID]![index].remoteHost
        let remotePort = forwards[sessionID]![index].remotePort

        forwards[sessionID]?[index].status = .starting
        forwards[sessionID]?[index].errorMessage = nil

        let runID = UUID()
        forwardRunIDs[forwardID] = runID
        let childRegistry = PortForwardChildChannelRegistry()
        childChannelRegistries[forwardID] = childRegistry

        let task = Task<Void, Never> { [weak self] in
            do {
                // Stream to receive accepted local connections as NIOAsyncChannels
                let (acceptedClients, continuation) = AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.makeStream()

                let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { childChannel in
                        Self.initializeAcceptedClient(
                            childChannel,
                            continuation: continuation,
                            registry: childRegistry
                        )
                    }
                    .bind(host: "127.0.0.1", port: localPort)
                    .get()

                let claimedListener = await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID,
                          self.runningTunnels[forwardID] != nil,
                          !Task.isCancelled else {
                        return false
                    }
                    self.listenerChannels[forwardID] = serverChannel
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .active
                        Self.logger.info("Local forward active: 127.0.0.1:\(localPort) -> \(remoteHost):\(remotePort)")
                    }
                    return true
                }
                guard claimedListener else {
                    continuation.finish()
                    try? await serverChannel.close()
                    return
                }

                // Process accepted connections until cancelled or server closes
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // When the server channel closes, finish the stream
                        try await serverChannel.closeFuture.get()
                        continuation.finish()
                    }

                    group.addTask {
                        await withDiscardingTaskGroup { connectionGroup in
                            for await localClient in acceptedClients {
                                connectionGroup.addTask {
                                    defer { childRegistry.remove(localClient.channel) }
                                    await Self.handleLocalConnection(
                                        localClient: localClient,
                                        remoteHost: remoteHost,
                                        remotePort: remotePort,
                                        connection: connection
                                    )
                                }
                            }
                        }
                    }

                    defer {
                        continuation.finish()
                        group.cancelAll()
                    }
                    try await group.next()
                }
                await MainActor.run {
                    guard let self, self.forwardRunIDs[forwardID] == runID else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    self.listenerChannels.removeValue(forKey: forwardID)
                    self.childChannelRegistries.removeValue(forKey: forwardID)
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .inactive
                        self.forwards[sessionID]?[idx].errorMessage = nil
                    }
                }
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID,
                          self.runningTunnels[forwardID] != nil else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    self.listenerChannels.removeValue(forKey: forwardID)?.close(promise: nil)
                    self.childChannelRegistries.removeValue(forKey: forwardID)?.closeAllWithoutWaiting()
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .error
                        self.forwards[sessionID]?[idx].errorMessage = Self.userFacingBindError(error, port: localPort)
                        Self.logger.error("Local forward failed on port \(localPort): \(error)")
                    }
                }
            }
        }

        runningTunnels[forwardID] = task
    }

    // MARK: - Handle a single local connection

    /// Establish a direct-tcpip SSH channel and pipe data bidirectionally with the local socket.
    /// Follows the pattern from Citadel's RemotePortForward+Client.swift (lines 273-289).
    nonisolated private static func handleLocalConnection(
        localClient: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        remoteHost: String,
        remotePort: Int,
        connection: SSHConnection
    ) async {
        do {
            // Open a direct-tcpip channel through SSH to reach the remote target.
            // SSHConnection is @MainActor, so this call hops to the main actor.
            let sshChannel = try await connection.createDirectTCPIPChannel(
                targetHost: remoteHost,
                targetPort: remotePort
            )

            let sshAsyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: sshChannel
            )

            // Bidirectional pipe: local <-> SSH channel
            try await localClient.executeThenClose { localInbound, localOutbound in
                try await sshAsyncChannel.executeThenClose { sshInbound, sshOutbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // local -> remote
                        group.addTask {
                            for try await data in localInbound {
                                try await sshOutbound.write(data)
                            }
                        }
                        // remote -> local
                        group.addTask {
                            for try await data in sshInbound {
                                try await localOutbound.write(data)
                            }
                        }

                        // When either direction closes, tear down both
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                }
            }
        } catch {
            logger.debug("Port forward connection ended: \(error)")
            // Close the local client channel on error
            try? await localClient.channel.close()
        }
    }

    // MARK: - Start Remote Forward

    /// Ask the SSH server to listen on remoteHost:remotePort and forward back
    /// through the tunnel to localHost:localPort (-R).
    private func startRemoteForward(forwardID: UUID, sessionID: UUID, connection: SSHConnection) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) else { return }

        let localPort = forwards[sessionID]![index].localPort
        let remoteHost = forwards[sessionID]![index].remoteHost
        let remotePort = forwards[sessionID]![index].remotePort

        forwards[sessionID]?[index].status = .starting
        forwards[sessionID]?[index].errorMessage = nil

        let runID = UUID()
        forwardRunIDs[forwardID] = runID

        let task = Task<Void, Never> { [weak self] in
            do {
                try await connection.runRemotePortForward(
                    remoteHost: remoteHost, remotePort: remotePort,
                    localHost: "127.0.0.1", localPort: localPort
                ) { [weak self] boundPort in
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID,
                          self.runningTunnels[forwardID] != nil,
                          !Task.isCancelled,
                          let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }),
                          self.forwards[sessionID]?[idx].status == .starting else {
                        return
                    }

                    self.forwards[sessionID]?[idx].status = .active
                    Self.logger.info(
                        "Remote forward active: \(remoteHost):\(boundPort) -> 127.0.0.1:\(localPort)"
                    )
                }
                guard !Task.isCancelled else { return }

                // runRemotePortForward blocks until cancelled; reaching here means
                // the remote side closed gracefully.
                await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .inactive
                        self.forwards[sessionID]?[idx].errorMessage = nil
                    }
                }
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .error
                        self.forwards[sessionID]?[idx].errorMessage = "Remote forward failed: \(error.localizedDescription)"
                        Self.logger.error("Remote forward failed \(remoteHost):\(remotePort): \(error)")
                    }
                }
            }
        }

        Self.logger.info("Remote forward starting: \(remoteHost):\(remotePort) -> 127.0.0.1:\(localPort)")

        runningTunnels[forwardID] = task
    }

    // MARK: - Start Dynamic (SOCKS5) Forward

    /// Bind a local SOCKS5 proxy on 127.0.0.1:<localPort> (-D).
    /// Each accepted connection performs a SOCKS5 handshake, then tunnels
    /// data through an SSH direct-tcpip channel to the requested target.
    private func startDynamicForward(forwardID: UUID, sessionID: UUID, connection: SSHConnection) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }),
              let credentials = socks5CredentialsByForwardID[forwardID] else {
            return
        }

        let localPort = forwards[sessionID]![index].localPort

        forwards[sessionID]?[index].status = .starting
        forwards[sessionID]?[index].errorMessage = nil

        let runID = UUID()
        forwardRunIDs[forwardID] = runID
        let connectionLimiter = SOCKS5ConnectionLimiter(
            maximumConnections: Self.maximumConcurrentSOCKS5Connections
        )
        let childRegistry = PortForwardChildChannelRegistry()
        childChannelRegistries[forwardID] = childRegistry

        let task = Task<Void, Never> { [weak self] in
            do {
                let (acceptedClients, continuation) = AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.makeStream()

                let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { childChannel in
                        Self.initializeAcceptedClient(
                            childChannel,
                            continuation: continuation,
                            registry: childRegistry
                        )
                    }
                    .bind(host: "127.0.0.1", port: localPort)
                    .get()

                let claimedListener = await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID,
                          self.runningTunnels[forwardID] != nil,
                          !Task.isCancelled else {
                        return false
                    }
                    self.listenerChannels[forwardID] = serverChannel
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .active
                        Self.logger.info("Dynamic SOCKS5 forward active: 127.0.0.1:\(localPort)")
                    }
                    return true
                }
                guard claimedListener else {
                    continuation.finish()
                    try? await serverChannel.close()
                    return
                }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await serverChannel.closeFuture.get()
                        continuation.finish()
                    }

                    group.addTask {
                        await withDiscardingTaskGroup { connectionGroup in
                            for await localClient in acceptedClients {
                                guard await connectionLimiter.acquire() else {
                                    try? await localClient.channel.close()
                                    childRegistry.remove(localClient.channel)
                                    continue
                                }
                                let handshakePermit = SOCKS5ConnectionPermit(
                                    limiter: connectionLimiter
                                )
                                connectionGroup.addTask {
                                    defer { childRegistry.remove(localClient.channel) }
                                    await Self.handleSOCKS5Connection(
                                        localClient: localClient,
                                        connection: connection,
                                        credentials: credentials,
                                        handshakePermit: handshakePermit
                                    )
                                    await handshakePermit.release()
                                }
                            }
                        }
                    }

                    defer {
                        continuation.finish()
                        group.cancelAll()
                    }
                    try await group.next()
                }
                await MainActor.run {
                    guard let self, self.forwardRunIDs[forwardID] == runID else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    self.listenerChannels.removeValue(forKey: forwardID)
                    self.childChannelRegistries.removeValue(forKey: forwardID)
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .inactive
                        self.forwards[sessionID]?[idx].errorMessage = nil
                    }
                }
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self,
                          self.forwardRunIDs[forwardID] == runID,
                          self.runningTunnels[forwardID] != nil else { return }
                    self.forwardRunIDs.removeValue(forKey: forwardID)
                    self.runningTunnels.removeValue(forKey: forwardID)
                    self.listenerChannels.removeValue(forKey: forwardID)?.close(promise: nil)
                    self.childChannelRegistries.removeValue(forKey: forwardID)?.closeAllWithoutWaiting()
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .error
                        self.forwards[sessionID]?[idx].errorMessage = Self.userFacingBindError(error, port: localPort)
                        Self.logger.error("Dynamic forward failed on port \(localPort): \(error)")
                    }
                }
            }
        }

        runningTunnels[forwardID] = task
    }

    // MARK: - SOCKS5 Connection Handler

    nonisolated static let maximumSOCKS5GreetingBytes = 257
    nonisolated static let maximumSOCKS5AuthenticationBytes = 513
    nonisolated static let maximumSOCKS5ConnectRequestBytes = 262
    nonisolated static let maximumSOCKS5BufferedHandshakeBytes = 64 * 1024

    nonisolated static func appendSOCKS5HandshakeBytes(
        _ chunk: inout ByteBuffer,
        to buffer: inout ByteBuffer
    ) -> Bool {
        guard buffer.readableBytes <= maximumSOCKS5BufferedHandshakeBytes,
              chunk.readableBytes <= maximumSOCKS5BufferedHandshakeBytes - buffer.readableBytes else {
            return false
        }
        buffer.writeBuffer(&chunk)
        return true
    }

    nonisolated static func socks5Credentials(
        username: String,
        password: String
    ) -> SOCKS5CredentialBytes? {
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        guard (1...255).contains(usernameBytes.count),
              (1...255).contains(passwordBytes.count) else {
            return nil
        }
        return SOCKS5CredentialBytes(username: usernameBytes, password: passwordBytes)
    }

    /// Fixed-work comparison across RFC 1929's entire 255-byte field capacity.
    /// Both username and password comparisons are always evaluated by the caller.
    nonisolated static func constantTimeSOCKS5FieldEquals(
        _ presented: [UInt8],
        _ expected: [UInt8]
    ) -> Bool {
        var difference = UInt16(presented.count ^ expected.count)
        for index in 0..<255 {
            let presentedByte = index < presented.count ? presented[index] : 0
            let expectedByte = index < expected.count ? expected[index] : 0
            difference |= UInt16(presentedByte ^ expectedByte)
        }
        return difference == 0
    }

    nonisolated static func authenticateSOCKS5(
        presented: SOCKS5CredentialBytes,
        expected: SOCKS5CredentialBytes
    ) -> Bool {
        let usernameMatches = constantTimeSOCKS5FieldEquals(presented.username, expected.username)
        let passwordMatches = constantTimeSOCKS5FieldEquals(presented.password, expected.password)
        return usernameMatches && passwordMatches
    }

    nonisolated static func parseSOCKS5Greeting(
        from buffer: inout ByteBuffer
    ) -> SOCKS5GreetingParseResult {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 2,
              let version = buffer.getInteger(at: start, as: UInt8.self),
              let methodCount = buffer.getInteger(at: start + 1, as: UInt8.self) else {
            return .incomplete
        }

        guard version == 0x05 else {
            buffer.moveReaderIndex(forwardBy: 2)
            return .invalidVersion
        }

        let messageLength = 2 + Int(methodCount)
        guard messageLength <= maximumSOCKS5GreetingBytes else {
            buffer.moveReaderIndex(forwardBy: 2)
            return .rejectAuthenticationMethods
        }
        guard buffer.readableBytes >= messageLength,
              let methods = buffer.getBytes(at: start + 2, length: Int(methodCount)) else {
            return .incomplete
        }

        buffer.moveReaderIndex(forwardBy: messageLength)
        guard methods.contains(0x02) else {
            return .rejectAuthenticationMethods
        }
        return .selectUsernamePassword
    }

    nonisolated static func parseSOCKS5Authentication(
        from buffer: inout ByteBuffer
    ) -> SOCKS5AuthenticationParseResult {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 2,
              let version = buffer.getInteger(at: start, as: UInt8.self),
              let usernameLength = buffer.getInteger(at: start + 1, as: UInt8.self) else {
            return .incomplete
        }
        guard version == 0x01 else {
            buffer.moveReaderIndex(forwardBy: 2)
            return .invalidVersion
        }
        guard usernameLength > 0 else {
            buffer.moveReaderIndex(forwardBy: 2)
            return .invalidCredentials
        }

        let passwordLengthIndex = start + 2 + Int(usernameLength)
        guard buffer.writerIndex > passwordLengthIndex,
              let passwordLength = buffer.getInteger(at: passwordLengthIndex, as: UInt8.self) else {
            return .incomplete
        }
        guard passwordLength > 0 else {
            buffer.moveReaderIndex(forwardBy: 3 + Int(usernameLength))
            return .invalidCredentials
        }

        let messageLength = 3 + Int(usernameLength) + Int(passwordLength)
        guard messageLength <= maximumSOCKS5AuthenticationBytes else {
            buffer.moveReaderIndex(forwardBy: 2)
            return .invalidCredentials
        }
        guard buffer.readableBytes >= messageLength,
              let username = buffer.getBytes(at: start + 2, length: Int(usernameLength)),
              let password = buffer.getBytes(
                at: passwordLengthIndex + 1,
                length: Int(passwordLength)
              ) else {
            return .incomplete
        }
        buffer.moveReaderIndex(forwardBy: messageLength)
        return .authenticate(.init(username: username, password: password))
    }

    nonisolated static func parseSOCKS5ConnectRequest(
        from buffer: inout ByteBuffer
    ) -> SOCKS5RequestParseResult {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 4,
              let version = buffer.getInteger(at: start, as: UInt8.self),
              let command = buffer.getInteger(at: start + 1, as: UInt8.self),
              let reserved = buffer.getInteger(at: start + 2, as: UInt8.self),
              let addressType = buffer.getInteger(at: start + 3, as: UInt8.self) else {
            return .incomplete
        }

        guard version == 0x05 else {
            buffer.moveReaderIndex(forwardBy: 4)
            return .invalidVersion
        }
        guard reserved == 0x00 else {
            buffer.moveReaderIndex(forwardBy: 4)
            return .invalidReservedByte
        }
        guard command == 0x01 else {
            buffer.moveReaderIndex(forwardBy: 4)
            return .unsupportedCommand
        }

        let host: String
        let requestLength: Int
        switch addressType {
        case 0x01:
            requestLength = 10
            guard buffer.readableBytes >= requestLength,
                  let address = buffer.getBytes(at: start + 4, length: 4) else {
                return .incomplete
            }
            host = address.map(String.init).joined(separator: ".")

        case 0x03:
            guard buffer.readableBytes >= 5,
                  let nameLength = buffer.getInteger(at: start + 4, as: UInt8.self) else {
                return .incomplete
            }
            guard nameLength > 0 else {
                buffer.moveReaderIndex(forwardBy: 5)
                return .invalidAddress
            }
            requestLength = 7 + Int(nameLength)
            guard buffer.readableBytes >= requestLength,
                  let nameBytes = buffer.getBytes(at: start + 5, length: Int(nameLength)),
                  let name = String(bytes: nameBytes, encoding: .utf8) else {
                return buffer.readableBytes >= requestLength ? .invalidAddress : .incomplete
            }
            host = name

        case 0x04:
            requestLength = 22
            guard buffer.readableBytes >= requestLength else {
                return .incomplete
            }
            var segments: [String] = []
            segments.reserveCapacity(8)
            for offset in stride(from: 4, to: 20, by: 2) {
                guard let segment = buffer.getInteger(
                    at: start + offset,
                    endianness: .big,
                    as: UInt16.self
                ) else {
                    return .incomplete
                }
                segments.append(String(segment, radix: 16))
            }
            host = segments.joined(separator: ":")

        default:
            buffer.moveReaderIndex(forwardBy: 4)
            return .unsupportedAddressType
        }

        guard requestLength <= maximumSOCKS5ConnectRequestBytes else {
            buffer.moveReaderIndex(forwardBy: 4)
            return .invalidAddress
        }

        guard let port = buffer.getInteger(
            at: start + requestLength - 2,
            endianness: .big,
            as: UInt16.self
        ) else {
            return .incomplete
        }
        buffer.moveReaderIndex(forwardBy: requestLength)
        guard port > 0 else {
            return .invalidAddress
        }
        return .connect(SOCKS5Target(host: host, port: Int(port)))
    }

    nonisolated private static func socks5Reply(code: UInt8) -> ByteBuffer {
        var reply = ByteBuffer()
        reply.writeBytes([0x05, code, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        return reply
    }

    /// Perform SOCKS5 handshake on a local client, then tunnel to the requested
    /// target through SSH direct-tcpip.
    nonisolated private static func handleSOCKS5Connection(
        localClient: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connection: SSHConnection,
        credentials: SOCKS5CredentialBytes,
        handshakePermit: SOCKS5ConnectionPermit
    ) async {
        let handshakeTimeoutTask = Task {
            do {
                try await Task.sleep(for: socks5HandshakeTimeout)
                try Task.checkCancellation()
                try? await localClient.channel.close()
            } catch {
                // Cancellation means the complete handshake beat the deadline.
            }
        }
        defer { handshakeTimeoutTask.cancel() }
        do {
            try await localClient.executeThenClose { localInbound, localOutbound in
                var bufferedClientData = ByteBuffer()
                var inboundIterator = localInbound.makeAsyncIterator()

                var greetingResult = parseSOCKS5Greeting(from: &bufferedClientData)
                while case .incomplete = greetingResult {
                    guard bufferedClientData.readableBytes < maximumSOCKS5GreetingBytes,
                          var chunk = try await inboundIterator.next() else { return }
                    guard appendSOCKS5HandshakeBytes(&chunk, to: &bufferedClientData) else { return }
                    greetingResult = parseSOCKS5Greeting(from: &bufferedClientData)
                }

                switch greetingResult {
                case .selectUsernamePassword:
                    var authReply = ByteBuffer()
                    authReply.writeBytes([0x05, 0x02])
                    try await localOutbound.write(authReply)
                case .rejectAuthenticationMethods:
                    var rejection = ByteBuffer()
                    rejection.writeBytes([0x05, 0xFF])
                    try await localOutbound.write(rejection)
                    return
                case .invalidVersion, .incomplete:
                    return
                }

                var authenticationResult = parseSOCKS5Authentication(from: &bufferedClientData)
                while case .incomplete = authenticationResult {
                    guard bufferedClientData.readableBytes < maximumSOCKS5AuthenticationBytes,
                          var chunk = try await inboundIterator.next() else {
                        return
                    }
                    guard appendSOCKS5HandshakeBytes(&chunk, to: &bufferedClientData) else { return }
                    authenticationResult = parseSOCKS5Authentication(from: &bufferedClientData)
                }

                let authenticated: Bool
                switch authenticationResult {
                case .authenticate(let presented):
                    authenticated = authenticateSOCKS5(
                        presented: presented,
                        expected: credentials
                    )
                case .invalidVersion, .invalidCredentials, .incomplete:
                    authenticated = false
                }
                var authenticationReply = ByteBuffer()
                authenticationReply.writeBytes([0x01, authenticated ? 0x00 : 0x01])
                try await localOutbound.write(authenticationReply)
                guard authenticated else { return }

                var requestResult = parseSOCKS5ConnectRequest(from: &bufferedClientData)
                while case .incomplete = requestResult {
                    guard bufferedClientData.readableBytes < maximumSOCKS5ConnectRequestBytes,
                          var chunk = try await inboundIterator.next() else { return }
                    guard appendSOCKS5HandshakeBytes(&chunk, to: &bufferedClientData) else { return }
                    requestResult = parseSOCKS5ConnectRequest(from: &bufferedClientData)
                }

                let target: SOCKS5Target
                switch requestResult {
                case .connect(let parsedTarget):
                    target = parsedTarget
                case .unsupportedCommand:
                    try await localOutbound.write(socks5Reply(code: 0x07))
                    return
                case .unsupportedAddressType:
                    try await localOutbound.write(socks5Reply(code: 0x08))
                    return
                case .invalidReservedByte, .invalidAddress:
                    try await localOutbound.write(socks5Reply(code: 0x01))
                    return
                case .invalidVersion, .incomplete:
                    return
                }
                // Open direct-tcpip channel through SSH
                let sshChannel: any Channel
                do {
                    sshChannel = try await connection.createDirectTCPIPChannel(
                        targetHost: target.host,
                        targetPort: target.port
                    )
                } catch {
                    try await localOutbound.write(socks5Reply(code: 0x01))
                    return
                }
                handshakeTimeoutTask.cancel()
                await handshakePermit.release()

                let sshAsyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: sshChannel
                )

                // SOCKS5 success reply
                try await localOutbound.write(socks5Reply(code: 0x00))

                logger.debug("SOCKS5 tunnel opened")

                // Bidirectional pipe: local <-> SSH channel
                let pendingClientData = bufferedClientData
                try await sshAsyncChannel.executeThenClose { sshInbound, sshOutbound in
                    let remoteToLocalTask = Task {
                        defer { localClient.channel.close(promise: nil) }
                        for try await data in sshInbound {
                            try await localOutbound.write(data)
                        }
                    }

                    do {
                        if pendingClientData.readableBytes > 0 {
                            try await sshOutbound.write(pendingClientData)
                        }
                        while let data = try await inboundIterator.next() {
                            try await sshOutbound.write(data)
                        }
                    } catch {
                        remoteToLocalTask.cancel()
                        _ = try? await remoteToLocalTask.value
                        throw error
                    }

                    remoteToLocalTask.cancel()
                    do {
                        try await remoteToLocalTask.value
                    } catch is CancellationError {
                        // The local half closed first, so cancellation is expected.
                    }
                }
            }
        } catch {
            logger.debug("SOCKS5 connection ended: \(error)")
            try? await localClient.channel.close()
        }
    }

    // MARK: - Stop

    func stopForward(_ forwardID: UUID) {
        forwardRunIDs.removeValue(forKey: forwardID)
        runningTunnels[forwardID]?.cancel()
        runningTunnels.removeValue(forKey: forwardID)

        if let channel = listenerChannels.removeValue(forKey: forwardID) {
            channel.close(promise: nil)
        }
        childChannelRegistries.removeValue(forKey: forwardID)?.closeAllWithoutWaiting()
    }

    func stopAllForwardsAndWait(for sessionID: UUID) async {
        let forwardIDs = forwards[sessionID]?.map(\.id) ?? []
        var tasks: [Task<Void, Never>] = []
        var channels: [any Channel] = []
        var childRegistries: [PortForwardChildChannelRegistry] = []

        for forwardID in forwardIDs {
            forwardRunIDs.removeValue(forKey: forwardID)
            if let task = runningTunnels.removeValue(forKey: forwardID) {
                task.cancel()
                tasks.append(task)
            }
            if let channel = listenerChannels.removeValue(forKey: forwardID) {
                channels.append(channel)
            }
            if let registry = childChannelRegistries.removeValue(forKey: forwardID) {
                childRegistries.append(registry)
            }
        }

        let listenerCloseFailureCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        try await channel.close()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for registry in childRegistries {
                group.addTask {
                    await registry.closeAllAndWait()
                    return true
                }
            }
            for task in tasks {
                group.addTask {
                    await task.value
                    return true
                }
            }
            var failures = 0
            for await closed in group where !closed {
                failures += 1
            }
            return failures
        }
        if listenerCloseFailureCount > 0 {
            Logger.ssh.error("Failed to close \(listenerCloseFailureCount, privacy: .public) port-forward listener channel(s) during shutdown")
        }

        for forwardID in forwardIDs {
            if let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                forwards[sessionID]?[index].status = .inactive
                forwards[sessionID]?[index].errorMessage = nil
            }
        }
    }

    func stopAllForwards(for sessionID: UUID) {
        guard let sessionForwards = forwards[sessionID] else { return }
        for forward in sessionForwards {
            stopForward(forward.id)
            if let idx = forwards[sessionID]?.firstIndex(where: { $0.id == forward.id }) {
                forwards[sessionID]?[idx].status = .inactive
                forwards[sessionID]?[idx].errorMessage = nil
            }
        }
    }

    func purgeAllForwards(for sessionID: UUID) {
        let forwardIDs = forwards[sessionID]?.map(\.id) ?? []
        for forwardID in forwardIDs {
            stopForward(forwardID)
            socks5CredentialsByForwardID.removeValue(forKey: forwardID)
        }
        forwards.removeValue(forKey: sessionID)
    }

    // MARK: - Error Formatting

    private static func userFacingBindError(_ error: Error, port: Int) -> String {
        let description = "\(error)"
        if description.contains("address_already_in_use") || description.contains("EADDRINUSE") || description.contains("Address already in use") {
            return "Port \(port) is already in use."
        }
        if description.contains("permission_denied") || description.contains("EACCES") {
            return "Permission denied binding port \(port). Ports below 1024 require elevated privileges."
        }
        return "Failed to bind port \(port): \(error.localizedDescription)"
    }
}
