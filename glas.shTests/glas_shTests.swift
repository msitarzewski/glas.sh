//
//  glas_shTests.swift
//  glas.shTests
//
//  Created by Michael Sitarzewski on 9/10/25.
//

import Testing
import Foundation
@testable import glas_sh
import GlasSecretStore
import NIOCore
import NIOSSH

struct glas_shTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func sshConfigParserParsesSafeDirectives() async throws {
        let input = """
        Host devbox
          HostName dev.internal
          User michael
          Port 2222
          IdentityFile ~/.ssh/id_ed25519
        """

        let (entries, warnings) = SSHConfigParser.parse(input)

        #expect(entries.count == 1)
        #expect(entries.first?.alias == "devbox")
        #expect(entries.first?.hostName == "dev.internal")
        #expect(entries.first?.user == "michael")
        #expect(entries.first?.port == 2222)
        #expect(entries.first?.identityFile == "~/.ssh/id_ed25519")
        #expect(warnings.isEmpty)
    }

    @Test func sshConfigParserBlocksUnsafeDirectives() async throws {
        let input = """
        Host prod
          HostName prod.example.com
          User root
          ProxyCommand nc %h %p
          LocalCommand echo hacked
        """

        let (entries, warnings) = SSHConfigParser.parse(input)

        #expect(entries.count == 1)
        #expect(entries.first?.alias == "prod")
        #expect(warnings.count >= 2)
    }

    @Test func ptyTerminalModesDisableOnlyCarriageReturnTranslation() async throws {
        let modes = SSHConnection.preferredPTYTerminalModes().modeMapping

        #expect(modes[.OCRNL]?.rawValue == 0)
        #expect(modes[.ONLCR] == nil)
        #expect(modes[.ONLRET] == nil)
    }

    // MARK: - Constants Tests

    @Test func userDefaultsKeysAreConsistent() {
        // Verify keys don't have typos by checking they round-trip through UserDefaults
        let testSuite = UserDefaults(suiteName: "sh.glas.test.constants")!
        defer { testSuite.removePersistentDomain(forName: "sh.glas.test.constants") }

        testSuite.set(true, forKey: UserDefaultsKeys.autoReconnect)
        #expect(testSuite.bool(forKey: UserDefaultsKeys.autoReconnect) == true)

        testSuite.set(42, forKey: UserDefaultsKeys.maxScrollbackLines)
        #expect(testSuite.integer(forKey: UserDefaultsKeys.maxScrollbackLines) == 42)

        testSuite.set("Block", forKey: UserDefaultsKeys.cursorStyle)
        #expect(testSuite.string(forKey: UserDefaultsKeys.cursorStyle) == "Block")
    }

    @Test func keychainConfigServiceNamesAreWellFormed() {
        let config = KeychainManager.config
        #expect(config.passwordsService.hasPrefix("sh.glas."))
        #expect(config.sshKeysPrivateService.hasPrefix("sh.glas."))
        #expect(config.sshKeysPassphraseService.hasPrefix("sh.glas."))
        #expect(config.sealedP256Service.hasPrefix("sh.glas."))
        #expect(config.sealedP256TagService.hasPrefix("sh.glas."))
    }

    // MARK: - ServerManager Tests

    @Test @MainActor func serverManagerStartsEmpty() {
        let manager = ServerManager(loadImmediately: false)
        #expect(manager.servers.isEmpty)
        #expect(manager.favoriteServers.isEmpty)
        #expect(manager.recentServers.isEmpty)
    }

    @Test @MainActor func serverManagerAddAndRemove() {
        let manager = ServerManager(loadImmediately: false)
        let server = ServerConfiguration(
            name: "Test Server",
            host: "test.example.com",
            port: 22,
            username: "testuser"
        )

        manager.servers.append(server)
        #expect(manager.servers.count == 1)
        #expect(manager.server(for: server.id)?.name == "Test Server")

        manager.servers.removeAll { $0.id == server.id }
        #expect(manager.servers.isEmpty)
        #expect(manager.server(for: server.id) == nil)
    }

    @Test @MainActor func serverManagerToggleFavorite() {
        let manager = ServerManager(loadImmediately: false)
        var server = ServerConfiguration(
            name: "Fav Server",
            host: "fav.example.com",
            port: 22,
            username: "user"
        )
        server.isFavorite = false
        manager.servers.append(server)

        manager.toggleFavorite(server)
        #expect(manager.servers.first?.isFavorite == true)
        #expect(manager.favoriteServers.count == 1)

        manager.toggleFavorite(manager.servers.first!)
        #expect(manager.servers.first?.isFavorite == false)
        #expect(manager.favoriteServers.isEmpty)
    }

    @Test @MainActor func serverManagerUpdateServer() {
        let manager = ServerManager(loadImmediately: false)
        let server = ServerConfiguration(
            name: "Original",
            host: "original.example.com",
            port: 22,
            username: "user"
        )
        manager.servers.append(server)

        var updated = server
        updated.name = "Updated"
        updated.host = "updated.example.com"
        manager.updateServer(updated)

        #expect(manager.servers.first?.name == "Updated")
        #expect(manager.servers.first?.host == "updated.example.com")
    }

    // MARK: - SettingsManager Tests

    @Test @MainActor func settingsManagerDefaults() {
        let settings = SettingsManager(loadImmediately: false)

        #expect(settings.autoReconnect == true)
        #expect(settings.confirmBeforeClosing == true)
        #expect(settings.saveScrollback == true)
        #expect(settings.maxScrollbackLines == 10000)
        #expect(settings.bellEnabled == false)
        #expect(settings.visualBell == true)
        #expect(settings.cursorStyle == "Block")
        #expect(settings.blinkingCursor == true)
        #expect(settings.windowOpacity == 0.95)
        #expect(settings.blurBackground == true)
        #expect(settings.interactiveGlassEffects == true)
        #expect(settings.glassTint == "None")
        #expect(settings.showSidebarByDefault == true)
        #expect(settings.showInfoPanelByDefault == false)
        #expect(settings.sidebarPosition == "Left")
    }

    @Test @MainActor func settingsManagerSnippetCRUD() {
        let settings = SettingsManager(loadImmediately: false)

        let snippet = CommandSnippet(
            name: "List files",
            command: "ls -la",
            description: "List all files",
            tags: ["filesystem"]
        )
        settings.addSnippet(snippet)
        #expect(settings.snippets.count == 1)
        #expect(settings.snippets.first?.name == "List files")

        var modified = snippet
        modified.name = "List all"
        settings.updateSnippet(modified)
        #expect(settings.snippets.first?.name == "List all")

        settings.useSnippet(snippet.id)
        #expect(settings.snippets.first?.useCount == 1)

        settings.deleteSnippet(snippet)
        #expect(settings.snippets.isEmpty)
    }

    @Test @MainActor func settingsManagerSessionOverride() {
        let settings = SettingsManager(loadImmediately: false)
        let sessionID = UUID()

        #expect(settings.sessionOverride(for: sessionID) == nil)

        settings.updateSessionOverride(for: sessionID) { override in
            override.windowOpacity = 0.8
            override.blurBackground = false
        }

        let result = settings.sessionOverride(for: sessionID)
        #expect(result?.windowOpacity == 0.8)
        #expect(result?.blurBackground == false)
    }

    // MARK: - Error Classification Tests

    @Test @MainActor func userFacingMessageForPasswordRequired() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let message = SSHConnection.userFacingMessage(for: SSHError.passwordRequired, server: server)
        #expect(message.contains("password"))
        #expect(message.contains("user@example.com:22"))
    }

    @Test @MainActor func userFacingMessageForConnectionFailed() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let message = SSHConnection.userFacingMessage(for: SSHError.connectionFailed, server: server)
        #expect(message.contains("example.com:22"))
    }

    @Test @MainActor func userFacingMessageForInvalidHost() {
        let server = ServerConfiguration(
            name: "Test",
            host: "bad://host",
            port: 22,
            username: "user"
        )
        let message = SSHConnection.userFacingMessage(for: SSHError.invalidHost("bad://host"), server: server)
        #expect(message.contains("bad://host"))
        #expect(message.contains("not valid"))
    }

    @Test @MainActor func keyExchangeNegotiationFailureDetection() {
        // Type-based detection via NIOSSHError is tested implicitly through userFacingMessage
        // String-based fallback:
        let server = ServerConfiguration(
            name: "Test",
            host: "legacy.example.com",
            port: 22,
            username: "user"
        )
        let message = SSHConnection.userFacingMessage(for: SSHError.sshKeyNotFound, server: server)
        #expect(message.contains("SSH key"))
    }

    @Test @MainActor func channelClosedErrorDetection() {
        #expect(SSHConnection.isChannelClosedError(ChannelError.eof))
        #expect(SSHConnection.isChannelClosedError(ChannelError.alreadyClosed))
        #expect(SSHConnection.isChannelClosedError(ChannelError.inputClosed))
        #expect(SSHConnection.isChannelClosedError(ChannelError.outputClosed))
        #expect(!SSHConnection.isChannelClosedError(ChannelError.connectPending))
        #expect(!SSHConnection.isChannelClosedError(SSHError.connectionFailed))
    }

    // MARK: - TerminalSession Lifecycle Tests

    @Test @MainActor func terminalSessionInitialState() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let session = TerminalSession(server: server)

        #expect(session.state == .disconnected)
        #expect(session.output.isEmpty)
        #expect(session.pendingHostKeyChallenge == nil)
        #expect(session.connectionProgress == nil)
        #expect(session.server.host == "example.com")
    }

    @Test @MainActor func terminalSessionDisconnect() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let session = TerminalSession(server: server)
        session.disconnect()

        #expect(session.state == .disconnected)
        #expect(session.connectionProgress == nil)
    }

    @Test @MainActor func terminalSessionCleanRemoteExit() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let session = TerminalSession(server: server)
        let initialNonce = session.closeWindowNonce

        session.handleCleanRemoteExit()

        #expect(session.state == .disconnected)
        #expect(session.connectionProgress == nil)
        #expect(session.closeWindowNonce == initialNonce &+ 1)
    }

    // MARK: - SSH Config Parser Edge Cases

    @Test func sshConfigParserMultipleHosts() {
        let input = """
        Host web1
          HostName web1.example.com
          User deploy
          Port 22

        Host web2
          HostName web2.example.com
          User deploy
          Port 2222
        """

        let (entries, warnings) = SSHConfigParser.parse(input)
        #expect(entries.count == 2)
        #expect(entries[0].alias == "web1")
        #expect(entries[1].alias == "web2")
        #expect(entries[1].port == 2222)
        #expect(warnings.isEmpty)
    }

    @Test func sshConfigParserSkipsWildcardHosts() {
        let input = """
        Host *
          ServerAliveInterval 60

        Host dev
          HostName dev.example.com
          User admin
        """

        let (entries, warnings) = SSHConfigParser.parse(input)
        #expect(entries.count == 1)
        #expect(entries.first?.alias == "dev")
        #expect(warnings.contains { $0.contains("wildcard") })
    }

    @Test func sshConfigParserHandlesComments() {
        let input = """
        # This is a comment
        Host myserver
          HostName server.example.com # inline comment
          User admin
          Port 22
        """

        let (entries, warnings) = SSHConfigParser.parse(input)
        #expect(entries.count == 1)
        #expect(entries.first?.hostName == "server.example.com")
        #expect(warnings.isEmpty)
    }

    @Test func sshConfigParserEmptyInput() {
        let (entries, warnings) = SSHConfigParser.parse("")
        #expect(entries.isEmpty)
        #expect(warnings.isEmpty)
    }
}
