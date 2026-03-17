//
//  Models.swift
//  glas.sh
//
//  Core data models for SSH connections, sessions, and configuration
//

import SwiftUI
import Foundation
import Security
import Observation
import Citadel
import NIOCore
import NIOSSH
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
    case insecureAcceptAny = "Insecure (Accept Any)"
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
        self.requestPTY = true
        self.terminalType = "xterm-256color"
        self.environmentVariables = [:]
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

final class PromptingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private static let challengeCache = OSAllocatedUnfairLock(initialState: [String: HostKeyTrustChallenge]())

    private let host: String
    private let port: Int
    private let trustedKeyBase64Set: Set<String>
    private let verificationMode: HostKeyVerificationMode

    init(host: String, port: Int, trustedKeyBase64Set: Set<String>, verificationMode: HostKeyVerificationMode) {
        self.host = host
        self.port = port
        self.trustedKeyBase64Set = trustedKeyBase64Set
        self.verificationMode = verificationMode
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let challenge = Self.challenge(from: hostKey, host: host, port: port, trustedKeyBase64Set: trustedKeyBase64Set)
        Self.storeChallenge(challenge)

        if trustedKeyBase64Set.contains(challenge.keyDataBase64) {
            Self.clearChallenge(host: host, port: port)
            validationCompletePromise.succeed(())
            return
        }

        switch verificationMode {
        case .insecureAcceptAny:
            validationCompletePromise.succeed(())
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

    private static func cacheKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    private static func storeChallenge(_ challenge: HostKeyTrustChallenge) {
        challengeCache.withLock {
            $0[cacheKey(host: challenge.host, port: challenge.port)] = challenge
        }
    }

    static func takeLatestChallenge(host: String, port: Int) -> HostKeyTrustChallenge? {
        challengeCache.withLock {
            $0.removeValue(forKey: cacheKey(host: host, port: port))
        }
    }

    static func clearChallenge(host: String, port: Int) {
        challengeCache.withLock {
            _ = $0.removeValue(forKey: cacheKey(host: host, port: port))
        }
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

@MainActor
@Observable
class TerminalSession: Identifiable, Hashable {
    let id: UUID
    var server: ServerConfiguration
    
    var state: SessionState = .disconnected
    var output: [TerminalLine] = []
    var terminalInputNonce: UInt64 = 0
    var closeWindowNonce: UInt64 = 0
    var currentDirectory: String = "~"
    var portForwards: [PortForward] = []
    var pendingHostKeyChallenge: HostKeyTrustChallenge?
    var lastConnectionDiagnostics: String?
    var connectionProgress: ConnectionProgressStage?
    
    // Terminal properties
    var scrollbackBuffer: [TerminalLine] = []
    let maxScrollback: Int = 10000
    
    // Jump host chain (resolved before connect, ordered first-hop to last-hop)
    var jumpHostChain: [ServerConfiguration] = []

    // SSH Connection
    private var sshConnection: SSHConnection?
    nonisolated(unsafe) private var connectionTask: Task<Void, Never>?
    nonisolated(unsafe) private var outputTask: Task<Void, Never>?
    private var pendingTerminalOutput = Data()
    private var pendingTerminalInputChunks: [Data] = []
    nonisolated(unsafe) private var terminalFlushTask: Task<Void, Never>?
    private let terminalFlushInterval: Duration = .milliseconds(8)
    private var userInitiatedDisconnect: Bool = false
    nonisolated(unsafe) private var reconnectTask: Task<Void, Never>?
    var reconnectAttemptCount: Int = 0
    var recorder: SessionRecorder?
    var sharePlayManager: SharePlayManager?

    init(server: ServerConfiguration) {
        self.id = UUID()
        self.server = server
        self.sshConnection = SSHConnection(session: self)
    }

    deinit {
        connectionTask?.cancel()
        outputTask?.cancel()
        terminalFlushTask?.cancel()
        reconnectTask?.cancel()
    }

    func getSSHConnection() -> SSHConnection? { sshConnection }

    // Hashable conformance
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    func connect(password: String? = nil) async {
        userInitiatedDisconnect = false
        if state == .connecting {
            appendLine(TerminalLine(text: "Connection already in progress. Please wait…", style: .system))
            return
        }

        if state == .connected {
            appendLine(TerminalLine(text: "Already connected to \(server.name).", style: .system))
            return
        }

        state = .connecting
        connectionProgress = .resolvingDNS
        lastConnectionDiagnostics = nil
        appendLine(TerminalLine(text: "Connecting to \(server.name)...", style: .system))
        
        do {
            try await sshConnection?.connect(password: password, jumpHostChain: jumpHostChain)
            pendingHostKeyChallenge = nil
            connectionProgress = nil
            lastConnectionDiagnostics = nil
            state = .connected
            appendLine(TerminalLine(text: "✓ Connected to \(server.username)@\(server.host)", style: .system))
        } catch {
            if let challengeError = error as? HostKeyTrustRequiredError {
                pendingHostKeyChallenge = challengeError.challenge
            } else if let cachedChallenge = PromptingHostKeyValidator.takeLatestChallenge(
                host: server.host,
                port: server.port
            ) {
                pendingHostKeyChallenge = cachedChallenge
            }
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
                case .insecureAcceptAny:
                    message = SSHConnection.userFacingMessage(for: error, server: server)
                }
            } else {
                message = SSHConnection.userFacingMessage(for: error, server: server)
            }
            Logger.ssh.error("SSH connect error (\(self.server.host):\(self.server.port)): \(error)")
            lastConnectionDiagnostics =
                "Attempted: \(server.host):\(server.port)\nAuth method: \(server.authMethod.displayName)\nHost key mode: \(mode.rawValue)\nRaw error: \(String(describing: error))"
            connectionProgress = nil
            state = .error(message)
            appendLine(TerminalLine(text: "✗ \(message)", style: .error))
        }
    }
    
    func disconnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        Task {
            await sshConnection?.disconnect()
        }
        connectionTask?.cancel()
        outputTask?.cancel()
        connectionProgress = nil
        state = .disconnected
    }

    func attemptAutoReconnect(autoReconnectEnabled: Bool) {
        guard autoReconnectEnabled,
              !userInitiatedDisconnect
        else { return }

        reconnectTask?.cancel()
        reconnectAttemptCount = 0
        state = .reconnecting
        appendLine(TerminalLine(text: "Connection lost. Auto-reconnecting...", style: .system))

        reconnectTask = Task { [weak self] in
            let maxAttempts = 5

            for attempt in 1...maxAttempts {
                guard !Task.isCancelled, let self else { return }

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

                await self.sshConnection?.disconnect()
                self.sshConnection = SSHConnection(session: self)
                await self.connect()

                if self.state == .connected {
                    self.appendLine(TerminalLine(text: "Reconnected successfully.", style: .system))
                    self.reconnectTask = nil
                    return
                }

                if attempt < maxAttempts {
                    self.state = .reconnecting
                }
            }

            guard let self, !Task.isCancelled else { return }
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
        Task {
            do {
                try await sshConnection?.sendCommand(command)
            } catch {
                appendLine(TerminalLine(text: "Error: \(error.localizedDescription)", style: .error))
            }
        }
    }
    
    func sendTerminalData(_ data: Data) {
        recorder?.recordInput(data)
        Task {
            do {
                try await sshConnection?.sendBytes(data)
            } catch {
                Logger.ssh.error("Error sending terminal data: \(error)")
            }
        }
    }

    func handleCleanRemoteExit() {
        connectionProgress = nil
        state = .disconnected
        closeWindowNonce &+= 1
    }
    
    func appendLine(_ line: TerminalLine) {
        output.append(line)
        
        // Manage scrollback
        if output.count > maxScrollback {
            let excess = output.count - maxScrollback
            scrollbackBuffer.append(contentsOf: output.prefix(excess))
            output.removeFirst(excess)
        }
    }
    
    func clearScreen() {
        let clearSequence = "\u{1b}[2J\u{1b}[H"
        terminalFlushTask?.cancel()
        terminalFlushTask = nil
        pendingTerminalOutput.removeAll(keepingCapacity: true)
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
        if let sharePlay = sharePlayManager, sharePlay.isActive {
            Task { await sharePlay.broadcastOutput(data) }
        }
        scheduleTerminalFlush()
    }
    
    func updateTerminalGeometry(rows: Int, columns: Int) {
        let clampedRows = max(8, rows)
        let clampedColumns = max(20, columns)

        sshConnection?.setPreferredTerminalSize(rows: clampedRows, columns: clampedColumns)

        guard state == .connected else { return }

        Task {
            do {
                try await sshConnection?.resizeTerminal(rows: clampedRows, columns: clampedColumns)
            } catch {
                Logger.ssh.error("Failed to resize remote PTY: \(error)")
            }
        }
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
        terminalFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.terminalFlushInterval)
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
    var lineSpacing: CGFloat
    var opacity: Double
    
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
        fontSize: 14,
        lineSpacing: 1.2,
        opacity: 0.95
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
        // Note: This is a simplified version. In production, you'd need proper color space conversion
        let components = color.cgColor?.components ?? [0, 0, 0, 1]
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
    private var ttyWriter: TTYStdinWriter?
    private var ttyTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var missedKeepAlives: Int = 0
    private var terminalRows: Int = 40
    private var terminalColumns: Int = 140

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
    
    /// Resolve SSH authentication method for a given server configuration.
    /// Reused for both direct connections and jump host connections.
    private static func resolveAuthMethod(
        for server: ServerConfiguration,
        password: String?
    ) throws -> SSHAuthenticationMethod {
        switch server.authMethod {
        case .password:
            guard let pwd = password else {
                throw SSHError.passwordRequired
            }
            return .passwordBased(username: server.username, password: pwd)

        case .sshKey:
            guard let keyID = server.sshKeyID else {
                throw SSHError.sshKeyNotFound
            }
            do {
                let keyMaterial = try KeychainManager.retrieveSSHKey(for: keyID)
                let privateKeyString = keyMaterial.privateKey.toUTF8String() ?? ""
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
                throw SSHError.invalidSSHKey(error.localizedDescription)
            }

        case .agent:
            // TODO: Implement SSH agent authentication
            guard let pwd = password else {
                throw SSHError.passwordRequired
            }
            return .passwordBased(username: server.username, password: pwd)
        }
    }

    /// Build an SSHHostKeyValidator for a given server configuration.
    private static func resolveHostKeyValidator(
        for server: ServerConfiguration,
        normalizedHost: String
    ) -> SSHHostKeyValidator {
        let mode = hostKeyVerificationMode()
        let trustedSet = trustedHostKeyBase64Set(server: server, host: normalizedHost, port: server.port)
        if mode == .insecureAcceptAny {
            return .acceptAnything()
        } else {
            return .custom(
                PromptingHostKeyValidator(
                    host: normalizedHost,
                    port: server.port,
                    trustedKeyBase64Set: trustedSet,
                    verificationMode: mode
                )
            )
        }
    }

    /// Connect to an SSH server with retry for legacy kex algorithms.
    private static func connectWithFallback(
        host: String,
        port: Int,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
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
            if isKeyExchangeNegotiationFailure(error) {
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
    func connect(password: String?, jumpHostChain: [ServerConfiguration] = []) async throws {
        guard let session = session else { throw SSHError.sessionNotFound }
        let server = session.server
        let normalizedHost = Self.normalizedHost(server.host)
        guard !normalizedHost.isEmpty else {
            throw SSHError.invalidHost(server.host)
        }
        session.setConnectionProgress(.resolvingDNS)

        // Resolve target authentication method
        let authMethod = try Self.resolveAuthMethod(for: server, password: password)
        let hostKeyValidator = Self.resolveHostKeyValidator(for: server, normalizedHost: normalizedHost)

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

            // Resolve first hop credentials
            let firstHopPassword: String?
            if firstHop.authMethod == .password {
                firstHopPassword = try KeychainManager.retrievePassword(for: firstHop)
            } else {
                firstHopPassword = nil
            }
            let firstHopAuth = try Self.resolveAuthMethod(for: firstHop, password: firstHopPassword)
            let firstHopValidator = Self.resolveHostKeyValidator(for: firstHop, normalizedHost: firstHopHost)

            session.appendLine(TerminalLine(
                text: "Connecting via jump host \(firstHop.name) (\(firstHop.host):\(firstHop.port))...",
                style: .system
            ))

            // 1. Connect to the first jump host
            var currentClient = try await Self.connectWithFallback(
                host: firstHopHost,
                port: firstHop.port,
                authenticationMethod: firstHopAuth,
                hostKeyValidator: firstHopValidator,
                session: session
            )

            session.appendLine(TerminalLine(
                text: "Hop 1/\(jumpHostChain.count) connected: \(firstHop.name)",
                style: .system
            ))

            // 2. Jump through each subsequent hop in the chain
            for (index, hopConfig) in jumpHostChain.dropFirst().enumerated() {
                let hopHost = Self.normalizedHost(hopConfig.host)
                guard !hopHost.isEmpty else {
                    throw SSHError.invalidHost(hopConfig.host)
                }

                let hopPassword: String?
                if hopConfig.authMethod == .password {
                    hopPassword = try KeychainManager.retrievePassword(for: hopConfig)
                } else {
                    hopPassword = nil
                }
                let hopAuth = try Self.resolveAuthMethod(for: hopConfig, password: hopPassword)
                let hopValidator = Self.resolveHostKeyValidator(for: hopConfig, normalizedHost: hopHost)

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
                currentClient = try await currentClient.jump(to: hopSettings)

                session.appendLine(TerminalLine(
                    text: "Hop \(index + 2)/\(jumpHostChain.count) connected: \(hopConfig.name)",
                    style: .system
                ))
            }

            session.appendLine(TerminalLine(
                text: "Tunneling to target \(server.host):\(server.port)...",
                style: .system
            ))

            // 3. Jump through to the final target server
            let targetSettings = SSHClientSettings(
                host: normalizedHost,
                port: server.port,
                authenticationMethod: { authMethod },
                hostKeyValidator: hostKeyValidator
            )
            self.client = try await currentClient.jump(to: targetSettings)
        } else {
            // --- Direct connection path ---
            self.client = try await Self.connectWithFallback(
                host: normalizedHost,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: hostKeyValidator,
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
        return try await client.openSFTP()
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
    func runRemotePortForward(remoteHost: String, remotePort: Int,
                              localHost: String, localPort: Int) async throws {
        guard let client else { throw SSHError.notConnected }
        try await client.runRemotePortForward(
            host: remoteHost, port: remotePort,
            forwardingTo: localHost, port: localPort
        ) { remoteForward in
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

        do {
            try await client?.close()
        } catch {
            Logger.ssh.error("Error during disconnect: \(error)")
        }

        client = nil
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
            case .authenticationFailed:
                return "Authentication failed for \(server.username)@\(server.host):\(server.port)."
            case .invalidHost(let rawHost):
                return "The host \"\(rawHost)\" is not valid. Use a plain host name or IP (no protocol)."
            case .connectionFailed:
                return "Could not establish an SSH connection to \(server.host):\(server.port)."
            case .notConnected:
                return "Not connected to \(server.host):\(server.port)."
            case .sessionNotFound:
                return "The terminal session is no longer available."
            case .unsupportedSSHKeyType(let keyType):
                return "\(keyType). Supported key types are RSA, ED25519, and ECDSA P-256."
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

    private static func trustedHostKeyBase64Set(server: ServerConfiguration, host: String, port: Int) -> Set<String> {
        let serverEntries = Set(
            (server.trustedHostKeys ?? [])
                .filter { $0.host == host && $0.port == port }
                .map { $0.keyDataBase64 }
        )
        if !serverEntries.isEmpty {
            return serverEntries
        }

        // Backward-compatible fallback for previously stored global trust entries.
        guard let data = SharedDefaults.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys),
              let entries = try? JSONDecoder().decode([TrustedHostKeyEntry].self, from: data)
        else {
            return []
        }
        return Set(entries.filter { $0.host == host && $0.port == port }.map { $0.keyDataBase64 })
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
    case connectionFailed
    case notConnected
    case authenticationFailed
    case invalidHost(String)
    case unsupportedSSHKeyType(String)
    case invalidSSHKey(String)
    
    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Terminal session not found"
        case .passwordRequired:
            return "Password is required for authentication"
        case .sshKeyNotFound:
            return "SSH key file not found"
        case .connectionFailed:
            return "Failed to establish SSH connection"
        case .notConnected:
            return "Not connected to SSH server"
        case .authenticationFailed:
            return "Authentication failed"
        case .invalidHost(let host):
            return "Invalid host: \(host)"
        case .unsupportedSSHKeyType(let keyType):
            return "SSH key type '\(keyType)' is not supported yet. Use RSA or ED25519."
        case .invalidSSHKey(let message):
            return "Invalid SSH key: \(message)"
        }
    }
}

// MARK: - Layout Presets

struct LayoutPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var serverIDs: [UUID]
    let createdAt: Date
    var lastUsed: Date?

    init(id: UUID = UUID(), name: String, serverIDs: [UUID], createdAt: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.serverIDs = serverIDs
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }
}
