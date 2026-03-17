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
    var forwards: [UUID: [PortForward]] = [:] // sessionID -> forwards

    /// Running tunnel tasks keyed by forward ID.
    private var runningTunnels: [UUID: Task<Void, Never>] = [:]

    /// Bound server channels keyed by forward ID, used for shutdown.
    private var listenerChannels: [UUID: any Channel] = [:]

    private static let logger = Logger(subsystem: "sh.glas", category: "PortForwardManager")

    // MARK: - CRUD

    func addForward(_ forward: PortForward, to sessionID: UUID) {
        if forwards[sessionID] == nil {
            forwards[sessionID] = []
        }
        forwards[sessionID]?.append(forward)
    }

    func removeForward(_ forward: PortForward, from sessionID: UUID) {
        stopForward(forward.id)
        forwards[sessionID]?.removeAll { $0.id == forward.id }
    }

    func forwards(for sessionID: UUID) -> [PortForward] {
        forwards[sessionID] ?? []
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

        let task = Task<Void, Never> { [weak self] in
            do {
                // Stream to receive accepted local connections as NIOAsyncChannels
                let (acceptedClients, continuation) = AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.makeStream()

                let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { childChannel in
                        childChannel.eventLoop.makeCompletedFuture {
                            let asyncChild = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: childChannel
                            )
                            continuation.yield(asyncChild)
                        }
                    }
                    .bind(host: "127.0.0.1", port: localPort)
                    .get()

                await MainActor.run {
                    guard let self else { return }
                    self.listenerChannels[forwardID] = serverChannel
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .active
                        Self.logger.info("Local forward active: 127.0.0.1:\(localPort) -> \(remoteHost):\(remotePort)")
                    }
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
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self else { return }
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
    private static func handleLocalConnection(
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

        let task = Task<Void, Never> { [weak self] in
            do {
                try await connection.runRemotePortForward(
                    remoteHost: remoteHost, remotePort: remotePort,
                    localHost: "127.0.0.1", localPort: localPort
                )
                // runRemotePortForward blocks until cancelled; reaching here means
                // the remote side closed gracefully.
                await MainActor.run {
                    guard let self else { return }
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .inactive
                        self.forwards[sessionID]?[idx].errorMessage = nil
                    }
                }
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .error
                        self.forwards[sessionID]?[idx].errorMessage = "Remote forward failed: \(error.localizedDescription)"
                        Self.logger.error("Remote forward failed \(remoteHost):\(remotePort): \(error)")
                    }
                }
            }
        }

        // Mark active once the task is spawned; the actual server-side bind
        // confirmation happens inside runRemotePortForward's onOpen callback.
        forwards[sessionID]?[index].status = .active
        Self.logger.info("Remote forward starting: \(remoteHost):\(remotePort) -> 127.0.0.1:\(localPort)")

        runningTunnels[forwardID] = task
    }

    // MARK: - Start Dynamic (SOCKS5) Forward

    /// Bind a local SOCKS5 proxy on 127.0.0.1:<localPort> (-D).
    /// Each accepted connection performs a SOCKS5 handshake, then tunnels
    /// data through an SSH direct-tcpip channel to the requested target.
    private func startDynamicForward(forwardID: UUID, sessionID: UUID, connection: SSHConnection) {
        guard let index = forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) else { return }

        let localPort = forwards[sessionID]![index].localPort

        forwards[sessionID]?[index].status = .starting
        forwards[sessionID]?[index].errorMessage = nil

        let task = Task<Void, Never> { [weak self] in
            do {
                let (acceptedClients, continuation) = AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.makeStream()

                let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { childChannel in
                        childChannel.eventLoop.makeCompletedFuture {
                            let asyncChild = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: childChannel
                            )
                            continuation.yield(asyncChild)
                        }
                    }
                    .bind(host: "127.0.0.1", port: localPort)
                    .get()

                await MainActor.run {
                    guard let self else { return }
                    self.listenerChannels[forwardID] = serverChannel
                    if let idx = self.forwards[sessionID]?.firstIndex(where: { $0.id == forwardID }) {
                        self.forwards[sessionID]?[idx].status = .active
                        Self.logger.info("Dynamic SOCKS5 forward active: 127.0.0.1:\(localPort)")
                    }
                }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await serverChannel.closeFuture.get()
                        continuation.finish()
                    }

                    group.addTask {
                        await withDiscardingTaskGroup { connectionGroup in
                            for await localClient in acceptedClients {
                                connectionGroup.addTask {
                                    await Self.handleSOCKS5Connection(
                                        localClient: localClient,
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
            } catch is CancellationError {
                // Normal shutdown path
            } catch {
                await MainActor.run {
                    guard let self else { return }
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

    /// Perform SOCKS5 handshake on a local client, then tunnel to the requested
    /// target through SSH direct-tcpip.
    private static func handleSOCKS5Connection(
        localClient: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connection: SSHConnection
    ) async {
        do {
            try await localClient.executeThenClose { localInbound, localOutbound in
                // --- SOCKS5 greeting ---
                // Expect: [0x05, nMethods, ...methods]
                guard var greeting = try await localInbound.first(where: { _ in true }) else { return }
                guard greeting.readableBytes >= 2 else { return }
                let version = greeting.readInteger(as: UInt8.self)!
                guard version == 0x05 else { return } // Must be SOCKS5
                let nMethods = Int(greeting.readInteger(as: UInt8.self)!)
                // Skip method bytes (we accept no-auth regardless)
                _ = greeting.readSlice(length: min(nMethods, greeting.readableBytes))

                // Reply: no authentication required
                var authReply = ByteBuffer()
                authReply.writeInteger(UInt8(0x05))
                authReply.writeInteger(UInt8(0x00))
                try await localOutbound.write(authReply)

                // --- SOCKS5 connect request ---
                // [0x05, 0x01, 0x00, addrType, ...addr..., port_hi, port_lo]
                guard var request = try await localInbound.first(where: { _ in true }) else { return }
                guard request.readableBytes >= 4 else { return }
                let reqVersion = request.readInteger(as: UInt8.self)!
                let command = request.readInteger(as: UInt8.self)!
                _ = request.readInteger(as: UInt8.self)! // reserved
                let addrType = request.readInteger(as: UInt8.self)!

                guard reqVersion == 0x05, command == 0x01 else { // only CONNECT
                    // Send general failure reply
                    var failReply = ByteBuffer()
                    failReply.writeBytes([0x05, 0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    try await localOutbound.write(failReply)
                    return
                }

                let targetHost: String
                switch addrType {
                case 0x01: // IPv4
                    guard request.readableBytes >= 6 else { return }
                    let a = request.readInteger(as: UInt8.self)!
                    let b = request.readInteger(as: UInt8.self)!
                    let c = request.readInteger(as: UInt8.self)!
                    let d = request.readInteger(as: UInt8.self)!
                    targetHost = "\(a).\(b).\(c).\(d)"
                case 0x03: // Domain name
                    guard request.readableBytes >= 1 else { return }
                    let nameLen = Int(request.readInteger(as: UInt8.self)!)
                    guard request.readableBytes >= nameLen + 2 else { return }
                    guard let nameBytes = request.readSlice(length: nameLen),
                          let name = nameBytes.getString(at: nameBytes.readerIndex, length: nameLen) else { return }
                    targetHost = name
                case 0x04: // IPv6
                    guard request.readableBytes >= 18 else { return }
                    var parts: [String] = []
                    for _ in 0..<8 {
                        let segment = request.readInteger(as: UInt16.self)!
                        parts.append(String(segment, radix: 16))
                    }
                    targetHost = parts.joined(separator: ":")
                default:
                    // Unsupported address type
                    var failReply = ByteBuffer()
                    failReply.writeBytes([0x05, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                    try await localOutbound.write(failReply)
                    return
                }

                guard request.readableBytes >= 2 else { return }
                let targetPort = Int(request.readInteger(as: UInt16.self)!)

                // Open direct-tcpip channel through SSH
                let sshChannel = try await connection.createDirectTCPIPChannel(
                    targetHost: targetHost,
                    targetPort: targetPort
                )

                let sshAsyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: sshChannel
                )

                // SOCKS5 success reply
                var successReply = ByteBuffer()
                successReply.writeBytes([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                try await localOutbound.write(successReply)

                logger.debug("SOCKS5 tunnel opened: \(targetHost):\(targetPort)")

                // Bidirectional pipe: local <-> SSH channel
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

                        defer { group.cancelAll() }
                        try await group.next()
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
        runningTunnels[forwardID]?.cancel()
        runningTunnels.removeValue(forKey: forwardID)

        if let channel = listenerChannels.removeValue(forKey: forwardID) {
            channel.close(promise: nil)
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
