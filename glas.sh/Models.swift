//
//  Models.swift
//  glas.sh
//
//  Core data models for SSH connections, sessions, and configuration
//

import SwiftUI
import Foundation
import CoreGraphics
import Security
import Observation
import Citadel
import NIOCore
import NIOSSH
import Logging
import RealityKitContent
import os
import GlasSecretStore
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Host Key Verification

enum HostKeyVerificationMode: String, Codable, CaseIterable {
    case ask = "Ask"
    case strict = "Strict"
}

struct TrustedHostKeyEntry: Codable, Identifiable, Hashable {
    var id: String { "\(host):\(port):\(algorithm):\(fingerprintSHA256)" }
    let host: String
    let port: Int
    let algorithm: String
    let fingerprintSHA256: String
    let keyDataBase64: String
    let addedAt: Date
}

// MARK: - Authentication

enum AuthenticationMethod: String, Codable, CaseIterable {
    case password
    case sshKey
    case agent
    
    var displayName: String {
        switch self {
        case .password: return "Password"
        case .sshKey: return "SSH Key"
        case .agent: return "SSH Agent"
        }
    }
    
    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "key.radiowaves.forward.fill"
        case .agent: return "person.badge.key.fill"
        }
    }
}

// MARK: - Server Configuration

struct ServerConfiguration: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthenticationMethod
    var sshKeyPath: String?
    var sshKeyID: UUID?
    var trustedHostKeys: [TrustedHostKeyEntry]?
    var isFavorite: Bool
    var colorTag: ServerColorTag
    let dateAdded: Date
    var lastConnected: Date?
    var tags: [String]
    var jumpHostID: UUID?
    var jumpHostIDs: [UUID]?

    /// Returns the ordered list of jump host UUIDs, preferring the multi-hop
    /// array when present and falling back to the legacy single-hop property.
    var resolvedJumpHostIDs: [UUID] {
        if let ids = jumpHostIDs, !ids.isEmpty { return ids }
        if let id = jumpHostID { return [id] }
        return []
    }

    // Advanced options
    var compression: Bool
    var keepAliveInterval: Int // seconds
    var serverAliveCountMax: Int
    var forwardAgent: Bool
    /// Explicit, per-host opt-in for compatibility algorithms. Existing
    /// records with no value remain on the modern default policy.
    var allowLegacyAlgorithms: Bool?
    var requestPTY: Bool
    var terminalType: String
    var environmentVariables: [String: String]
    
    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthenticationMethod = .password,
        sshKeyPath: String? = nil,
        sshKeyID: UUID? = nil,
        isFavorite: Bool = false,
        colorTag: ServerColorTag = .blue,
        tags: [String] = [],
        jumpHostID: UUID? = nil,
        jumpHostIDs: [UUID]? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sshKeyPath = sshKeyPath
        self.sshKeyID = sshKeyID
        self.trustedHostKeys = nil
        self.isFavorite = isFavorite
        self.colorTag = colorTag
        self.dateAdded = Date()
        self.lastConnected = nil
        self.tags = tags
        self.jumpHostID = jumpHostID
        self.jumpHostIDs = jumpHostIDs

        // Defaults
        self.compression = false
        self.keepAliveInterval = 60
        self.serverAliveCountMax = 3
        self.forwardAgent = false
        self.allowLegacyAlgorithms = false
        self.requestPTY = true
        self.terminalType = "xterm-256color"
        self.environmentVariables = [:]
    }

    var legacyAlgorithmsEnabled: Bool {
        allowLegacyAlgorithms == true
    }
}

enum ServerColorTag: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, cyan, gray
    
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .cyan: return .cyan
        case .gray: return .gray
        }
    }
}

// MARK: - Terminal Session

enum HostKeyChallengeReason: String, Codable {
    case unknown
    case changed
}

struct HostKeyTrustChallenge: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let algorithm: String
    let fingerprintSHA256: String
    let keyDataBase64: String
    let reason: HostKeyChallengeReason

    var summary: String {
        switch reason {
        case .unknown:
            return "This is the first time connecting to \(host):\(port)."
        case .changed:
            return "The server key for \(host):\(port) has changed."
        }
    }
}

struct HostKeyTrustRequiredError: Error {
    let challenge: HostKeyTrustChallenge
}

/// Per-connection challenge handoff for SSH libraries that wrap delegate errors.
/// Avoiding global endpoint state prevents concurrent sessions from accepting
/// one another's fingerprints.
nonisolated final class HostKeyChallengeBox: Sendable {
    private let value = OSAllocatedUnfairLock<HostKeyTrustChallenge?>(initialState: nil)

    func store(_ challenge: HostKeyTrustChallenge) {
        value.withLock { $0 = challenge }
    }

    func take() -> HostKeyTrustChallenge? {
        value.withLock {
            defer { $0 = nil }
            return $0
        }
    }

    func clear() {
        value.withLock { $0 = nil }
    }
}

final class PromptingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let trustedKeyBase64Set: Set<String>
    private let verificationMode: HostKeyVerificationMode
    private let challengeBox: HostKeyChallengeBox

    init(
        host: String,
        port: Int,
        trustedKeyBase64Set: Set<String>,
        verificationMode: HostKeyVerificationMode,
        challengeBox: HostKeyChallengeBox
    ) {
        self.host = host
        self.port = port
        self.trustedKeyBase64Set = trustedKeyBase64Set
        self.verificationMode = verificationMode
        self.challengeBox = challengeBox
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let challenge = Self.challenge(from: hostKey, host: host, port: port, trustedKeyBase64Set: trustedKeyBase64Set)
        challengeBox.store(challenge)

        if trustedKeyBase64Set.contains(challenge.keyDataBase64) {
            challengeBox.clear()
            validationCompletePromise.succeed(())
            return
        }

        switch verificationMode {
        case .ask, .strict:
            validationCompletePromise.fail(HostKeyTrustRequiredError(challenge: challenge))
        }
    }

    private static func challenge(
        from hostKey: NIOSSHPublicKey,
        host: String,
        port: Int,
        trustedKeyBase64Set: Set<String>
    ) -> HostKeyTrustChallenge {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        _ = hostKey.write(to: &buffer)
        let keyData = Data(buffer.readableBytesView)
        let keyDataBase64 = keyData.base64EncodedString()
        let algorithm = hostKeyAlgorithm(fromWireData: keyData)
        let fingerprintSHA256 = sha256Base64(of: keyData)
        let reason: HostKeyChallengeReason = trustedKeyBase64Set.isEmpty ? .unknown : .changed

        return HostKeyTrustChallenge(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprintSHA256: fingerprintSHA256,
            keyDataBase64: keyDataBase64,
            reason: reason
        )
    }

    private static func hostKeyAlgorithm(fromWireData data: Data) -> String {
        guard data.count >= 4 else { return "unknown" }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, data.count >= 4 + length else { return "unknown" }
        return String(data: data[4..<(4 + length)], encoding: .utf8) ?? "unknown"
    }

    private static func sha256Base64(of data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
        #else
        return data.base64EncodedString()
        #endif
    }
}

enum SessionAuthenticationMaterial {
    case password(SecureBytes)
    case sshKey(SSHKeyMaterial)
}

struct PreparedServerAuthentication {
    let serverID: UUID
    let material: SessionAuthenticationMaterial
}

struct SessionConnectionPreparation {
    let target: PreparedServerAuthentication
    let jumpHosts: [PreparedServerAuthentication]
}

enum TerminalSessionLifecycleTransition: CaseIterable, Sendable {
    case manualReconnect
    case automaticReconnect
    case explicitDisconnect
    case cleanRemoteExit
    case terminalError
}

@MainActor
@Observable
class TerminalSession: Identifiable, Hashable {
    typealias TerminalWriteSink = @MainActor (Data) async throws -> Void
    typealias TerminalResizeSink = @MainActor (_ rows: Int, _ columns: Int) async throws -> Void
    typealias LifecycleHook = @MainActor (TerminalSessionLifecycleTransition) -> Task<Void, Never>?

    private struct PendingTerminalWrite {
        let data: Data
        let presentsFailure: Bool
    }

    let id: UUID
    var server: ServerConfiguration
    
    var state: SessionState = .disconnected
    var output: [TerminalLine] = []
    var terminalInputNonce: UInt64 = 0
    var closeWindowNonce: UInt64 = 0
    var currentDirectory: String = "~"
    var pendingHostKeyChallenge: HostKeyTrustChallenge?
    var lastConnectionDiagnostics: String?
    var connectionProgress: ConnectionProgressStage?
    
    // Terminal properties
    let maxScrollback: Int = 10000
    
    // Jump host chain (resolved before connect, ordered first-hop to last-hop)
    var jumpHostChain: [ServerConfiguration] = []
    var connectionPreparation: SessionConnectionPreparation?

    // SSH Connection
    private var sshConnection: SSHConnection?
    private var pendingTerminalOutput = Data()
    private var pendingTerminalInputChunks: [Data] = []
    private var terminalFlushTask: Task<Void, Never>?
    private var terminalFlushGeneration: UInt64 = 0
    private let terminalFlushInterval: Duration = .milliseconds(8)
    private let terminalWriteSink: TerminalWriteSink?
    private var pendingTerminalWrites: [PendingTerminalWrite] = []
    private var terminalWriteTask: Task<Void, Never>?
    private var terminalWriteGeneration: UInt64 = 0
    private let terminalResizeSink: TerminalResizeSink?
    private var pendingTerminalResize: (rows: Int, columns: Int)?
    private var terminalResizeTask: Task<Void, Never>?
    private var terminalResizeGeneration: UInt64 = 0
    private var latestTerminalRows: Int = 40
    private var latestTerminalColumns: Int = 140
    private var userInitiatedDisconnect: Bool = false
    private var reconnectTask: Task<Void, Never>?
    var reconnectAttemptCount: Int = 0
    var recorder: SessionRecorder?
    var reconnectPreparation: ((ServerConfiguration) async throws -> SessionConnectionPreparation)?
    var automaticReconnectSucceeded: (() -> Void)?
    private var lifecycleHook: LifecycleHook?
    private var lifecycleCleanupPerformed = false
    private var lifecycleCleanupTask: Task<Void, Never>?

    init(
        server: ServerConfiguration,
        terminalWriteSink: TerminalWriteSink? = nil,
        terminalResizeSink: TerminalResizeSink? = nil
    ) {
        self.id = UUID()
        self.server = server
        self.terminalWriteSink = terminalWriteSink
        self.terminalResizeSink = terminalResizeSink
        let connection = SSHConnection(session: self)
        connection.setPreferredTerminalSize(
            rows: latestTerminalRows,
            columns: latestTerminalColumns
        )
        self.sshConnection = connection
    }

    isolated deinit {
        terminalFlushTask?.cancel()
        terminalWriteTask?.cancel()
        terminalResizeTask?.cancel()
        reconnectTask?.cancel()
    }

    func getSSHConnection() -> SSHConnection? { sshConnection }

    func installLifecycleHook(_ hook: @escaping LifecycleHook) {
        lifecycleHook = hook
    }

    /// Runs once for each attached SSH connection. Repeated terminal errors,
    /// reconnect signals, and close requests for the same transport are harmless.
    func performLifecycleCleanup(for transition: TerminalSessionLifecycleTransition) {
        guard !lifecycleCleanupPerformed else { return }
        lifecycleCleanupPerformed = true
        lifecycleCleanupTask = lifecycleHook?(transition)
    }

    func awaitLifecycleCleanup() async {
        await lifecycleCleanupTask?.value
    }

    /// Extends the current resource cleanup so callers awaiting the lifecycle
    /// boundary also wait for the detached SSH transport to close. This is used
    /// by synchronous error callbacks that cannot themselves `await`.
    private func appendTransportDisconnectToLifecycleCleanup(_ connection: SSHConnection?) {
        let resourceCleanup = lifecycleCleanupTask
        lifecycleCleanupTask = Task {
            await resourceCleanup?.value
            await connection?.disconnect()
        }
    }

    /// The sole boundary for detaching an SSH connection. Session-owned
    /// resources are stopped before callers can disconnect or replace it.
    func detachSSHConnection(for transition: TerminalSessionLifecycleTransition) -> SSHConnection? {
        performLifecycleCleanup(for: transition)
        let detachedConnection = sshConnection
        sshConnection = nil
        return detachedConnection
    }

    // Hashable conformance
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    func connect() async {
        userInitiatedDisconnect = false
        if state == .connecting {
            appendLine(TerminalLine(text: "Connection already in progress. Please wait…", style: .system))
            return
        }

        if state == .connected {
            appendLine(TerminalLine(text: "Already connected to \(server.name).", style: .system))
            return
        }

        if sshConnection == nil {
            sshConnection = makeConfiguredSSHConnection()
        }

        state = .connecting
        connectionProgress = .resolvingDNS
        lastConnectionDiagnostics = nil
        appendLine(TerminalLine(text: "Connecting to \(server.name)...", style: .system))
        
        do {
            guard let connectionPreparation else {
                throw SSHError.invalidCredentialPreparation
            }
            self.connectionPreparation = nil
            try await sshConnection?.connect(
                preparation: connectionPreparation,
                jumpHostChain: jumpHostChain
            )
            pendingHostKeyChallenge = nil
            connectionProgress = nil
            lastConnectionDiagnostics = nil
            state = .connected
            lifecycleCleanupPerformed = false
            appendLine(TerminalLine(text: "✓ Connected to \(server.username)@\(server.host)", style: .system))
        } catch {
            if let challengeError = error as? HostKeyTrustRequiredError {
                pendingHostKeyChallenge = challengeError.challenge
            } else if let cachedChallenge = sshConnection?.takePendingHostKeyChallenge() {
                pendingHostKeyChallenge = cachedChallenge
            }
            let failedConnection = detachSSHConnection(for: .terminalError)
            let mode = HostKeyVerificationMode(
                rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.hostKeyVerificationMode) ?? ""
            ) ?? .ask
            let message: String
            if let challenge = pendingHostKeyChallenge {
                switch mode {
                case .ask:
                    message = "Host key verification required for \(challenge.host):\(challenge.port)."
                case .strict:
                    message = "Strict host-key verification blocked the connection to \(challenge.host):\(challenge.port)."
                }
            } else {
                message = SSHConnection.userFacingMessage(for: error, server: server)
            }
            Logger.ssh.error(
                "SSH connect error (\(self.server.host):\(self.server.port)); category=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            lastConnectionDiagnostics =
                "Attempted: \(server.host):\(server.port)\nAuth method: \(server.authMethod.displayName)\nHost key mode: \(mode.rawValue)\nFailure category: \(String(reflecting: type(of: error)))"
            connectionProgress = nil
            state = .error(message)
            recorder?.finalize()
            appendLine(TerminalLine(text: "✗ \(message)", style: .error))
            await awaitLifecycleCleanup()
            await failedConnection?.disconnect()
        }
    }
    
    func disconnect() {
        userInitiatedDisconnect = true
        flushPendingTerminalOutputNow()
        cancelPendingTerminalWrites()
        cancelPendingTerminalResizes()
        recorder?.finalize()
        reconnectTask?.cancel()
        reconnectTask = nil
        let connectionToDisconnect = detachSSHConnection(for: .explicitDisconnect)
        connectionProgress = nil
        state = .disconnected
        Task {
            await self.awaitLifecycleCleanup()
            await connectionToDisconnect?.disconnect()
        }
    }

    func reconnect() async {
        state = .reconnecting
        flushPendingTerminalOutputNow()
        cancelPendingTerminalWrites()
        cancelPendingTerminalResizes()
        recorder?.finalize()
        reconnectTask?.cancel()
        reconnectTask = nil
        let connectionToDisconnect = detachSSHConnection(for: .manualReconnect)
        await awaitLifecycleCleanup()
        await connectionToDisconnect?.disconnect()
        sshConnection = makeConfiguredSSHConnection()
        connectionProgress = nil
        state = .disconnected
        await connect()
    }

    func attemptAutoReconnect(autoReconnectEnabled: Bool) {
        guard autoReconnectEnabled,
              !userInitiatedDisconnect
        else { return }

        reconnectTask?.cancel()
        flushPendingTerminalOutputNow()
        cancelPendingTerminalWrites()
        cancelPendingTerminalResizes()
        reconnectAttemptCount = 0
        state = .reconnecting
        appendLine(TerminalLine(text: "Connection lost. Auto-reconnecting...", style: .system))
        let initialConnection = detachSSHConnection(for: .automaticReconnect)

        reconnectTask = Task { [weak self] in
            let maxAttempts = 5
            var connectionToDisconnect = initialConnection

            for attempt in 1...maxAttempts {
                guard !Task.isCancelled, let self else { return }

                await self.awaitLifecycleCleanup()
                await connectionToDisconnect?.disconnect()
                connectionToDisconnect = nil

                self.reconnectAttemptCount = attempt
                let delay = min(UInt64(pow(2.0, Double(attempt - 1))), 30)
                self.appendLine(TerminalLine(
                    text: "Reconnect attempt \(attempt)/\(maxAttempts) in \(delay)s...",
                    style: .system
                ))

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch { return }

                guard !Task.isCancelled else { return }

                let preparation: SessionConnectionPreparation
                do {
                    guard let reconnectPreparation = self.reconnectPreparation else {
                        throw SSHError.invalidCredentialPreparation
                    }
                    preparation = try await reconnectPreparation(self.server)
                } catch {
                    self.state = .error(error.localizedDescription)
                    self.appendLine(TerminalLine(text: "Auto-reconnect blocked: \(error.localizedDescription)", style: .error))
                    self.reconnectTask = nil
                    return
                }

                guard !Task.isCancelled else { return }
                self.connectionPreparation = preparation
                self.sshConnection = self.makeConfiguredSSHConnection()
                await self.connect()

                if self.state == .connected {
                    self.appendLine(TerminalLine(text: "Reconnected successfully.", style: .system))
                    self.reconnectTask = nil
                    self.automaticReconnectSucceeded?()
                    return
                }

                if attempt < maxAttempts {
                    connectionToDisconnect = self.sshConnection
                    self.sshConnection = nil
                    self.cancelPendingTerminalWrites()
                    self.cancelPendingTerminalResizes()
                    self.state = .reconnecting
                }
            }

            guard let self, !Task.isCancelled else { return }
            let failedConnection = self.sshConnection
            self.sshConnection = nil
            await failedConnection?.disconnect()
            self.state = .error("Reconnect failed after 5 attempts")
            self.appendLine(TerminalLine(text: "Auto-reconnect failed after 5 attempts.", style: .error))
            self.reconnectTask = nil
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptCount = 0
        if state == .reconnecting {
            state = .disconnected
            appendLine(TerminalLine(text: "Auto-reconnect cancelled.", style: .system))
        }
    }
    
    func sendCommand(_ command: String) {
        guard state == .connected else {
            appendLine(TerminalLine(text: "Error: terminal is not connected.", style: .error))
            return
        }
        let data = Data((command + "\n").utf8)
        // Generated commands, suggested fixes, and snippets share the exact
        // same consented input-recording path as keyboard bytes.
        recorder?.recordInput(data)
        enqueueTerminalWrite(data, presentsFailure: true)
    }
    
    func sendTerminalData(_ data: Data) {
        guard state == .connected else {
            Logger.ssh.debug("Ignoring terminal input while session is not connected")
            return
        }
        recorder?.recordInput(data)
        enqueueTerminalWrite(data, presentsFailure: false)
    }

    func handleCleanRemoteExit() {
        let connectionToDisconnect = detachSSHConnection(for: .cleanRemoteExit)
        flushPendingTerminalOutputNow()
        cancelPendingTerminalWrites()
        cancelPendingTerminalResizes()
        recorder?.finalize()
        connectionProgress = nil
        state = .disconnected
        closeWindowNonce &+= 1
        Task {
            await self.awaitLifecycleCleanup()
            await connectionToDisconnect?.disconnect()
        }
    }
    
    func appendLine(_ line: TerminalLine) {
        output.append(line)
        
        // Manage scrollback
        if output.count > maxScrollback {
            let excess = output.count - maxScrollback
            output.removeFirst(excess)
        }
    }
    
    func clearScreen() {
        let clearSequence = "\u{1b}[2J\u{1b}[H"
        // Preserve bytes that arrived immediately before the user's clear
        // action. SwiftTerm must observe them before the clear sequence so the
        // transport boundary never silently discards remote output.
        flushPendingTerminalOutputNow()
        if let clearData = clearSequence.data(using: .utf8) {
            emitTerminalChunk(clearData)
        }
        output.removeAll()
    }
    
    func searchOutput(_ query: String) -> [Int] {
        output.enumerated().compactMap { index, line in
            line.text.localizedCaseInsensitiveContains(query) ? index : nil
        }
    }

    func reportError(_ message: String) {
        let failedConnection = detachSSHConnection(for: .terminalError)
        appendTransportDisconnectToLifecycleCleanup(failedConnection)
        flushPendingTerminalOutputNow()
        cancelPendingTerminalWrites()
        cancelPendingTerminalResizes()
        recorder?.finalize()
        connectionProgress = nil
        state = .error(message)
        appendLine(TerminalLine(text: "✗ \(message)", style: .error))
    }

    func setConnectionProgress(_ progress: ConnectionProgressStage?) {
        connectionProgress = progress
    }
    
    func feedTerminalData(_ data: Data) {
        pendingTerminalOutput.append(data)
        recorder?.recordOutput(data)
        scheduleTerminalFlush()
    }
    
    func updateTerminalGeometry(rows: Int, columns: Int) {
        let clampedRows = max(8, rows)
        let clampedColumns = max(20, columns)
        latestTerminalRows = clampedRows
        latestTerminalColumns = clampedColumns
        recorder?.recordResize(width: clampedColumns, height: clampedRows)

        sshConnection?.setPreferredTerminalSize(rows: clampedRows, columns: clampedColumns)

        guard state == .connected else { return }
        pendingTerminalResize = (rows: clampedRows, columns: clampedColumns)
        scheduleTerminalResizeDrainIfNeeded()
    }

    func drainTerminalInputChunks() -> [Data] {
        guard !pendingTerminalInputChunks.isEmpty else { return [] }
        let chunks = pendingTerminalInputChunks
        pendingTerminalInputChunks.removeAll(keepingCapacity: true)
        return chunks
    }

    private func emitTerminalChunk(_ data: Data) {
        pendingTerminalInputChunks.append(data)
        terminalInputNonce &+= 1
    }

    private func scheduleTerminalFlush() {
        guard terminalFlushTask == nil else { return }
        let generation = terminalFlushGeneration
        terminalFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.terminalFlushInterval)
            } catch {
                return
            }
            guard generation == self.terminalFlushGeneration else { return }
            self.flushPendingTerminalOutput()
            self.terminalFlushTask = nil
            if !self.pendingTerminalOutput.isEmpty {
                self.scheduleTerminalFlush()
            }
        }
    }

    private func flushPendingTerminalOutput() {
        guard !pendingTerminalOutput.isEmpty else { return }
        let chunk = pendingTerminalOutput
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        emitTerminalChunk(chunk)
    }

    private func flushPendingTerminalOutputNow() {
        terminalFlushGeneration &+= 1
        terminalFlushTask?.cancel()
        terminalFlushTask = nil
        flushPendingTerminalOutput()
    }

    private func enqueueTerminalWrite(_ data: Data, presentsFailure: Bool) {
        guard !data.isEmpty else { return }
        pendingTerminalWrites.append(PendingTerminalWrite(
            data: data,
            presentsFailure: presentsFailure
        ))
        scheduleTerminalWriteDrainIfNeeded()
    }

    private func scheduleTerminalWriteDrainIfNeeded() {
        guard terminalWriteTask == nil, !pendingTerminalWrites.isEmpty else { return }
        let generation = terminalWriteGeneration
        terminalWriteTask = Task { @MainActor [weak self] in
            await self?.drainTerminalWrites(generation: generation)
        }
    }

    private func drainTerminalWrites(generation: UInt64) async {
        while generation == terminalWriteGeneration,
              !Task.isCancelled,
              !pendingTerminalWrites.isEmpty {
            let write = pendingTerminalWrites.removeFirst()
            do {
                if let terminalWriteSink {
                    try await terminalWriteSink(write.data)
                } else if let sshConnection {
                    // Capture the current connection for this write. A
                    // reconnect cancels this generation before replacing it,
                    // so queued bytes can never leak into the next session.
                    try await sshConnection.sendBytes(write.data)
                } else {
                    throw SSHError.notConnected
                }
            } catch {
                guard generation == terminalWriteGeneration, !Task.isCancelled else { return }
                let presentsFailure = write.presentsFailure
                    || pendingTerminalWrites.contains(where: \.presentsFailure)
                pendingTerminalWrites.removeAll(keepingCapacity: true)
                if presentsFailure {
                    appendLine(TerminalLine(
                        text: "Error: \(error.localizedDescription)",
                        style: .error
                    ))
                } else {
                    Logger.ssh.error("Error sending terminal data: \(error)")
                }
                break
            }
        }

        guard generation == terminalWriteGeneration else { return }
        terminalWriteTask = nil
        scheduleTerminalWriteDrainIfNeeded()
    }

    private func cancelPendingTerminalWrites() {
        terminalWriteGeneration &+= 1
        terminalWriteTask?.cancel()
        terminalWriteTask = nil
        pendingTerminalWrites.removeAll(keepingCapacity: true)
    }

    /// Deterministic test/automation seam for ordering-sensitive input paths.
    func waitUntilTerminalWritesComplete() async {
        while let task = terminalWriteTask {
            await task.value
        }
    }

    private func scheduleTerminalResizeDrainIfNeeded() {
        guard terminalResizeTask == nil, pendingTerminalResize != nil else { return }
        let generation = terminalResizeGeneration
        terminalResizeTask = Task { @MainActor [weak self] in
            await self?.drainTerminalResizes(generation: generation)
        }
    }

    private func drainTerminalResizes(generation: UInt64) async {
        while generation == terminalResizeGeneration,
              !Task.isCancelled,
              let resize = pendingTerminalResize {
            // Clear before awaiting. Geometry changes that arrive while this
            // resize is in flight replace this value, so the next iteration
            // sends only the newest dimensions.
            pendingTerminalResize = nil
            do {
                if let terminalResizeSink {
                    try await terminalResizeSink(resize.rows, resize.columns)
                } else if let sshConnection {
                    try await sshConnection.resizeTerminal(
                        rows: resize.rows,
                        columns: resize.columns
                    )
                } else {
                    throw SSHError.notConnected
                }
            } catch {
                guard generation == terminalResizeGeneration, !Task.isCancelled else { return }
                Logger.ssh.error("Failed to resize remote PTY: \(error)")
            }
        }

        guard generation == terminalResizeGeneration else { return }
        terminalResizeTask = nil
        scheduleTerminalResizeDrainIfNeeded()
    }

    private func cancelPendingTerminalResizes() {
        terminalResizeGeneration &+= 1
        terminalResizeTask?.cancel()
        terminalResizeTask = nil
        pendingTerminalResize = nil
    }

    /// Deterministic test/automation seam for resize coalescing.
    func waitUntilTerminalResizesComplete() async {
        while let task = terminalResizeTask {
            await task.value
        }
    }

    private func makeConfiguredSSHConnection() -> SSHConnection {
        let connection = SSHConnection(session: self)
        connection.setPreferredTerminalSize(
            rows: latestTerminalRows,
            columns: latestTerminalColumns
        )
        return connection
    }
}

enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
    
    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting..."
        case .error(let message): return "Error: \(message)"
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting: return "circle.dotted"
        case .connected: return "circle.fill"
        case .reconnecting: return "arrow.clockwise.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .reconnecting: return .yellow
        case .error: return .red
        }
    }
}

enum ConnectionProgressStage: Equatable {
    case resolvingDNS
    case openingSocket(port: Int)
    case negotiatingSecurity
    case negotiatingCompatibility
    case authenticating
    case startingShell

    var tickerLabel: String {
        switch self {
        case .resolvingDNS:
            return "DNS"
        case .openingSocket(let port):
            return "Connecting:\(port)"
        case .negotiatingSecurity:
            return "Negotiating"
        case .negotiatingCompatibility:
            return "Negotiating (Legacy)"
        case .authenticating:
            return "Authenticating"
        case .startingShell:
            return "Starting shell"
        }
    }

    static let orderedFlow: [ConnectionProgressStage] = [
        .resolvingDNS,
        .openingSocket(port: 22),
        .negotiatingSecurity,
        .authenticating,
        .startingShell
    ]

    var flowIndex: Int {
        switch self {
        case .resolvingDNS: return 0
        case .openingSocket: return 1
        case .negotiatingSecurity, .negotiatingCompatibility: return 2
        case .authenticating: return 3
        case .startingShell: return 4
        }
    }
}

struct TerminalLine: Identifiable {
    let id = UUID()
    let text: String
    let style: LineStyle
    let timestamp: Date = Date()
    
    enum LineStyle {
        case output
        case input
        case error
        case system
        case prompt
    }
}

// MARK: - Port Forwarding

enum TunnelStatus: String, Codable {
    case inactive
    case starting
    case active
    case error
    case stopping
}

struct PortForward: Identifiable, Codable {
    let id: UUID
    var type: ForwardType
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var status: TunnelStatus = .inactive
    var errorMessage: String?
    let dateCreated: Date

    var isActive: Bool { status == .active || status == .starting }
    
    enum ForwardType: String, Codable {
        case local // -L
        case remote // -R
        case dynamic // -D
        
        var displayName: String {
            switch self {
            case .local: return "Local"
            case .remote: return "Remote"
            case .dynamic: return "Dynamic (SOCKS)"
            }
        }
        
        var description: String {
            switch self {
            case .local: return "Forward local port to remote"
            case .remote: return "Forward remote port to local"
            case .dynamic: return "SOCKS proxy on local port"
            }
        }
    }
    
    init(
        id: UUID = UUID(),
        type: ForwardType,
        localPort: Int,
        remoteHost: String = "localhost",
        remotePort: Int
    ) {
        self.id = id
        self.type = type
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.status = .inactive
        self.dateCreated = Date()
    }
    
    var displayString: String {
        switch type {
        case .local:
            return "localhost:\(localPort) → \(remoteHost):\(remotePort)"
        case .remote:
            return "\(remoteHost):\(remotePort) → localhost:\(localPort)"
        case .dynamic:
            return "SOCKS proxy on localhost:\(localPort)"
        }
    }
}

// MARK: - HTML Preview

#if DEBUG
struct HTMLPreviewContext: Identifiable, Hashable, Codable {
    let id: UUID
    let sessionID: UUID
    let url: String
    let autoReload: Bool
    let reloadInterval: TimeInterval
    
    init(
        id: UUID = UUID(),
        sessionID: UUID,
        url: String,
        autoReload: Bool = true,
        reloadInterval: TimeInterval = 2.0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.url = url
        self.autoReload = autoReload
        self.reloadInterval = reloadInterval
    }
}
#endif

// MARK: - SFTP Browser

struct SFTPBrowserContext: Codable, Hashable {
    let sessionID: UUID
}

// MARK: - Snippets

struct CommandSnippet: Identifiable, Codable {
    let id: UUID
    var name: String
    var command: String
    var description: String
    var tags: [String]
    let dateCreated: Date
    var lastUsed: Date?
    var useCount: Int
    
    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        description: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.description = description
        self.tags = tags
        self.dateCreated = Date()
        self.lastUsed = nil
        self.useCount = 0
    }
}

// MARK: - Terminal Theme

struct TerminalTheme: Identifiable, Codable {
    let id: UUID
    var name: String
    var background: CodableColor
    var foreground: CodableColor
    var cursor: CodableColor
    var selection: CodableColor
    
    // ANSI colors
    var black: CodableColor
    var red: CodableColor
    var green: CodableColor
    var yellow: CodableColor
    var blue: CodableColor
    var magenta: CodableColor
    var cyan: CodableColor
    var white: CodableColor
    
    // Bright variants
    var brightBlack: CodableColor
    var brightRed: CodableColor
    var brightGreen: CodableColor
    var brightYellow: CodableColor
    var brightBlue: CodableColor
    var brightMagenta: CodableColor
    var brightCyan: CodableColor
    var brightWhite: CodableColor
    
    var fontName: String
    var fontSize: CGFloat
    
    static let `default` = TerminalTheme(
        id: UUID(),
        name: "Glass Terminal",
        background: CodableColor(color: Color.black.opacity(0.3)),
        foreground: CodableColor(color: .white),
        cursor: CodableColor(color: .green),
        selection: CodableColor(color: Color.blue.opacity(0.3)),
        black: CodableColor(color: .black),
        red: CodableColor(color: .red),
        green: CodableColor(color: .green),
        yellow: CodableColor(color: .yellow),
        blue: CodableColor(color: .blue),
        magenta: CodableColor(color: .purple),
        cyan: CodableColor(color: .cyan),
        white: CodableColor(color: .white),
        brightBlack: CodableColor(color: .gray),
        brightRed: CodableColor(color: .red),
        brightGreen: CodableColor(color: .green),
        brightYellow: CodableColor(color: .yellow),
        brightBlue: CodableColor(color: .blue),
        brightMagenta: CodableColor(color: .purple),
        brightCyan: CodableColor(color: .cyan),
        brightWhite: CodableColor(color: .white),
        fontName: "SF Mono",
        fontSize: 14
    )
}

// Helper for encoding/decoding Color
struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
    
    init(color: Color) {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let components = color.cgColor?
            .converted(to: sRGB, intent: .defaultIntent, options: nil)?
            .components ?? [0, 0, 0, 1]
        self.red = components[0]
        self.green = components.count > 1 ? components[1] : components[0]
        self.blue = components.count > 2 ? components[2] : components[0]
        self.alpha = components.last ?? 1.0
    }
}
// MARK: - SSH Connection

/// Handles actual SSH connection and terminal session
@MainActor
class SSHConnection {
    private var client: SSHClient?
    private var jumpClients: [SSHClient] = []
    private var ttyWriter: TTYStdinWriter?
    private var ttyTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var missedKeepAlives: Int = 0
    private var terminalRows: Int = 40
    private var terminalColumns: Int = 140
    private let hostKeyChallengeBox = HostKeyChallengeBox()

    weak var session: TerminalSession?
    
    init(session: TerminalSession) {
        self.session = session
    }

    nonisolated static func preferredPTYTerminalModes() -> SSHTerminalModes {
        SSHTerminalModes([
            // Keep shell line behavior intact while ensuring CR isn't rewritten to NL.
            .OCRNL: 0
        ])
    }

    func setPreferredTerminalSize(rows: Int, columns: Int) {
        terminalRows = max(8, rows)
        terminalColumns = max(20, columns)
    }

    nonisolated func takePendingHostKeyChallenge() -> HostKeyTrustChallenge? {
        hostKeyChallengeBox.take()
    }
    
    /// Resolve SSH authentication method for a given server configuration.
    /// Reused for both direct connections and jump host connections.
    static func resolveAuthMethod(
        for server: ServerConfiguration,
        authentication: PreparedServerAuthentication
    ) throws -> SSHAuthenticationMethod {
        guard authentication.serverID == server.id else {
            throw SSHError.invalidCredentialPreparation
        }
        switch server.authMethod {
        case .password:
            guard case .password(let password) = authentication.material else {
                throw SSHError.invalidCredentialPreparation
            }
            guard let decodedPassword = password.toUTF8String() else {
                throw SSHError.invalidCredentialEncoding
            }
            return .passwordBased(username: server.username, password: decodedPassword)

        case .sshKey:
            guard server.sshKeyID != nil,
                  case .sshKey(let keyMaterial) = authentication.material else {
                throw SSHError.invalidCredentialPreparation
            }
            do {
                guard let privateKeyString = keyMaterial.privateKey.toUTF8String() else {
                    throw SSHError.invalidCredentialEncoding
                }
                let passphraseData = keyMaterial.passphrase?.toData()

                if privateKeyString.hasPrefix("TRUE_SE_P256:") {
                    // True Secure Enclave key — signing happens in hardware
                    let payload = String(privateKeyString.dropFirst("TRUE_SE_P256:".count))
                    guard let dataRep = Data(base64Encoded: payload) else {
                        throw SSHError.invalidSSHKey("Invalid true Secure Enclave P-256 data representation.")
                    }
                    let seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRep)
                    return .secureEnclaveP256(username: server.username, privateKey: seKey)
                } else if privateKeyString.hasPrefix("SECURE_ENCLAVE_P256:") {
                    // Legacy wrapped Secure Enclave key — backward compatible
                    let payload = String(privateKeyString.dropFirst("SECURE_ENCLAVE_P256:".count))
                    guard let rawData = Data(base64Encoded: payload) else {
                        throw SSHError.invalidSSHKey("Invalid Secure Enclave P-256 payload.")
                    }
                    let key = try P256.Signing.PrivateKey(rawRepresentation: rawData)
                    return .p256(username: server.username, privateKey: key)
                } else {
                    let keyType = try SSHKeyDetection.detectPrivateKeyType(from: privateKeyString)
                    switch keyType {
                    case .rsa:
                        let key = try Insecure.RSA.PrivateKey(sshRsa: privateKeyString, decryptionKey: passphraseData)
                        return .rsa(username: server.username, privateKey: key)
                    case .ed25519:
                        let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKeyString, decryptionKey: passphraseData)
                        return .ed25519(username: server.username, privateKey: key)
                    default:
                        throw SSHError.unsupportedSSHKeyType(keyType.description)
                    }
                }
            } catch let error as SSHError {
                throw error
            } catch {
                throw SSHError.invalidSSHKey("The stored key material could not be decoded.")
            }

        case .agent:
            throw SSHError.unsupportedAuthMethod("SSH Agent authentication is unavailable in this release.")
        }
    }

    /// Build an SSHHostKeyValidator for a given server configuration.
    private static func resolveHostKeyValidator(
        for server: ServerConfiguration,
        normalizedHost: String,
        challengeBox: HostKeyChallengeBox
    ) throws -> SSHHostKeyValidator {
        let mode = hostKeyVerificationMode()
        let trustedSet = try trustedHostKeyBase64Set(server: server, host: normalizedHost, port: server.port)
        return .custom(
            PromptingHostKeyValidator(
                host: normalizedHost,
                port: server.port,
                trustedKeyBase64Set: trustedSet,
                verificationMode: mode,
                challengeBox: challengeBox
            )
        )
    }

    /// Connect to an SSH server with retry for legacy kex algorithms.
    private static func connectWithFallback(
        host: String,
        port: Int,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        allowLegacyAlgorithms: Bool,
        session: TerminalSession?
    ) async throws -> SSHClient {
        do {
            return try await connectClient(
                host: host,
                port: port,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: hostKeyValidator,
                algorithms: SSHAlgorithms()
            )
        } catch {
            if shouldRetryWithLegacyAlgorithms(error, enabled: allowLegacyAlgorithms) {
                session?.setConnectionProgress(.negotiatingCompatibility)
                return try await connectClient(
                    host: host,
                    port: port,
                    authenticationMethod: authenticationMethod,
                    hostKeyValidator: hostKeyValidator,
                    algorithms: .all
                )
            } else {
                throw error
            }
        }
    }

    /// Connect to SSH server, optionally through a chain of jump hosts (ProxyJump)
    func connect(
        preparation: SessionConnectionPreparation,
        jumpHostChain: [ServerConfiguration] = []
    ) async throws {
        guard let session = session else { throw SSHError.sessionNotFound }
        let server = session.server
        let normalizedHost = Self.normalizedHost(server.host)
        guard !normalizedHost.isEmpty else {
            throw SSHError.invalidHost(server.host)
        }
        guard (1...65_535).contains(server.port) else {
            throw SSHError.invalidPort(server.port)
        }
        session.setConnectionProgress(.resolvingDNS)

        // Resolve target authentication method
        guard preparation.jumpHosts.count == jumpHostChain.count else {
            throw SSHError.invalidCredentialPreparation
        }
        let authMethod = try Self.resolveAuthMethod(
            for: server,
            authentication: preparation.target
        )
        hostKeyChallengeBox.clear()
        let hostKeyValidator = try Self.resolveHostKeyValidator(
            for: server,
            normalizedHost: normalizedHost,
            challengeBox: hostKeyChallengeBox
        )

        // Connect to SSH server using Citadel.
        // Try modern defaults first, then retry once with compatibility algorithms
        // for servers that still require older SSH kex/signature sets.
        session.setConnectionProgress(.openingSocket(port: server.port))
        session.setConnectionProgress(.negotiatingSecurity)

        if !jumpHostChain.isEmpty {
            // --- Jump Host Chain (multi-hop ProxyJump) path ---
            let firstHop = jumpHostChain[0]
            let firstHopHost = Self.normalizedHost(firstHop.host)
            guard !firstHopHost.isEmpty else {
                throw SSHError.invalidHost(firstHop.host)
            }
            guard (1...65_535).contains(firstHop.port) else {
                throw SSHError.invalidPort(firstHop.port)
            }

            let firstHopAuth = try Self.resolveAuthMethod(
                for: firstHop,
                authentication: preparation.jumpHosts[0]
            )
            let firstHopValidator = try Self.resolveHostKeyValidator(
                for: firstHop,
                normalizedHost: firstHopHost,
                challengeBox: hostKeyChallengeBox
            )

            session.appendLine(TerminalLine(
                text: "Connecting via jump host \(firstHop.name) (\(firstHop.host):\(firstHop.port))...",
                style: .system
            ))

            var establishedJumpClients: [SSHClient] = []
            do {
                // 1. Connect to the first jump host.
                var currentClient = try await Self.connectWithFallback(
                    host: firstHopHost,
                    port: firstHop.port,
                    authenticationMethod: firstHopAuth,
                    hostKeyValidator: firstHopValidator,
                    allowLegacyAlgorithms: firstHop.legacyAlgorithmsEnabled,
                    session: session
                )
                establishedJumpClients.append(currentClient)

                session.appendLine(TerminalLine(
                    text: "Hop 1/\(jumpHostChain.count) connected: \(firstHop.name)",
                    style: .system
                ))

                // 2. Jump through each subsequent hop in the chain. Retain
                // every parent client because closing only the final child
                // channel does not close the outer SSH transports.
                for (index, hopConfig) in jumpHostChain.dropFirst().enumerated() {
                    let hopHost = Self.normalizedHost(hopConfig.host)
                    guard !hopHost.isEmpty else {
                        throw SSHError.invalidHost(hopConfig.host)
                    }
                    guard (1...65_535).contains(hopConfig.port) else {
                        throw SSHError.invalidPort(hopConfig.port)
                    }

                    let hopAuth = try Self.resolveAuthMethod(
                        for: hopConfig,
                        authentication: preparation.jumpHosts[index + 1]
                    )
                    let hopValidator = try Self.resolveHostKeyValidator(
                        for: hopConfig,
                        normalizedHost: hopHost,
                        challengeBox: hostKeyChallengeBox
                    )

                    session.appendLine(TerminalLine(
                        text: "Jumping to hop \(index + 2)/\(jumpHostChain.count): \(hopConfig.name) (\(hopConfig.host):\(hopConfig.port))...",
                        style: .system
                    ))

                    let hopSettings = SSHClientSettings(
                        host: hopHost,
                        port: hopConfig.port,
                        authenticationMethod: { hopAuth },
                        hostKeyValidator: hopValidator
                    )
                    let nextClient = try await currentClient.jump(to: hopSettings)
                    establishedJumpClients.append(nextClient)
                    currentClient = nextClient

                    session.appendLine(TerminalLine(
                        text: "Hop \(index + 2)/\(jumpHostChain.count) connected: \(hopConfig.name)",
                        style: .system
                    ))
                }

                session.appendLine(TerminalLine(
                    text: "Tunneling to target \(server.host):\(server.port)...",
                    style: .system
                ))

                // 3. Jump through to the final target server, then transfer
                // ownership of the complete chain to this connection.
                let targetSettings = SSHClientSettings(
                    host: normalizedHost,
                    port: server.port,
                    authenticationMethod: { authMethod },
                    hostKeyValidator: hostKeyValidator
                )
                let targetClient = try await currentClient.jump(to: targetSettings)
                jumpClients = establishedJumpClients
                self.client = targetClient
            } catch {
                await closeClients(establishedJumpClients, context: "failed jump-host connection")
                throw error
            }
        } else {
            // --- Direct connection path ---
            self.client = try await Self.connectWithFallback(
                host: normalizedHost,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: hostKeyValidator,
                allowLegacyAlgorithms: server.legacyAlgorithmsEnabled,
                session: session
            )
        }
        session.setConnectionProgress(.authenticating)

        guard let client = self.client else {
            throw SSHError.connectionFailed
        }

        ttyTask = Task { [weak self] in
            await self?.runInteractiveTTY(client: client, server: server)
        }

        startKeepAliveTimer(
            client: client,
            interval: server.keepAliveInterval,
            maxMissed: server.serverAliveCountMax
        )
    }

    private func runInteractiveTTY(client: SSHClient, server: ServerConfiguration) async {
        await MainActor.run {
            self.session?.setConnectionProgress(.startingShell)
        }
        do {
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: server.terminalType,
                terminalCharacterWidth: terminalColumns,
                terminalRowHeight: terminalRows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: Self.preferredPTYTerminalModes()
            )
            var mergedEnv = server.environmentVariables
            if mergedEnv["TERM"] == nil {
                mergedEnv["TERM"] = server.terminalType
            }
            if mergedEnv["COLORTERM"] == nil {
                mergedEnv["COLORTERM"] = "truecolor"
            }

            let env = mergedEnv.map {
                SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: $0.key,
                    value: $0.value
                )
            }

            try await client.withPTY(pty, environment: env) { inbound, outbound in
                await MainActor.run {
                    self.ttyWriter = outbound
                }

                for try await output in inbound {
                    let buffer: ByteBuffer
                    switch output {
                    case .stdout(let out):
                        buffer = out
                    case .stderr(let err):
                        buffer = err
                    }

                    let data = Data(buffer.readableBytesView)
                    await MainActor.run {
                        self.resetKeepAliveCounter()
                        self.session?.feedTerminalData(data)
                    }
                }
            }
            await MainActor.run {
                self.session?.handleCleanRemoteExit()
            }
        } catch let channelError as ChannelError where channelError == .inputClosed || channelError == .outputClosed || channelError == .eof || channelError == .alreadyClosed {
            await MainActor.run {
                self.session?.handleCleanRemoteExit()
            }
        } catch is CancellationError {
            // Task cancelled during disconnect.
        } catch {
            if Self.isChannelClosedError(error) {
                await MainActor.run {
                    self.session?.handleCleanRemoteExit()
                }
                return
            }
            let message = Self.userFacingMessage(for: error, server: server)
            Logger.ssh.error("SSH stream error (\(server.host):\(server.port)): \(error)")
            await MainActor.run {
                if case .connected = self.session?.state {
                    self.session?.reportError(message)
                }
                let autoReconnect = UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoReconnect)
                self.session?.attemptAutoReconnect(autoReconnectEnabled: autoReconnect)
            }
        }
    }
    
    /// Send command to shell
    func sendCommand(_ command: String) async throws {
        guard client != nil else {
            throw SSHError.notConnected
        }

        try await sendInput(command + "\n")
    }
    
    /// Send raw input (for key presses, control characters, etc.)
    func sendInput(_ input: String) async throws {
        guard let writer = ttyWriter else {
            throw SSHError.notConnected
        }
        try await writer.write(ByteBuffer(string: input))
    }

    func sendBytes(_ data: Data) async throws {
        guard let writer = ttyWriter else {
            throw SSHError.notConnected
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }
    
    /// Open an SFTP subchannel over the existing SSH connection.
    func openSFTPClient() async throws -> SFTPClient {
        guard let client else { throw SSHError.notConnected }
        var sftpLogger = Logging.Logger(label: "sh.glas.sftp.private")
        // Citadel's info/debug messages include full remote paths and handles.
        // The app presents sanitized failures in its UI instead of persisting
        // potentially sensitive filesystem metadata to system logs.
        sftpLogger.logLevel = .error
        return try await client.openSFTP(logger: sftpLogger)
    }

    func executeRemoteCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let buffer = try await client.executeCommand(command)
        return String(buffer: buffer)
    }

    /// Create a direct-tcpip channel to reach a remote host:port through the SSH tunnel.
    func createDirectTCPIPChannel(targetHost: String, targetPort: Int) async throws -> Channel {
        guard let client else { throw SSHError.notConnected }
        return try await client.createDirectTCPIPChannel(
            using: .init(targetHost: targetHost, targetPort: targetPort,
                         originatorAddress: try .init(ipAddress: "127.0.0.1", port: 0)),
            initialize: { $0.eventLoop.makeSucceededVoidFuture() }
        )
    }

    /// Request remote port forwarding (-R) from the SSH server.
    ///
    /// The remote server listens on `remoteHost:remotePort` and forwards incoming
    /// connections back through the SSH tunnel to `localHost:localPort`.
    /// This method blocks until cancelled or the forward is torn down.
    func runRemotePortForward(
        remoteHost: String,
        remotePort: Int,
        localHost: String,
        localPort: Int,
        onOpen: @escaping @MainActor @Sendable (_ boundPort: Int) -> Void
    ) async throws {
        guard let client else { throw SSHError.notConnected }
        try await client.runRemotePortForward(
            host: remoteHost, port: remotePort,
            forwardingTo: localHost, port: localPort
        ) { remoteForward in
            await onOpen(remoteForward.boundPort)
            Logger.ssh.info("Remote port forward established: \(remoteHost):\(remoteForward.boundPort) -> \(localHost):\(localPort)")
        }
    }

    /// Disconnect from SSH server
    func disconnect() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        ttyTask?.cancel()
        ttyTask = nil
        ttyWriter = nil

        var clientsToClose: [SSHClient] = []
        if let client {
            clientsToClose.append(client)
        }
        clientsToClose.append(contentsOf: jumpClients.reversed())
        client = nil
        jumpClients.removeAll(keepingCapacity: false)
        await closeClientsInOrder(clientsToClose, context: "disconnect")
    }

    private func closeClients(_ clients: [SSHClient], context: String) async {
        await closeClientsInOrder(Array(clients.reversed()), context: context)
    }

    private func closeClientsInOrder(_ clients: [SSHClient], context: String) async {
        for client in clients {
            do {
                try await client.close()
            } catch {
                Logger.ssh.error("SSH client close failed during \(context); category=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Reset the missed-keepalive counter when we receive data from the server.
    func resetKeepAliveCounter() {
        missedKeepAlives = 0
    }

    private func startKeepAliveTimer(client: SSHClient, interval: Int, maxMissed: Int) {
        guard interval > 0 else { return }
        keepAliveTask?.cancel()
        missedKeepAlives = 0

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                do {
                    try await client.sendKeepAlive()
                    // sendKeepAlive succeeded — the TCP connection and SSH channel
                    // are still active. Reset the counter since the transport is healthy.
                    // The counter only climbs if sendKeepAlive throws (channel dead).
                    self.missedKeepAlives = 0
                    Logger.ssh.debug("Keepalive sent successfully")
                } catch {
                    self.missedKeepAlives += 1
                    Logger.ssh.debug("Keepalive failed (\(self.missedKeepAlives)/\(maxMissed)): \(error)")

                    if self.missedKeepAlives >= maxMissed {
                        Logger.ssh.warning("Server not responding after \(self.missedKeepAlives) failed keepalives — disconnecting")
                        self.session?.reportError("Connection timed out (server not responding)")
                        await self.disconnect()
                        let autoReconnect = UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoReconnect)
                        self.session?.attemptAutoReconnect(autoReconnectEnabled: autoReconnect)
                        break
                    }
                }
            }
        }
    }
    
    /// Resize terminal window
    func resizeTerminal(rows: Int, columns: Int) async throws {
        terminalRows = max(8, rows)
        terminalColumns = max(20, columns)

        guard let writer = ttyWriter else { return }
        try await writer.changeSize(
            cols: terminalColumns,
            rows: terminalRows,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    static func userFacingMessage(for error: Error, server: ServerConfiguration) -> String {
        if let trustError = error as? HostKeyTrustRequiredError {
            switch trustError.challenge.reason {
            case .unknown:
                return "First-time host key check for \(server.host):\(server.port). Review and trust the fingerprint to continue."
            case .changed:
                return "Warning: the host key changed for \(server.host):\(server.port). This may indicate a security risk."
            }
        }

        if let sshError = error as? SSHError {
            switch sshError {
            case .passwordRequired:
                return "A password is required for \(server.username)@\(server.host):\(server.port)."
            case .sshKeyNotFound:
                return "SSH key was not found. Check the key path in server settings."
            case .invalidCredentialPreparation:
                return "SSH credentials were not prepared for this connection. Start the connection again."
            case .invalidCredentialEncoding:
                return "The stored SSH credential is invalid or corrupt. Save or import it again."
            case .authenticationFailed:
                return "Authentication failed for \(server.username)@\(server.host):\(server.port)."
            case .invalidHost(let rawHost):
                return "The host \"\(rawHost)\" is not valid. Use a plain host name or IP (no protocol)."
            case .invalidPort(let port):
                return "The SSH port \(port) is not valid. Use a port from 1 through 65535."
            case .connectionFailed:
                return "Could not establish an SSH connection to \(server.host):\(server.port)."
            case .notConnected:
                return "Not connected to \(server.host):\(server.port)."
            case .sessionNotFound:
                return "The terminal session is no longer available."
            case .unsupportedSSHKeyType(let keyType):
                return "\(keyType). Supported key types are RSA, ED25519, and ECDSA P-256."
            case .unsupportedAuthMethod(let message):
                return message
            case .invalidSSHKey:
                return "The selected SSH key could not be parsed. Verify key contents and passphrase."
            }
        }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectPending:
                return "A connection to \(server.host):\(server.port) is already in progress."
            case .connectTimeout:
                return "Connection to \(server.host):\(server.port) timed out."
            case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof:
                return "The SSH channel to \(server.host):\(server.port) was closed."
            default:
                return "SSH channel error while connecting to \(server.host):\(server.port)."
            }
        }

        if isKeyExchangeNegotiationFailure(error) {
            return "SSH handshake failed: no shared security algorithm was found with \(server.host):\(server.port)."
        }

        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("allauthenticationoptionsfailed")
            || raw.localizedCaseInsensitiveContains("all authentication options failed")
        {
            if server.authMethod == .sshKey {
                return "SSH authentication was rejected by \(server.host):\(server.port). Verify username, ensure the matching public key is installed in authorized_keys, and confirm the server allows this key algorithm."
            }
            return "Authentication failed for \(server.username)@\(server.host):\(server.port). Verify credentials and server auth policy."
        }
        if raw.localizedCaseInsensitiveContains("authentication") {
            return "Authentication failed for \(server.username)@\(server.host):\(server.port)."
        }
        if raw.localizedCaseInsensitiveContains("timed out") {
            return "Connection to \(server.host):\(server.port) timed out."
        }
        if raw.localizedCaseInsensitiveContains("refused") {
            return "Connection refused by \(server.host):\(server.port). Verify SSH is running on that port."
        }
        if raw.localizedCaseInsensitiveContains("no route")
            || raw.localizedCaseInsensitiveContains("unreachable")
            || raw.localizedCaseInsensitiveContains("dns")
        {
            return "Could not reach \(server.host):\(server.port). Check network access and host name."
        }

        return "Could not connect to \(server.host):\(server.port)."
    }

    private static func hostKeyVerificationMode() -> HostKeyVerificationMode {
        guard
            let rawValue = UserDefaults.standard.string(forKey: UserDefaultsKeys.hostKeyVerificationMode),
            let mode = HostKeyVerificationMode(rawValue: rawValue)
        else {
            return .ask
        }
        return mode
    }

    private static func trustedHostKeyBase64Set(server _: ServerConfiguration, host: String, port: Int) throws -> Set<String> {
        do {
            return try KeychainManager.trustedHostKeyBase64Set(host: host, port: port)
        } catch {
            Logger.ssh.error(
                "Failed to read authoritative trusted host keys for \(host):\(port); category=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ssh://", with: "", options: [.caseInsensitive])
    }

    private static func connectClient(
        host: String,
        port: Int,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms
    ) async throws -> SSHClient {
        try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            reconnect: .never,
            algorithms: algorithms
        )
    }

    static func isKeyExchangeNegotiationFailure(_ error: Error) -> Bool {
        if let nioError = error as? NIOSSHError, nioError.type == .keyExchangeNegotiationFailure {
            return true
        }

        let raw = String(describing: error)
        return raw.localizedCaseInsensitiveContains("keyexchangenegotiationfailure")
            || raw.localizedCaseInsensitiveContains("key exchange negotiation failure")
    }

    static func shouldRetryWithLegacyAlgorithms(_ error: Error, enabled: Bool) -> Bool {
        enabled && isKeyExchangeNegotiationFailure(error)
    }

    static func isChannelClosedError(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError {
            return channelError == .eof || channelError == .alreadyClosed
                || channelError == .inputClosed || channelError == .outputClosed
        }
        return false
    }
}

// MARK: - SSH Errors

enum SSHError: LocalizedError {
    case sessionNotFound
    case passwordRequired
    case sshKeyNotFound
    case invalidCredentialPreparation
    case invalidCredentialEncoding
    case connectionFailed
    case notConnected
    case authenticationFailed
    case invalidHost(String)
    case invalidPort(Int)
    case unsupportedSSHKeyType(String)
    case unsupportedAuthMethod(String)
    case invalidSSHKey(String)
    
    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Terminal session not found"
        case .passwordRequired:
            return "Password is required for authentication"
        case .sshKeyNotFound:
            return "SSH key file not found"
        case .invalidCredentialPreparation:
            return "SSH credentials were not prepared for this connection"
        case .invalidCredentialEncoding:
            return "The stored SSH credential is invalid or corrupt"
        case .connectionFailed:
            return "Failed to establish SSH connection"
        case .notConnected:
            return "Not connected to SSH server"
        case .authenticationFailed:
            return "Authentication failed"
        case .invalidHost(let host):
            return "Invalid host: \(host)"
        case .invalidPort(let port):
            return "Invalid SSH port: \(port)"
        case .unsupportedSSHKeyType(let keyType):
            return "SSH key type '\(keyType)' is not supported yet. Use RSA or ED25519."
        case .unsupportedAuthMethod(let message):
            return message
        case .invalidSSHKey(let message):
            return "Invalid SSH key: \(message)"
        }
    }
}

// MARK: - Layout Presets

struct LayoutPreset: Identifiable, Codable, Hashable {
    static let currentSchemaVersion = 2

    struct SessionIntent: Codable, Hashable {
        static let currentSchemaVersion = 1

        enum Restoration: Hashable, Codable {
            case freshAuthorizedSession
            case unsupported(String)

            private var rawValue: String {
                switch self {
                case .freshAuthorizedSession:
                    return "freshAuthorizedSession"
                case .unsupported(let value):
                    return value
                }
            }

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer().decode(String.self)
                self = value == "freshAuthorizedSession"
                    ? .freshAuthorizedSession
                    : .unsupported(value)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }

        var schemaVersion: Int
        var serverID: UUID
        var restoration: Restoration

        init(
            schemaVersion: Int = SessionIntent.currentSchemaVersion,
            serverID: UUID,
            restoration: Restoration = .freshAuthorizedSession
        ) {
            self.schemaVersion = schemaVersion
            self.serverID = serverID
            self.restoration = restoration
        }

        var isSupported: Bool {
            schemaVersion == Self.currentSchemaVersion
                && restoration == .freshAuthorizedSession
        }
    }

    let id: UUID
    var name: String
    private(set) var schemaVersion: Int
    var sessionIntents: [SessionIntent]
    let createdAt: Date
    var lastUsed: Date?

    init(id: UUID = UUID(), name: String, serverIDs: [UUID], createdAt: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionIntents = serverIDs.map { SessionIntent(serverID: $0) }
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    init(
        id: UUID = UUID(),
        name: String,
        sessionIntents: [SessionIntent],
        createdAt: Date = Date(),
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionIntents = sessionIntents
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    /// Compatibility view used by callers that only need endpoint identities.
    /// Repeated IDs are intentional: each entry represents a separate session.
    var serverIDs: [UUID] {
        sessionIntents.map(\.serverID)
    }

    var needsMigration: Bool {
        schemaVersion < Self.currentSchemaVersion
    }

    func migratedToCurrentSchema() -> LayoutPreset {
        guard needsMigration else { return self }
        var migrated = self
        migrated.schemaVersion = Self.currentSchemaVersion
        return migrated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case schemaVersion
        case sessionIntents
        case serverIDs
        case createdAt
        case lastUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)

        if let decodedIntents = try container.decodeIfPresent([SessionIntent].self, forKey: .sessionIntents) {
            sessionIntents = decodedIntents
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.currentSchemaVersion
        } else {
            let legacyServerIDs = try container.decodeIfPresent([UUID].self, forKey: .serverIDs) ?? []
            sessionIntents = legacyServerIDs.map { SessionIntent(serverID: $0) }
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionIntents, forKey: .sessionIntents)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
    }
}
