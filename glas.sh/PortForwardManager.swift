//
//  PortForwardManager.swift
//  glas.sh
//
//  Manages port forwarding state and tunnel lifecycle per session.
//  Sprint 1: Local forwarding (-L) only.
//

import SwiftUI
import Observation
import NIOCore
import NIOPosix
import NIOSSH
import os

/// Manages SSH port forward tunnels across all active sessions.
///
/// Each local forward (-L) binds a TCP listener on 127.0.0.1:<localPort>.
/// When a local client connects, a direct-tcpip channel is opened through the
/// SSH connection to <remoteHost>:<remotePort>, and bytes are piped
/// bidirectionally between the two endpoints.
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
            guard forward.type == .local else {
                forwards[sessionID]?[index].status = .error
                forwards[sessionID]?[index].errorMessage = "Only local forwarding is supported in this release."
                return
            }
            guard let connection = session.getSSHConnection() else {
                forwards[sessionID]?[index].status = .error
                forwards[sessionID]?[index].errorMessage = "No active SSH connection."
                return
            }
            startLocalForward(forwardID: forward.id, sessionID: sessionID, connection: connection)
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
