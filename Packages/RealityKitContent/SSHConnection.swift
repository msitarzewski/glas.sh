//
//  SSHConnection.swift
//  glas.sh
//
//  SSH connection implementation using Citadel
//

import Foundation
import Citadel
import NIO

/// Handles actual SSH connection and terminal session
@MainActor
class SSHConnection {
    private var client: SSHClient?
    private var shell: SSHShell?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    
    weak var session: TerminalSession?
    
    init(session: TerminalSession) {
        self.session = session
    }
    
    /// Connect to SSH server
    func connect(password: String?) async throws {
        // Create event loop group for network operations
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group
        
        guard let session = session else { throw SSHError.sessionNotFound }
        let server = session.server
        
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
        
        // Connect to SSH server
        self.client = try await SSHClient.connect(
            host: server.host,
            port: server.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(), // TODO: Implement proper host key validation
            reconnect: .never,
            group: group
        )
        
        guard let client = self.client else {
            throw SSHError.connectionFailed
        }
        
        // Open shell with PTY
        let shell = try await client.openShell(
            terminal: .init(server.terminalType),
            inbound: .limitedBy(windowSize: .init(width: 80)),
            environment: server.environmentVariables.map { .init(name: $0.key, value: $0.value) }
        )
        
        self.shell = shell
        
        // Start reading output
        Task {
            await readOutput(from: shell)
        }
    }
    
    /// Read output from shell
    private func readOutput(from shell: SSHShell) async {
        do {
            for try await chunk in shell.outbound {
                guard let session = session else { return }
                
                let text = String(buffer: chunk)
                await MainActor.run {
                    // Process ANSI codes and add to output
                    self.processOutput(text)
                }
            }
        } catch {
            await MainActor.run {
                session?.state = .error("Connection lost: \(error.localizedDescription)")
            }
        }
    }
    
    /// Process output text (with ANSI code handling)
    private func processOutput(_ text: String) {
        guard let session = session else { return }
        
        // For now, simple line-by-line output
        // TODO: Implement proper ANSI escape sequence parsing
        let lines = text.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            let terminalLine = TerminalLine(text: line, style: .output)
            session.output.append(terminalLine)
            
            // Manage scrollback
            if session.output.count > session.maxScrollback {
                let excess = session.output.count - session.maxScrollback
                session.scrollbackBuffer.append(contentsOf: session.output.prefix(excess))
                session.output.removeFirst(excess)
            }
        }
    }
    
    /// Send command to shell
    func sendCommand(_ command: String) async throws {
        guard let shell = shell else {
            throw SSHError.notConnected
        }
        
        let commandData = command + "\n"
        try await shell.write(ByteBuffer(string: commandData))
    }
    
    /// Send raw input (for key presses, control characters, etc.)
    func sendInput(_ input: String) async throws {
        guard let shell = shell else {
            throw SSHError.notConnected
        }
        
        try await shell.write(ByteBuffer(string: input))
    }
    
    /// Disconnect from SSH server
    func disconnect() async {
        do {
            try await shell?.close()
            try await client?.close()
        } catch {
            print("Error during disconnect: \(error)")
        }
        
        try? await eventLoopGroup?.shutdownGracefully()
        
        shell = nil
        client = nil
        eventLoopGroup = nil
    }
    
    /// Resize terminal window
    func resizeTerminal(rows: Int, columns: Int) async throws {
        // TODO: Implement window size change
        // This would send SIGWINCH to the remote shell
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
        }
    }
}
