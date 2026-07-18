//
//  SessionManager.swift
//  glas.sh
//
//  Manages active terminal sessions
//

import SwiftUI
import Observation
import WidgetKit
import GlasSecretStore

@MainActor
@Observable
class SessionManager {
    struct ReconnectContext {
        let server: ServerConfiguration
        let password: String?
    }

    struct ConnectionPreparationResult {
        let authentication: SessionConnectionPreparation
        let jumpHostChain: [ServerConfiguration]
    }

    private enum SessionOrigin {
        case savedProfile(UUID)
        case transient(ServerConfiguration)
    }

    var sessions: [TerminalSession] = []
    let portForwardManager: PortForwardManager
    private let stopSessionForwards: (UUID) -> Void
    private let retrievePassword: (ServerConfiguration) throws -> String
    private let retrieveSSHKey: (UUID) throws -> SSHKeyMaterial

    let serverManager: ServerManager
    private var sessionOrigins: [UUID: SessionOrigin] = [:]
    private var transientPasswords: [UUID: SecureBytes] = [:]

    init(
        serverManager: ServerManager? = nil,
        loadImmediately: Bool = true,
        stopSessionForwards: ((UUID) -> Void)? = nil,
        retrievePassword: ((ServerConfiguration) throws -> String)? = nil,
        retrieveSSHKey: ((UUID) throws -> SSHKeyMaterial)? = nil
    ) {
        let authoritativeServerManager = serverManager ?? ServerManager(loadImmediately: false)
        let forwardManager = PortForwardManager()
        self.serverManager = authoritativeServerManager
        self.portForwardManager = forwardManager
        // The concrete manager is awaited by the lifecycle hook below. This
        // optional callback is an observation seam for focused lifecycle tests.
        self.stopSessionForwards = stopSessionForwards ?? { _ in }
        self.retrievePassword = retrievePassword ?? { try KeychainManager.retrievePassword(for: $0) }
        self.retrieveSSHKey = retrieveSSHKey ?? { try KeychainManager.retrieveSSHKey(for: $0) }
        if loadImmediately {
            authoritativeServerManager.loadServersIfNeeded()
        }
    }

    func preloadPersistentStateIfNeeded() {
        serverManager.loadServersIfNeeded()
    }

    func server(for id: UUID) -> ServerConfiguration? {
        serverManager.server(for: id)
    }

    private func prepareAuthentication(
        for server: ServerConfiguration,
        location: SessionCredentialLocation,
        providedPassword: String? = nil
    ) throws -> PreparedServerAuthentication {
        let material: SessionAuthenticationMaterial
        switch server.authMethod {
        case .password:
            let password: String
            if let providedPassword {
                password = providedPassword
            } else {
                do {
                    password = try retrievePassword(server)
                } catch SecretStoreError.notFound {
                    throw SessionOpenError.missingPassword(server: server, location: location)
                } catch {
                    throw SessionOpenError.credentialUnavailable(server: server, location: location)
                }
            }
            material = .password(SecureBytes(Data(password.utf8)))
        case .sshKey:
            guard let keyID = server.sshKeyID else {
                throw SessionOpenError.sshKeyNotFound(server: server, location: location)
            }
            do {
                material = .sshKey(try retrieveSSHKey(keyID))
            } catch SecretStoreError.notFound {
                throw SessionOpenError.sshKeyNotFound(server: server, location: location)
            } catch {
                throw SessionOpenError.credentialUnavailable(server: server, location: location)
            }
        case .agent:
            throw SessionOpenError.unsupportedAgent(server: server, location: location)
        }

        let authentication = PreparedServerAuthentication(serverID: server.id, material: material)
        do {
            _ = try SSHConnection.resolveAuthMethod(for: server, authentication: authentication)
        } catch {
            throw SessionOpenError.invalidSSHKey(server: server, location: location)
        }
        return authentication
    }

    private func prepareConnection(
        for server: ServerConfiguration,
        providedPassword: String?
    ) throws -> ConnectionPreparationResult {
        let jumpHostChain = try resolveJumpHostChain(for: server)
        let target = try prepareAuthentication(
            for: server,
            location: .target,
            providedPassword: providedPassword
        )
        let jumpAuthentication = try jumpHostChain.enumerated().map { index, hop in
            try prepareAuthentication(
                for: hop,
                location: .jumpHost(index + 1)
            )
        }
        return ConnectionPreparationResult(
            authentication: SessionConnectionPreparation(
                target: target,
                jumpHosts: jumpAuthentication
            ),
            jumpHostChain: jumpHostChain
        )
    }

    func prepareConnection(for server: ServerConfiguration) throws -> ConnectionPreparationResult {
        try prepareConnection(for: server, providedPassword: nil)
    }

    func createAuthorizedSession(
        for server: ServerConfiguration,
        settingsManager: SettingsManager
    ) async throws -> AuthorizedSessionLaunch {
        guard let currentServer = serverManager.server(for: server.id) else {
            throw SessionOpenError.savedServerNotFound
        }
        return try await createAuthorizedSession(
            for: currentServer,
            origin: .savedProfile(currentServer.id),
            settingsManager: settingsManager,
            providedPassword: nil
        )
    }

    func createTransientAuthorizedSession(
        for server: ServerConfiguration,
        settingsManager: SettingsManager,
        password providedPassword: String? = nil
    ) async throws -> AuthorizedSessionLaunch {
        guard serverManager.server(for: server.id) == nil else {
            throw SessionOpenError.transientServerIDCollision
        }
        return try await createAuthorizedSession(
            for: server,
            origin: .transient(server),
            settingsManager: settingsManager,
            providedPassword: providedPassword
        )
    }

    private func createAuthorizedSession(
        for server: ServerConfiguration,
        origin: SessionOrigin,
        settingsManager: SettingsManager,
        providedPassword: String?
    ) async throws -> AuthorizedSessionLaunch {
        let prepared: ConnectionPreparationResult
        switch origin {
        case .savedProfile:
            prepared = try prepareConnection(for: server)
        case .transient:
            prepared = try prepareConnection(for: server, providedPassword: providedPassword)
        }
        let session = await createSession(
            for: server,
            prepared: prepared,
            origin: origin,
            transientPassword: {
                guard case .transient = origin else { return nil }
                return providedPassword
            }(),
            settingsManager: settingsManager
        )
        if case .error = session.state, session.pendingHostKeyChallenge == nil {
            unregister(session)
        }
        return AuthorizedSessionLaunch(session: session)
    }

    func createAuthorizedSessionByServerID(
        _ serverID: UUID,
        settingsManager: SettingsManager
    ) async throws -> AuthorizedSessionLaunch {
        guard let server = serverManager.server(for: serverID) else {
            throw SessionOpenError.savedServerNotFound
        }
        return try await createAuthorizedSession(for: server, settingsManager: settingsManager)
    }

    func duplicateAuthorizedSession(
        from session: TerminalSession,
        settingsManager: SettingsManager
    ) async throws -> AuthorizedSessionLaunch {
        switch try origin(for: session) {
        case .savedProfile(let serverID):
            return try await createAuthorizedSessionByServerID(
                serverID,
                settingsManager: settingsManager
            )
        case .transient:
            let context = try reconnectContext(for: session)
            return try await createTransientAuthorizedSession(
                for: context.server,
                settingsManager: settingsManager,
                password: context.password
            )
        }
    }

    func reconnect(
        _ session: TerminalSession,
        settingsManager: SettingsManager
    ) async throws {
        session.cancelReconnect()
        let context = try reconnectContext(for: session)
        let prepared: ConnectionPreparationResult
        switch try origin(for: session) {
        case .savedProfile:
            prepared = try prepareConnection(for: context.server)
        case .transient:
            prepared = try prepareConnection(for: context.server, providedPassword: context.password)
        }
        session.server = context.server
        session.jumpHostChain = prepared.jumpHostChain
        session.connectionPreparation = prepared.authentication
        installReconnectPreparation(on: session, settingsManager: settingsManager)
        await session.reconnect()

        if session.state == .connected {
            recordSuccessfulConnection(for: session)
        }
    }

    func trustHostKey(_ challenge: HostKeyTrustChallenge, for session: TerminalSession) throws {
        switch try origin(for: session) {
        case .savedProfile(let serverID):
            guard serverManager.server(for: serverID) != nil else {
                throw SessionOpenError.savedServerNotFound
            }
            try serverManager.trustHostKey(challenge, for: serverID)
        case .transient:
            // Quick Connect and Tailscale sessions have no saved profile, but
            // accepted endpoint trust still belongs in authoritative Keychain.
            try KeychainManager.replaceHostKey(with: challenge)
        }
        if let server = serverManager.server(for: session.server.id) {
            session.server = server
        }
    }

    func reconnectContext(for session: TerminalSession) throws -> ReconnectContext {
        switch try origin(for: session) {
        case .savedProfile(let serverID):
            guard let currentServer = serverManager.server(for: serverID) else {
                throw SessionOpenError.savedServerNotFound
            }
            return ReconnectContext(server: currentServer, password: nil)
        case .transient(let server):
            return ReconnectContext(
                server: server,
                password: try Self.decodeTransientPassword(transientPasswords[session.id])
            )
        }
    }

    static func decodeTransientPassword(_ password: SecureBytes?) throws -> String? {
        guard let password else { return nil }
        guard let decoded = password.toUTF8String() else {
            throw SessionOpenError.invalidTransientCredentialEncoding
        }
        return decoded
    }

    func closePendingHostTrustSession(_ session: TerminalSession) {
        session.pendingHostKeyChallenge = nil
        closeSession(session)
    }

    private func origin(for session: TerminalSession) throws -> SessionOrigin {
        guard sessions.contains(where: { $0.id == session.id }),
              let origin = sessionOrigins[session.id] else {
            throw SessionOpenError.sessionNotRegistered
        }
        return origin
    }

    private func resolveJumpHostChain(for server: ServerConfiguration) throws -> [ServerConfiguration] {
        var chain: [ServerConfiguration] = []
        var visited: Set<UUID> = [server.id]
        for id in server.resolvedJumpHostIDs {
            guard visited.insert(id).inserted else {
                throw SessionOpenError.jumpHostCycle
            }
            guard let hop = serverManager.server(for: id) else {
                throw SessionOpenError.jumpHostNotFound
            }
            chain.append(hop)
        }
        return chain
    }

    private func createSession(
        for server: ServerConfiguration,
        prepared: ConnectionPreparationResult,
        origin: SessionOrigin,
        transientPassword: String?,
        settingsManager: SettingsManager
    ) async -> TerminalSession {
        let session = TerminalSession(server: server)
        session.jumpHostChain = prepared.jumpHostChain
        session.connectionPreparation = prepared.authentication

        registerSession(
            session,
            origin: origin,
            transientPassword: transientPassword
        )
        installReconnectPreparation(on: session, settingsManager: settingsManager)

        await session.connect()

        if session.state == .connected {
            recordSuccessfulConnection(for: session)
        }

        return session
    }

    func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func registerSession(_ session: TerminalSession) {
        let inferredOrigin: SessionOrigin
        if serverManager.server(for: session.server.id) != nil {
            inferredOrigin = .savedProfile(session.server.id)
        } else {
            inferredOrigin = .transient(session.server)
        }
        registerSession(session, origin: inferredOrigin, transientPassword: nil)
    }

    func registerTransientSession(_ session: TerminalSession, password: String?) {
        registerSession(
            session,
            origin: .transient(session.server),
            transientPassword: password
        )
    }

    private func registerSession(
        _ session: TerminalSession,
        origin: SessionOrigin,
        transientPassword: String?
    ) {
        installLifecycleHook(on: session)
        guard !sessions.contains(where: { $0.id == session.id }) else { return }
        sessionOrigins[session.id] = origin
        if case .transient = origin, let transientPassword {
            transientPasswords[session.id] = SecureBytes(Data(transientPassword.utf8))
        }
        sessions.append(session)
    }

    func closeSession(_ session: TerminalSession) {
        installLifecycleHook(on: session)
        session.disconnect()
        unregister(session)
    }

    private func unregister(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        sessionOrigins.removeValue(forKey: session.id)
        transientPasswords.removeValue(forKey: session.id)
        session.connectionPreparation = nil
        scheduleForwardPurgeAfterCleanup(for: session)
    }

    private func scheduleForwardPurgeAfterCleanup(for session: TerminalSession) {
        Task { [weak self] in
            await session.awaitLifecycleCleanup()
            guard let self,
                  !self.sessions.contains(where: { $0.id == session.id }) else {
                return
            }
            self.portForwardManager.purgeAllForwards(for: session.id)
        }
    }

    func closeAllSessions() {
        let closingSessions = sessions
        sessions.removeAll()
        sessionOrigins.removeAll(keepingCapacity: false)
        transientPasswords.removeAll(keepingCapacity: false)
        for session in closingSessions {
            installLifecycleHook(on: session)
            session.disconnect()
            session.connectionPreparation = nil
            scheduleForwardPurgeAfterCleanup(for: session)
        }
    }

    private func installReconnectPreparation(on session: TerminalSession, settingsManager _: SettingsManager) {
        session.reconnectPreparation = { [weak self, weak session] _ in
            guard let self, let session else {
                throw SessionOpenError.settingsUnavailable
            }
            let context = try self.reconnectContext(for: session)
            let prepared: ConnectionPreparationResult
            switch try self.origin(for: session) {
            case .savedProfile:
                prepared = try self.prepareConnection(for: context.server)
            case .transient:
                prepared = try self.prepareConnection(
                    for: context.server,
                    providedPassword: context.password
                )
            }
            session.server = context.server
            session.jumpHostChain = prepared.jumpHostChain
            return prepared.authentication
        }
        session.automaticReconnectSucceeded = { [weak self, weak session] in
            guard let self, let session,
                  self.sessions.contains(where: { $0.id == session.id }) else { return }
            self.recordSuccessfulConnection(for: session)
        }
    }

    private func recordSuccessfulConnection(for session: TerminalSession) {
        if serverManager.server(for: session.server.id) != nil {
            serverManager.updateLastConnected(session.server.id)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func installLifecycleHook(on session: TerminalSession) {
        let sessionID = session.id
        session.installLifecycleHook { [weak self] _ in
            guard let self else { return nil }
            self.stopSessionForwards(sessionID)
            return Task { @MainActor [portForwardManager = self.portForwardManager] in
                await portForwardManager.stopAllForwardsAndWait(for: sessionID)
            }
        }
    }
}

struct AuthorizedSessionLaunch {
    let session: TerminalSession
}

enum SessionCredentialLocation: Equatable {
    case target
    case jumpHost(Int)

    var description: String {
        switch self {
        case .target:
            return "target server"
        case .jumpHost(let position):
            return "jump host \(position)"
        }
    }
}

enum SessionOpenError: LocalizedError {
    case missingPassword(server: ServerConfiguration, location: SessionCredentialLocation)
    case credentialUnavailable(server: ServerConfiguration, location: SessionCredentialLocation)
    case sshKeyNotFound(server: ServerConfiguration, location: SessionCredentialLocation)
    case invalidSSHKey(server: ServerConfiguration, location: SessionCredentialLocation)
    case unsupportedAgent(server: ServerConfiguration, location: SessionCredentialLocation)
    case unsupportedAuthMethod(String)
    case settingsUnavailable
    case jumpHostNotFound
    case jumpHostCycle
    case savedServerNotFound
    case sessionNotRegistered
    case transientServerIDCollision
    case invalidTransientCredentialEncoding

    var errorDescription: String? {
        switch self {
        case .missingPassword(let server, let location):
            return "No saved password was found for \(location.description) \(server.name). Open Edit Server and save its password in Keychain, then try again."
        case .credentialUnavailable(let server, let location):
            return "The credential for \(location.description) \(server.name) is unavailable. Unlock the device and try again."
        case .sshKeyNotFound(let server, let location):
            return "The SSH key for \(location.description) \(server.name) is unavailable. Choose an available key in Edit Server and try again."
        case .invalidSSHKey(let server, let location):
            return "The SSH key for \(location.description) \(server.name) is invalid or corrupt. Import the key again and retry."
        case .unsupportedAgent(let server, let location):
            return "SSH Agent authentication is unavailable for \(location.description) \(server.name) in this release."
        case .unsupportedAuthMethod(let message):
            return message
        case .settingsUnavailable:
            return "Settings are unavailable for this connection request."
        case .jumpHostNotFound:
            return "A configured jump host is no longer available. Edit the server and repair its jump-host chain."
        case .jumpHostCycle:
            return "The jump-host chain contains a cycle. Edit the server and remove the repeated host."
        case .savedServerNotFound:
            return "The saved server no longer exists. Return to Connections and choose an available server."
        case .sessionNotRegistered:
            return "This terminal session is no longer active."
        case .transientServerIDCollision:
            return "The temporary connection conflicts with a saved server identifier. Start Quick Connect again."
        case .invalidTransientCredentialEncoding:
            return "The temporary connection credential is invalid. Start Quick Connect again."
        }
    }
}
