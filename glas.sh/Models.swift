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
#if canImport(CryptoKit)
import CryptoKit
#endif

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
    var isFavorite: Bool
    var colorTag: ServerColorTag
    let dateAdded: Date
    var lastConnected: Date?
    var tags: [String]
    
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
        isFavorite: Bool = false,
        colorTag: ServerColorTag = .blue,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sshKeyPath = sshKeyPath
        self.isFavorite = isFavorite
        self.colorTag = colorTag
        self.dateAdded = Date()
        self.lastConnected = nil
        self.tags = tags
        
        // Defaults
        self.compression = true
        self.keepAliveInterval = 60
        self.serverAliveCountMax = 3
        self.forwardAgent = true
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

final class PromptingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private static let challengeCacheQueue = DispatchQueue(label: "sh.glas.hostkey.challenge-cache")
    private static var challengeCache: [String: HostKeyTrustChallenge] = [:]

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
        challengeCacheQueue.sync {
            challengeCache[cacheKey(host: challenge.host, port: challenge.port)] = challenge
        }
    }

    static func takeLatestChallenge(host: String, port: Int) -> HostKeyTrustChallenge? {
        challengeCacheQueue.sync {
            challengeCache.removeValue(forKey: cacheKey(host: host, port: port))
        }
    }

    static func clearChallenge(host: String, port: Int) {
        _ = challengeCacheQueue.sync {
            challengeCache.removeValue(forKey: cacheKey(host: host, port: port))
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
    let server: ServerConfiguration
    
    var state: SessionState = .disconnected
    var output: [TerminalLine] = []
    var screenRows: [String] = []
    var screenStyledRows: [[TerminalStyledCell]] = []
    var terminalInputChunk: Data = Data()
    var terminalInputNonce: UInt64 = 0
    var closeWindowNonce: UInt64 = 0
    var currentDirectory: String = "~"
    var systemInfo: SystemInfo?
    var portForwards: [PortForward] = []
    var pendingHostKeyChallenge: HostKeyTrustChallenge?
    var lastConnectionDiagnostics: String?
    var connectionProgress: ConnectionProgressStage?
    
    // Terminal properties
    var cursorPosition: (row: Int, col: Int) = (0, 0)
    var scrollbackBuffer: [TerminalLine] = []
    let maxScrollback: Int = 10000
    
    // SSH Connection
    private var sshConnection: SSHConnection?
    private var connectionTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    let emulator = TerminalEmulator(cols: 140, rows: 40)
    
    init(server: ServerConfiguration) {
        self.id = UUID()
        self.server = server
        self.sshConnection = SSHConnection(session: self)
        self.screenRows = emulator.rows
        self.screenStyledRows = emulator.styledRows
        self.cursorPosition = emulator.cursor
    }
    
    // Hashable conformance
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    func connect(password: String? = nil) async {
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
            try await sshConnection?.connect(password: password)
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
                rawValue: UserDefaults.standard.string(forKey: "hostKeyVerificationMode") ?? ""
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
            print("SSH connect error (\(server.host):\(server.port)): \(error)")
            lastConnectionDiagnostics =
                "Attempted: \(server.host):\(server.port)\nAuth method: \(server.authMethod.displayName)\nHost key mode: \(mode.rawValue)\nRaw error: \(String(describing: error))"
            connectionProgress = nil
            state = .error(message)
            appendLine(TerminalLine(text: "✗ \(message)", style: .error))
        }
    }
    
    func disconnect() {
        Task {
            await sshConnection?.disconnect()
        }
        connectionTask?.cancel()
        outputTask?.cancel()
        connectionProgress = nil
        state = .disconnected
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
    
    func sendKeyPress(_ key: String) {
        Task {
            do {
                try await sshConnection?.sendInput(key)
            } catch {
                print("Error sending key: \(error)")
            }
        }
    }

    func sendTerminalData(_ data: Data) {
        Task {
            do {
                try await sshConnection?.sendBytes(data)
            } catch {
                print("Error sending terminal data: \(error)")
            }
        }
    }

    func handleCleanRemoteExit() {
        connectionProgress = nil
        state = .disconnected
        closeWindowNonce &+= 1
    }
    
    private func appendLine(_ line: TerminalLine) {
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
        emulator.feed(text: clearSequence)
        if let clearData = clearSequence.data(using: .utf8) {
            terminalInputChunk = clearData
            terminalInputNonce &+= 1
        }
        syncEmulatorSnapshot()
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
        emulator.feed(data: data)
        terminalInputChunk = data
        terminalInputNonce &+= 1
        syncEmulatorSnapshot()
    }
    
    func feedTerminalText(_ text: String) {
        emulator.feed(text: text)
        syncEmulatorSnapshot()
    }

    func updateTerminalGeometry(rows: Int, columns: Int) {
        let clampedRows = max(8, rows)
        let clampedColumns = max(20, columns)

        emulator.resize(cols: clampedColumns, rows: clampedRows)
        syncEmulatorSnapshot()
        sshConnection?.setPreferredTerminalSize(rows: clampedRows, columns: clampedColumns)

        guard state == .connected else { return }

        Task {
            do {
                try await sshConnection?.resizeTerminal(rows: clampedRows, columns: clampedColumns)
            } catch {
                print("Failed to resize remote PTY: \(error)")
            }
        }
    }
    
    private func syncEmulatorSnapshot() {
        screenRows = emulator.rows
        screenStyledRows = emulator.styledRows
        cursorPosition = emulator.cursor
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

struct SystemInfo {
    let hostname: String
    let os: String
    let kernel: String
    let uptime: String
    let cpuCores: Int
    let totalMemory: String
    let architecture: String
}

// MARK: - Port Forwarding

struct PortForward: Identifiable, Codable {
    let id: UUID
    var type: ForwardType
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var isActive: Bool
    let dateCreated: Date
    
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
        remotePort: Int,
        isActive: Bool = false
    ) {
        self.id = id
        self.type = type
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.isActive = isActive
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
    private var terminalRows: Int = 40
    private var terminalColumns: Int = 140
    
    weak var session: TerminalSession?
    
    init(session: TerminalSession) {
        self.session = session
    }

    func setPreferredTerminalSize(rows: Int, columns: Int) {
        terminalRows = max(8, rows)
        terminalColumns = max(20, columns)
    }
    
    /// Connect to SSH server
    func connect(password: String?) async throws {
        guard let session = session else { throw SSHError.sessionNotFound }
        let server = session.server
        let normalizedHost = Self.normalizedHost(server.host)
        guard !normalizedHost.isEmpty else {
            throw SSHError.invalidHost(server.host)
        }
        await session.setConnectionProgress(.resolvingDNS)
        
        // Determine authentication method
        let authMethod: SSHAuthenticationMethod
        switch server.authMethod {
        case .password:
            guard let pwd = password else {
                throw SSHError.passwordRequired
            }
            authMethod = .passwordBased(username: server.username, password: pwd)
            
        case .sshKey:
            // TODO: Implement SSH key authentication
            guard let keyPath = server.sshKeyPath else {
                throw SSHError.sshKeyNotFound
            }
            _ = keyPath
            // For now, fall back to password
            guard let pwd = password else {
                throw SSHError.passwordRequired
            }
            authMethod = .passwordBased(username: server.username, password: pwd)
            
        case .agent:
            // TODO: Implement SSH agent authentication
            guard let pwd = password else {
                throw SSHError.passwordRequired
            }
            authMethod = .passwordBased(username: server.username, password: pwd)
        }
        
        let mode = Self.hostKeyVerificationMode()
        let trustedSet = Self.trustedHostKeyBase64Set(host: normalizedHost, port: server.port)
        let hostKeyValidator: SSHHostKeyValidator
        if mode == .insecureAcceptAny {
            hostKeyValidator = .acceptAnything()
        } else {
            hostKeyValidator = .custom(
                PromptingHostKeyValidator(
                    host: normalizedHost,
                    port: server.port,
                    trustedKeyBase64Set: trustedSet,
                    verificationMode: mode
                )
            )
        }

        // Connect to SSH server using Citadel.
        // Try modern defaults first, then retry once with compatibility algorithms
        // for servers that still require older SSH kex/signature sets.
        await session.setConnectionProgress(.openingSocket(port: server.port))
        await session.setConnectionProgress(.negotiatingSecurity)
        do {
            self.client = try await Self.connectClient(
                host: normalizedHost,
                port: server.port,
                authenticationMethod: authMethod,
                hostKeyValidator: hostKeyValidator,
                algorithms: SSHAlgorithms()
            )
        } catch {
            if Self.isKeyExchangeNegotiationFailure(error) {
                await session.setConnectionProgress(.negotiatingCompatibility)
                self.client = try await Self.connectClient(
                    host: normalizedHost,
                    port: server.port,
                    authenticationMethod: authMethod,
                    hostKeyValidator: hostKeyValidator,
                    algorithms: .all
                )
            } else {
                throw error
            }
        }
        await session.setConnectionProgress(.authenticating)

        guard let client = self.client else {
            throw SSHError.connectionFailed
        }

        ttyTask = Task { [weak self] in
            await self?.runInteractiveTTY(client: client, server: server)
        }
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
                terminalModes: SSHTerminalModes([:])
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
            if String(describing: error).contains("ChannelError error 6") {
                await MainActor.run {
                    self.session?.handleCleanRemoteExit()
                }
                return
            }
            let message = Self.userFacingMessage(for: error, server: server)
            print("SSH stream error (\(server.host):\(server.port)): \(error)")
            await MainActor.run {
                if case .connected = self.session?.state {
                    self.session?.reportError(message)
                }
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
    
    /// Disconnect from SSH server
    func disconnect() async {
        ttyTask?.cancel()
        ttyTask = nil
        ttyWriter = nil

        do {
            try await client?.close()
        } catch {
            print("Error during disconnect: \(error)")
        }
        
        client = nil
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

        let raw = String(describing: error)
        if raw.localizedCaseInsensitiveContains("keyexchangenegotiationfailure")
            || raw.localizedCaseInsensitiveContains("key exchange negotiation failure")
        {
            return "SSH handshake failed: no shared security algorithm was found with \(server.host):\(server.port)."
        }
        if raw.contains("ChannelError error 0") {
            return "A connection to \(server.host):\(server.port) is already in progress."
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
            let rawValue = UserDefaults.standard.string(forKey: "hostKeyVerificationMode"),
            let mode = HostKeyVerificationMode(rawValue: rawValue)
        else {
            return .ask
        }
        return mode
    }

    private static func trustedHostKeyBase64Set(host: String, port: Int) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "trustedHostKeys") else {
            return []
        }
        guard let entries = try? JSONDecoder().decode([TrustedHostKeyEntry].self, from: data) else {
            return []
        }
        return Set(
            entries
                .filter { $0.host == host && $0.port == port }
                .map { $0.keyDataBase64 }
        )
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

    private static func isKeyExchangeNegotiationFailure(_ error: Error) -> Bool {
        if let nioError = error as? NIOSSHError, nioError.type == .keyExchangeNegotiationFailure {
            return true
        }

        let raw = String(describing: error)
        return raw.localizedCaseInsensitiveContains("keyexchangenegotiationfailure")
            || raw.localizedCaseInsensitiveContains("key exchange negotiation failure")
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
        }
    }
}
