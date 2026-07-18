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
import RealityKitContent
#if canImport(UIKit)
import Combine
import SwiftUI
import UIKit
#endif

private struct LegacyKEXFixture: Error, CustomStringConvertible {
    var description: String { "keyExchangeNegotiationFailure" }
}

@MainActor
private final class TerminalWriteProbe {
    private(set) var writes: [Data] = []

    func receive(_ data: Data) async throws {
        if writes.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        writes.append(data)
    }
}

@MainActor
private final class TerminalResizeProbe {
    private(set) var resizes: [String] = []

    func receive(rows: Int, columns: Int) async throws {
        resizes.append("\(rows)x\(columns)")
        if resizes.count == 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class ServerPasswordProbe {
    var values: [UUID: String] = [:]
    var retrieveError: Error?
    var saveError: Error?
    var deleteError: Error?

    var store: ServerPasswordStore {
        ServerPasswordStore(
            retrieve: { [unowned self] serverID in
                if let retrieveError { throw retrieveError }
                guard let value = values[serverID] else { throw SecretStoreError.notFound }
                return value
            },
            save: { [unowned self] password, serverID in
                if let saveError { throw saveError }
                values[serverID] = password
            },
            delete: { [unowned self] serverID in
                if let deleteError { throw deleteError }
                guard values.removeValue(forKey: serverID) != nil else {
                    throw SecretStoreError.notFound
                }
            }
        )
    }
}

private struct TerminalWriteFailure: Error {}

private enum HostTrustStoreProbeError: Error {
    case injectedFailure
}

private func syntheticOpenSSHPrivateKey(from encodedKey: ByteBuffer) -> String {
    let privateKeyLabel = "PRIVATE" + " KEY"
    return [
        "-----BEGIN OPENSSH \(privateKeyLabel)-----",
        Data(encodedKey.readableBytesView).base64EncodedString(),
        "-----END OPENSSH \(privateKeyLabel)-----",
    ].joined(separator: "\n")
}

private enum CredentialMigrationProbeError: Error {
    case queryFailure
    case persistenceFailure
}

@MainActor
private final class CredentialMigrationProbe {
    var values: [String: Data] = [:]
    var report: CredentialMigrationReport?
    var version = 0
    var failReadAccounts = Set<String>()
    var omitReadbackAccounts = Set<String>()
    var failDeleteAccounts = Set<String>()
    var failDeleteAfterMutationAccounts = Set<String>()
    var failWriteAfterMutationAccounts = Set<String>()
    var replaceAccountBeforeNextAdd: (account: String, data: Data)?
    var replaceAccountOnNextReportSave: (account: String, data: Data)?
    var replaceAccountOnNextCompletedReportSave: (account: String, data: Data)?
    var failReportSave = false
    var writeCount = 0
    var deleteCount = 0

    var store: CredentialMigrationStore {
        CredentialMigrationStore(
            read: { [self] account in
                if failReadAccounts.contains(account) {
                    throw CredentialMigrationProbeError.queryFailure
                }
                if omitReadbackAccounts.contains(account), values[account] != nil {
                    return nil
                }
                return values[account]
            },
            addIfAbsent: { [self] data, account in
                writeCount += 1
                if let replacement = replaceAccountBeforeNextAdd,
                   replacement.account == account {
                    replaceAccountBeforeNextAdd = nil
                    values[account] = replacement.data
                }
                guard values[account] == nil else { return false }
                values[account] = data
                if failWriteAfterMutationAccounts.contains(account) {
                    throw CredentialMigrationProbeError.queryFailure
                }
                return true
            },
            loadReport: { [self] in report },
            saveReport: { [self] value in
                if value.state == .completed,
                   let replacement = replaceAccountOnNextCompletedReportSave {
                    replaceAccountOnNextCompletedReportSave = nil
                    values[replacement.account] = replacement.data
                    throw CredentialMigrationProbeError.persistenceFailure
                }
                if let replacement = replaceAccountOnNextReportSave {
                    replaceAccountOnNextReportSave = nil
                    values[replacement.account] = replacement.data
                    throw CredentialMigrationProbeError.persistenceFailure
                }
                if failReportSave {
                    throw CredentialMigrationProbeError.persistenceFailure
                }
                report = value
            },
            removeReport: { [self] in report = nil },
            loadVersion: { [self] in version },
            saveVersion: { [self] value in version = value }
        )
    }

    var oauthStore: TailscaleOAuthCredentialStore {
        return TailscaleOAuthCredentialStore(
            read: { [self] account in
                if failReadAccounts.contains(account) {
                    throw CredentialMigrationProbeError.queryFailure
                }
                return values[account]
            },
            addIfAbsent: { [self] data, account in
                writeCount += 1
                if let replacement = replaceAccountBeforeNextAdd,
                   replacement.account == account {
                    replaceAccountBeforeNextAdd = nil
                    values[account] = replacement.data
                }
                guard values[account] == nil else { return false }
                values[account] = data
                return true
            },
            delete: { [self] account in
                deleteCount += 1
                if failDeleteAccounts.contains(account) {
                    throw CredentialMigrationProbeError.queryFailure
                }
                values.removeValue(forKey: account)
                if failDeleteAfterMutationAccounts.contains(account) {
                    throw CredentialMigrationProbeError.queryFailure
                }
            }
        )
    }
}

@MainActor
private final class HostTrustStoreProbe {
    var records: [String: PinnedSSHHostKey] = [:]
    var saveCount = 0
    var failSaves = false
    var omitRecordsOnReadback = false

    var store: HostTrustMigrationStore {
        HostTrustMigrationStore(
            save: { [self] record in
                saveCount += 1
                if failSaves {
                    throw HostTrustStoreProbeError.injectedFailure
                }
                records[record.storageAccount] = record
            },
            allRecords: { [self] in
                omitRecordsOnReadback ? [] : Array(records.values)
            }
        )
    }
}

@MainActor
struct glas_shTests {

    @Test @MainActor func terminalEmulatorAppliesCarriageReturnInPlace() {
        let terminal = TerminalEmulator(cols: 40, rows: 4)

        terminal.feed(text: "Progress 10%\rProgress 20%")

        #expect(String(terminal.rows[0].prefix(12)) == "Progress 20%")
        #expect(!terminal.rows[0].contains("Progress 10%"))
    }

    @Test @MainActor func terminalEmulatorRestoresNormalBufferAfterAlternateScreen() {
        let terminal = TerminalEmulator(cols: 20, rows: 4)
        terminal.feed(text: "normal")

        terminal.feed(text: "\u{1B}[?1049h")
        #expect(terminal.isAlternateBufferActive)
        terminal.feed(text: "alternate")
        #expect(terminal.rows.joined().contains("alternate"))

        terminal.feed(text: "\u{1B}[?1049l")
        #expect(!terminal.isAlternateBufferActive)
        #expect(terminal.rows.joined().contains("normal"))
        #expect(!terminal.rows.joined().contains("alternate"))
    }

    @Test @MainActor func terminalEmulatorTracksGeometryAcrossResize() {
        let terminal = TerminalEmulator(cols: 10, rows: 4)
        terminal.feed(text: "abcdefghijklmno")

        terminal.resize(cols: 5, rows: 4)

        #expect(terminal.columns == 5)
        #expect(terminal.rowCount == 4)
        #expect(terminal.cursor.col < terminal.columns)

        terminal.resize(cols: 5, rows: 5)
        #expect(terminal.rowCount == 5)
    }

    @Test @MainActor func terminalEmulatorHandlesFragmentedAndMalformedUTF8() {
        let expected = "A€終B"
        let bytes = Data(expected.utf8)
        for split in 1..<bytes.count {
            let terminal = TerminalEmulator(cols: 20, rows: 2)
            terminal.feed(data: bytes.prefix(split))
            terminal.feed(data: bytes.suffix(from: split))
            let renderedScalars = terminal.styledRows[0]
                .filter { $0.columnWidth > 0 }
                .map(\.scalar)
                .joined()
            #expect(renderedScalars.hasPrefix(expected), "UTF-8 split failed at byte \(split)")
        }

        let malformed = TerminalEmulator(cols: 20, rows: 2)
        malformed.feed(data: Data([0x41, 0xF0, 0x28, 0x8C, 0x28, 0x42]))
        let rendered = malformed.rows.joined()
        #expect(rendered.contains("A"))
        #expect(rendered.contains("B"))
        malformed.feed(text: "C")
        #expect(malformed.rows.joined().contains("C"))
    }

    @Test @MainActor func terminalEmulatorPreservesGraphemesWidthsAndLogicalRTLOrder() {
        let terminal = TerminalEmulator(cols: 20, rows: 2)
        terminal.feed(text: "e\u{301}界ما")

        let cells = terminal.styledRows[0]
        #expect(cells[0].scalar == "e\u{301}")
        #expect(cells[0].columnWidth == 1)
        #expect(cells[1].scalar == "界")
        #expect(cells[1].columnWidth == 2)
        #expect(cells[2].columnWidth == 0)
        #expect(terminal.rows[0].contains("ما"), "SwiftTerm 1.13 preserves RTL input in logical order")
    }

    @Test @MainActor func terminalEmulatorExposesSGRStylesAndColors() {
        let terminal = TerminalEmulator(cols: 10, rows: 2)
        terminal.feed(text: "\u{1B}[1;3;4;38;2;1;2;3;48;2;4;5;6mX\u{1B}[0;7mY")

        let styled = terminal.styledRows[0]
        #expect(styled[0].scalar == "X")
        #expect(styled[0].style.foreground == TerminalRGBColor(red: 1, green: 2, blue: 3))
        #expect(styled[0].style.background == TerminalRGBColor(red: 4, green: 5, blue: 6))
        #expect(styled[0].style.isBold)
        #expect(styled[0].style.isItalic)
        #expect(styled[0].style.isUnderlined)
        #expect(styled[1].scalar == "Y")
        #expect(styled[1].style.isInverse)
    }

    @Test @MainActor func terminalEmulatorExposesProtocolModesAndOutboundReplies() {
        let terminal = TerminalEmulator(cols: 20, rows: 4)

        terminal.feed(text: "\u{1B}[?2004h")
        #expect(terminal.isBracketedPasteModeActive)
        terminal.feed(text: "\u{1B}[?1000h")
        #expect(terminal.mouseReportingMode == .vt200)
        terminal.feed(text: "\u{1B}[>1u")
        #expect(terminal.kittyKeyboardFlagsRawValue == 1)
        terminal.feed(text: "\u{1B}[?2026h")
        #expect(terminal.isSynchronizedOutputActive)
        terminal.feed(text: "synchronized")
        terminal.feed(text: "\u{1B}[?2026l")
        #expect(!terminal.isSynchronizedOutputActive)
        terminal.feed(text: "\u{1B}[6n")
        #expect(!terminal.drainOutboundData().isEmpty)
        #expect(!terminal.outboundDataWasTruncated)
    }

    @Test @MainActor func terminalEmulatorReportsBoundedScrollbackState() {
        let terminal = TerminalEmulator(cols: 20, rows: 3)
        for index in 0..<24 {
            terminal.feed(text: "line-\(index)\r\n")
        }

        #expect(terminal.bufferLineCount > terminal.rowCount)
        #expect(terminal.scrollbackLineCount == terminal.bufferLineCount - terminal.rowCount)
        #expect(terminal.rows.joined().contains("line-23"))
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

    @Test func keychainAccountsAreTerminalNamespacedAndProfileStable() {
        let serverID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        #expect(
            KeychainManager.serverPasswordAccount(for: serverID)
                == "terminal.server-password.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        #expect(KeychainManager.tailscaleAPIKeyAccount == "terminal.tailscale.api-key")
        #expect(KeychainManager.tailscaleOAuthClientIDAccount == "terminal.tailscale.oauth.client-id")
        #expect(KeychainManager.tailscaleOAuthClientSecretAccount == "terminal.tailscale.oauth.client-secret")
        #expect(KeychainManager.tailscaleOAuthCredentialsAccount == "terminal.tailscale.oauth.credentials")
    }

    private func migrationServer(
        id: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        host: String = "terminal.example.com"
    ) -> ServerConfiguration {
        ServerConfiguration(id: id, name: "Terminal", host: host, username: "operator")
    }

    @Test func credentialMigrationCopiesOnlyExclusiveServerAndShippedTailscaleCredentials() throws {
        let server = migrationServer()
        let probe = CredentialMigrationProbe()
        let legacyServer = KeychainManager.legacyServerPasswordAccount(for: server)
        probe.values[legacyServer] = Data("terminal-password".utf8)
        probe.values[KeychainManager.legacyTailscaleAPIKeyAccount] = Data("ts-api".utf8)
        probe.values[KeychainManager.legacyTailscaleOAuthClientIDAccount] = Data("client-id".utf8)
        probe.values[KeychainManager.legacyTailscaleOAuthClientSecretAccount] = Data("client-secret".utf8)

        let first = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )

        #expect(first.state == .completed)
        #expect(first.exclusiveServerTupleCount == 1)
        #expect(first.migratedServerDestinationCount == 1)
        #expect(first.tailscaleLegacySourceCount == 3)
        #expect(first.tailscaleMigratedCredentialCount == 2)
        #expect(probe.values[KeychainManager.serverPasswordAccount(for: server.id)] == Data("terminal-password".utf8))
        #expect(probe.values[KeychainManager.tailscaleAPIKeyAccount] == Data("ts-api".utf8))
        #expect(probe.values[legacyServer] == Data("terminal-password".utf8))
        #expect(probe.values[KeychainManager.legacyTailscaleAPIKeyAccount] == Data("ts-api".utf8))
        #expect(probe.version == KeychainManager.currentCredentialMigrationVersion)

        let writesAfterFirstRun = probe.writeCount
        let second = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )
        #expect(second == first)
        #expect(probe.writeCount == writesAfterFirstRun)
    }

    @Test func credentialMigrationRetainsAmbiguousAndUnavailableMetadataServerTuples() throws {
        let server = migrationServer()
        let legacy = KeychainManager.legacyServerPasswordAccount(for: server)

        let ambiguous = CredentialMigrationProbe()
        ambiguous.values[legacy] = Data("shared".utf8)
        let ambiguousReport = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: [legacy]),
            store: ambiguous.store
        )
        #expect(ambiguousReport.ambiguousServerTupleCount == 1)
        #expect(ambiguous.values[legacy] == Data("shared".utf8))
        #expect(ambiguous.values[KeychainManager.serverPasswordAccount(for: server.id)] == nil)

        let unavailable = CredentialMigrationProbe()
        unavailable.values[legacy] = Data("unknown-owner".utf8)
        let unavailableReport = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .unavailable,
            store: unavailable.store
        )
        #expect(unavailableReport.unavailableMetadataTupleCount == 1)
        #expect(unavailable.values[legacy] == Data("unknown-owner".utf8))
        #expect(unavailable.values[KeychainManager.serverPasswordAccount(for: server.id)] == nil)
    }

    @Test func credentialMigrationDeduplicatesMatchingDestinationAndRetainsConflicts() throws {
        let server = migrationServer()
        let legacy = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)

        let matching = CredentialMigrationProbe()
        matching.values[legacy] = Data("same".utf8)
        matching.values[destination] = Data("same".utf8)
        let matchingReport = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: matching.store
        )
        #expect(matchingReport.alreadyPresentDestinationCount == 1)
        #expect(matchingReport.migratedServerDestinationCount == 0)
        #expect(matching.values[legacy] == Data("same".utf8))

        let conflicting = CredentialMigrationProbe()
        conflicting.values[legacy] = Data("legacy".utf8)
        conflicting.values[destination] = Data("canonical".utf8)
        let conflictReport = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: conflicting.store
        )
        #expect(conflictReport.conflictCount == 1)
        #expect(conflicting.values[legacy] == Data("legacy".utf8))
        #expect(conflicting.values[destination] == Data("canonical".utf8))
    }

    @Test func credentialMigrationCountsDuplicateProfilesDeterministically() throws {
        let first = migrationServer()
        let second = migrationServer(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let legacy = KeychainManager.legacyServerPasswordAccount(for: first)
        let probe = CredentialMigrationProbe()
        probe.values[legacy] = Data("shared-terminal-password".utf8)

        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [second, first],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )

        #expect(report.serverProfileCount == 2)
        #expect(report.uniqueServerTupleCount == 1)
        #expect(report.duplicateServerProfileCount == 1)
        #expect(report.migratedServerDestinationCount == 2)
        #expect(probe.values[KeychainManager.serverPasswordAccount(for: first.id)] == Data("shared-terminal-password".utf8))
        #expect(probe.values[KeychainManager.serverPasswordAccount(for: second.id)] == Data("shared-terminal-password".utf8))
        #expect(probe.values[legacy] == Data("shared-terminal-password".utf8))
    }

    @Test func credentialMigrationQueryFailureDoesNotMutateOrAdvance() {
        let server = migrationServer()
        let probe = CredentialMigrationProbe()
        let legacy = KeychainManager.legacyServerPasswordAccount(for: server)
        probe.values[legacy] = Data("secret".utf8)
        probe.failReadAccounts.insert(legacy)

        #expect(throws: CredentialMigrationProbeError.self) {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
        }
        #expect(probe.values[legacy] == Data("secret".utf8))
        #expect(probe.values[KeychainManager.serverPasswordAccount(for: server.id)] == nil)
        #expect(probe.version == 0)
        #expect(probe.report?.state == .failed)
    }

    @Test func credentialMigrationReadbackFailurePreservesUnverifiableDestinationAndRemainsRetryable() throws {
        let server = migrationServer()
        let probe = CredentialMigrationProbe()
        let legacy = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        probe.values[legacy] = Data("secret".utf8)
        probe.omitReadbackAccounts.insert(destination)

        #expect(throws: CredentialMigrationError.self) {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
        }
        #expect(probe.values[legacy] == Data("secret".utf8))
        // A missing readback cannot distinguish an absent destination from a
        // concealed or concurrently replaced value. Rollback must not delete it.
        #expect(probe.values[destination] == Data("secret".utf8))
        #expect(probe.version == 0)
        #expect(probe.report?.failureCode == CredentialMigrationError.keychainReadbackMismatch.code)

        probe.omitReadbackAccounts.remove(destination)
        let retry = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )
        #expect(retry.state == .completed)
        #expect(probe.values[destination] == Data("secret".utf8))
        #expect(probe.values[legacy] == Data("secret".utf8))
    }

    @Test func credentialMigrationReportFailureRollsBackBeforeSourceDeletion() {
        let server = migrationServer()
        let probe = CredentialMigrationProbe()
        let legacy = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        probe.values[legacy] = Data("secret".utf8)
        probe.failReportSave = true

        #expect(throws: CredentialMigrationProbeError.self) {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
        }
        #expect(probe.values[legacy] == Data("secret".utf8))
        #expect(probe.values[destination] == Data("secret".utf8))
        #expect(probe.version == 0)
    }

    @Test func credentialMigrationNeverQueriesOrDeletesForwardMigratedSources() throws {
        let probe = CredentialMigrationProbe()
        let clientIDAccount = KeychainManager.tailscaleOAuthClientIDAccount
        let clientSecretAccount = KeychainManager.tailscaleOAuthClientSecretAccount
        let destination = KeychainManager.tailscaleOAuthCredentialsAccount
        probe.values[clientIDAccount] = Data("client-id".utf8)
        probe.values[clientSecretAccount] = Data("client-secret".utf8)
        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [],
            metadata: .unavailable,
            store: probe.store
        )
        #expect(probe.values[clientIDAccount] == Data("client-id".utf8))
        #expect(probe.values[clientSecretAccount] == Data("client-secret".utf8))
        #expect(probe.values[destination] != nil)
        #expect(report.deletedLegacySourceCount == 0)
        #expect(probe.deleteCount == 0)
        #expect(probe.version == KeychainManager.currentCredentialMigrationVersion)
    }

    @Test func credentialMigrationDoesNotInvokeDestructiveSourceAdapter() throws {
        let server = migrationServer()
        let source = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        let probe = CredentialMigrationProbe()
        probe.values[source] = Data("terminal-password".utf8)
        probe.failDeleteAfterMutationAccounts.insert(source)

        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == Data("terminal-password".utf8))
        #expect(report.deletedLegacySourceCount == 0)
        #expect(probe.deleteCount == 0)
    }

    @Test func credentialMigrationWriteFailureAfterMutationPreservesForwardDestinationAndRetries() throws {
        let server = migrationServer()
        let source = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        let probe = CredentialMigrationProbe()
        probe.values[source] = Data("terminal-password".utf8)
        probe.failWriteAfterMutationAccounts.insert(destination)

        #expect(throws: CredentialMigrationProbeError.self) {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
        }
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == Data("terminal-password".utf8))
        #expect(probe.version == 0)

        probe.failWriteAfterMutationAccounts.remove(destination)
        let retry = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )
        #expect(retry.state == .completed)
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == Data("terminal-password".utf8))
    }

    @Test func credentialMigrationAtomicAddPreservesConcurrentDestination() throws {
        let server = migrationServer()
        let source = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        let replacement = Data("concurrent-owner-value".utf8)
        let probe = CredentialMigrationProbe()
        probe.values[source] = Data("terminal-password".utf8)
        probe.replaceAccountBeforeNextAdd = (destination, replacement)

        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [server],
            metadata: .available(glassDBLegacyPasswordAccounts: []),
            store: probe.store
        )

        #expect(report.state == .completed)
        #expect(report.conflictCount == 1)
        #expect(report.migratedServerDestinationCount == 0)
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == replacement)
    }

    @Test func credentialMigrationFailurePreservesConcurrentDestinationReplacement() {
        let server = migrationServer()
        let source = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        let replacement = Data("concurrent-owner-value".utf8)
        let probe = CredentialMigrationProbe()
        probe.values[source] = Data("terminal-password".utf8)
        probe.replaceAccountOnNextReportSave = (destination, replacement)

        do {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
            Issue.record("A concurrent destination replacement must surface the injected failure")
        } catch CredentialMigrationProbeError.persistenceFailure {
            // Expected.
        } catch {
            Issue.record("Expected persistenceFailure, received \(error)")
        }
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == replacement)
        #expect(probe.version == 0)
    }

    @Test func credentialMigrationFailureRetainsOriginalSourceAndForwardDestination() {
        let server = migrationServer()
        let source = KeychainManager.legacyServerPasswordAccount(for: server)
        let destination = KeychainManager.serverPasswordAccount(for: server.id)
        let probe = CredentialMigrationProbe()
        probe.values[source] = Data("terminal-password".utf8)
        probe.replaceAccountOnNextCompletedReportSave = (
            destination,
            Data("terminal-password".utf8)
        )

        do {
            try KeychainManager.runCredentialMigrationIfNeeded(
                servers: [server],
                metadata: .available(glassDBLegacyPasswordAccounts: []),
                store: probe.store
            )
            Issue.record("The injected completed-report failure must be surfaced")
        } catch CredentialMigrationProbeError.persistenceFailure {
            // Expected; neither side is destructively rolled back.
        } catch {
            Issue.record("Expected persistenceFailure, received \(error)")
        }
        #expect(probe.values[source] == Data("terminal-password".utf8))
        #expect(probe.values[destination] == Data("terminal-password".utf8))
        #expect(probe.version == 0)
    }

    @Test func credentialMigrationBundlesTerminalScopedOAuthAndIsIdempotent() throws {
        let probe = CredentialMigrationProbe()
        let clientIDAccount = KeychainManager.tailscaleOAuthClientIDAccount
        let clientSecretAccount = KeychainManager.tailscaleOAuthClientSecretAccount
        let destination = KeychainManager.tailscaleOAuthCredentialsAccount
        probe.values[clientIDAccount] = Data("scoped-client-id".utf8)
        probe.values[clientSecretAccount] = Data("scoped-client-secret".utf8)

        let first = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [],
            metadata: .unavailable,
            store: probe.store
        )
        let bundle = try #require(probe.values[destination])
        let decoded = try #require(
            JSONSerialization.jsonObject(with: bundle) as? [String: String]
        )

        #expect(first.state == .completed)
        #expect(first.tailscaleLegacySourceCount == 2)
        #expect(first.tailscaleMigratedCredentialCount == 1)
        #expect(first.verifiedDestinationCount == 1)
        #expect(first.deletedLegacySourceCount == 0)
        #expect(decoded == [
            "clientID": "scoped-client-id",
            "clientSecret": "scoped-client-secret"
        ])
        let reportText = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!reportText.contains("scoped-client-id"))
        #expect(!reportText.contains("scoped-client-secret"))
        #expect(probe.values[clientIDAccount] == Data("scoped-client-id".utf8))
        #expect(probe.values[clientSecretAccount] == Data("scoped-client-secret".utf8))

        let writesAfterFirstRun = probe.writeCount
        let second = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [],
            metadata: .unavailable,
            store: probe.store
        )
        #expect(second == first)
        #expect(probe.writeCount == writesAfterFirstRun)
    }

    @Test func credentialMigrationPreservesOAuthSplitSourcesOnDestinationConflict() throws {
        let probe = CredentialMigrationProbe()
        let clientIDAccount = KeychainManager.tailscaleOAuthClientIDAccount
        let clientSecretAccount = KeychainManager.tailscaleOAuthClientSecretAccount
        let destination = KeychainManager.tailscaleOAuthCredentialsAccount
        let destinationData = try JSONSerialization.data(withJSONObject: [
            "clientID": "canonical-client-id",
            "clientSecret": "canonical-client-secret"
        ], options: [.sortedKeys])
        probe.values[clientIDAccount] = Data("split-client-id".utf8)
        probe.values[clientSecretAccount] = Data("split-client-secret".utf8)
        probe.values[destination] = destinationData

        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [],
            metadata: .unavailable,
            store: probe.store
        )

        #expect(report.state == .completed)
        #expect(report.conflictCount == 1)
        #expect(report.deletedLegacySourceCount == 0)
        #expect(probe.values[clientIDAccount] == Data("split-client-id".utf8))
        #expect(probe.values[clientSecretAccount] == Data("split-client-secret".utf8))
        #expect(probe.values[destination] == destinationData)
    }

    @Test func credentialMigrationPreservesConflictingOAuthSourcePairs() throws {
        let probe = CredentialMigrationProbe()
        probe.values[KeychainManager.legacyTailscaleOAuthClientIDAccount] = Data("legacy-id".utf8)
        probe.values[KeychainManager.legacyTailscaleOAuthClientSecretAccount] = Data("legacy-secret".utf8)
        probe.values[KeychainManager.tailscaleOAuthClientIDAccount] = Data("scoped-id".utf8)
        probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] = Data("scoped-secret".utf8)

        let report = try KeychainManager.runCredentialMigrationIfNeeded(
            servers: [],
            metadata: .unavailable,
            store: probe.store
        )

        #expect(report.state == .completed)
        #expect(report.conflictCount == 1)
        #expect(report.deletedLegacySourceCount == 0)
        #expect(probe.values[KeychainManager.legacyTailscaleOAuthClientIDAccount] == Data("legacy-id".utf8))
        #expect(probe.values[KeychainManager.legacyTailscaleOAuthClientSecretAccount] == Data("legacy-secret".utf8))
        #expect(probe.values[KeychainManager.tailscaleOAuthClientIDAccount] == Data("scoped-id".utf8))
        #expect(probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] == Data("scoped-secret".utf8))
        #expect(probe.values[KeychainManager.tailscaleOAuthCredentialsAccount] == nil)
    }

    @Test func oauthReadSideMigrationVerifiesBundleAndRetainsSplitSources() throws {
        let probe = CredentialMigrationProbe()
        probe.values[KeychainManager.tailscaleOAuthClientIDAccount] = Data("client-id".utf8)
        probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] = Data("client-secret".utf8)

        let credentials = try KeychainManager.retrieveTailscaleOAuthCredentials(store: probe.oauthStore)

        #expect(credentials.clientID == "client-id")
        #expect(credentials.clientSecret == "client-secret")
        #expect(probe.values[KeychainManager.tailscaleOAuthCredentialsAccount] != nil)
        #expect(probe.values[KeychainManager.tailscaleOAuthClientIDAccount] == Data("client-id".utf8))
        #expect(probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] == Data("client-secret".utf8))
    }

    @Test func oauthReadSideMigrationDoesNotInvokeDestructiveSplitCleanup() throws {
        let probe = CredentialMigrationProbe()
        let clientIDAccount = KeychainManager.tailscaleOAuthClientIDAccount
        let clientSecretAccount = KeychainManager.tailscaleOAuthClientSecretAccount
        probe.values[clientIDAccount] = Data("client-id".utf8)
        probe.values[clientSecretAccount] = Data("client-secret".utf8)
        probe.failDeleteAfterMutationAccounts.insert(clientSecretAccount)

        let credentials = try KeychainManager.retrieveTailscaleOAuthCredentials(store: probe.oauthStore)
        #expect(credentials.clientID == "client-id")
        #expect(credentials.clientSecret == "client-secret")
        #expect(probe.values[KeychainManager.tailscaleOAuthCredentialsAccount] != nil)
        #expect(probe.values[clientIDAccount] == Data("client-id".utf8))
        #expect(probe.values[clientSecretAccount] == Data("client-secret".utf8))
        #expect(probe.deleteCount == 0)
    }

    @Test func oauthReadSideMigrationAtomicAddPreservesConcurrentBundle() throws {
        let probe = CredentialMigrationProbe()
        let destination = KeychainManager.tailscaleOAuthCredentialsAccount
        let replacement = try JSONSerialization.data(withJSONObject: [
            "clientID": "concurrent-id",
            "clientSecret": "concurrent-secret",
        ])
        probe.values[KeychainManager.tailscaleOAuthClientIDAccount] = Data("split-id".utf8)
        probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] = Data("split-secret".utf8)
        probe.replaceAccountBeforeNextAdd = (destination, replacement)

        #expect(throws: CredentialMigrationError.self) {
            try KeychainManager.retrieveTailscaleOAuthCredentials(store: probe.oauthStore)
        }
        #expect(probe.values[destination] == replacement)
        #expect(probe.values[KeychainManager.tailscaleOAuthClientIDAccount] == Data("split-id".utf8))
        #expect(probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] == Data("split-secret".utf8))
    }

    @Test func oauthDeleteAttemptsEveryAccountAndRetryRemovesPartialFailure() throws {
        let probe = CredentialMigrationProbe()
        let accounts = [
            KeychainManager.tailscaleOAuthCredentialsAccount,
            KeychainManager.tailscaleOAuthClientIDAccount,
            KeychainManager.tailscaleOAuthClientSecretAccount,
        ]
        for account in accounts {
            probe.values[account] = Data("credential".utf8)
        }
        probe.failDeleteAccounts.insert(KeychainManager.tailscaleOAuthClientIDAccount)

        #expect(throws: CredentialMigrationProbeError.self) {
            try KeychainManager.deleteTailscaleOAuthCredentials(store: probe.oauthStore)
        }
        #expect(probe.values[KeychainManager.tailscaleOAuthCredentialsAccount] == nil)
        #expect(probe.values[KeychainManager.tailscaleOAuthClientIDAccount] != nil)
        #expect(probe.values[KeychainManager.tailscaleOAuthClientSecretAccount] == nil)

        probe.failDeleteAccounts.remove(KeychainManager.tailscaleOAuthClientIDAccount)
        try KeychainManager.deleteTailscaleOAuthCredentials(store: probe.oauthStore)
        #expect(accounts.allSatisfy { probe.values[$0] == nil })
    }

    // MARK: - ServerManager Tests

    @Test func serverDeletionPersistsMetadataFirstAndRestoresItOnKeychainFailure() throws {
        let suiteName = "sh.glas.test.server-delete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = migrationServer()
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "original-secret"
        var observedPersistedRemoval = false
        let baseStore = passwordProbe.store
        let failingStore = ServerPasswordStore(
            retrieve: baseStore.retrieve,
            save: baseStore.save,
            delete: { _ in
                let data = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
                let persisted = try JSONDecoder().decode([ServerConfiguration].self, from: data)
                observedPersistedRemoval = persisted.isEmpty
                throw CredentialMigrationProbeError.queryFailure
            }
        )
        let manager = ServerManager(
            loadImmediately: false,
            defaults: defaults,
            passwordStore: failingStore
        )
        manager.servers = [server]
        try manager.persistServersOrThrow()

        #expect(throws: CredentialMigrationProbeError.self) {
            try manager.deleteServer(server)
        }
        #expect(observedPersistedRemoval)
        #expect(manager.servers == [server])
        #expect(passwordProbe.values[server.id] == "original-secret")
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
        let restoredData = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
        #expect(try JSONDecoder().decode([ServerConfiguration].self, from: restoredData) == [server])
    }

    @Test func serverPasswordCreateRestoresExactPriorUUIDSecretWhenMetadataReadbackFails() throws {
        let suiteName = "sh.glas.test.server-create-rollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([ServerConfiguration]()), forKey: UserDefaultsKeys.servers)

        let server = migrationServer()
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "preexisting-secret"
        var writeCount = 0
        let manager = ServerManager(
            loadImmediately: false,
            defaults: defaults,
            passwordStore: passwordProbe.store,
            serverDataWriter: { data in
                writeCount += 1
                if writeCount > 1 {
                    defaults.set(data, forKey: UserDefaultsKeys.servers)
                }
            }
        )

        #expect(throws: ServerManagerError.persistenceReadbackMismatch) {
            try manager.addServerOrThrow(server, password: "replacement-secret")
        }
        #expect(manager.servers.isEmpty)
        #expect(passwordProbe.values[server.id] == "preexisting-secret")
        let persistedData = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
        #expect(try JSONDecoder().decode([ServerConfiguration].self, from: persistedData).isEmpty)
    }

    @Test func serverPasswordEditRestoresExactOldSecretWhenMetadataReadbackFails() throws {
        let suiteName = "sh.glas.test.server-edit-rollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = migrationServer()
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "old-secret"
        var updatedServer = server
        updatedServer.name = "Updated"
        var writeCount = 0
        let manager = ServerManager(
            loadImmediately: false,
            defaults: defaults,
            passwordStore: passwordProbe.store,
            serverDataWriter: { data in
                writeCount += 1
                if writeCount > 1 {
                    defaults.set(data, forKey: UserDefaultsKeys.servers)
                }
            }
        )
        manager.servers = [server]

        #expect(throws: ServerManagerError.persistenceReadbackMismatch) {
            try manager.updateServerOrThrow(updatedServer, password: "new-secret")
        }
        #expect(manager.servers == [server])
        #expect(passwordProbe.values[server.id] == "old-secret")
        let persistedData = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
        #expect(try JSONDecoder().decode([ServerConfiguration].self, from: persistedData) == [server])
    }

    @Test func passwordAuthChangeRestoresProfileAndSecretWhenDeletionFails() throws {
        let suiteName = "sh.glas.test.password-auth-rollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = migrationServer()
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "old-secret"
        let baseStore = passwordProbe.store
        var observedCommittedMetadata = false
        let failingStore = ServerPasswordStore(
            retrieve: baseStore.retrieve,
            save: baseStore.save,
            delete: { _ in
                let data = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
                let persisted = try JSONDecoder().decode([ServerConfiguration].self, from: data)
                observedCommittedMetadata = persisted.first?.authMethod == .sshKey
                throw CredentialMigrationProbeError.queryFailure
            }
        )
        let manager = ServerManager(
            loadImmediately: false,
            defaults: defaults,
            passwordStore: failingStore
        )
        manager.servers = [server]
        var updatedServer = server
        updatedServer.authMethod = .sshKey
        updatedServer.sshKeyID = UUID()

        #expect(throws: CredentialMigrationProbeError.self) {
            try manager.updateServerOrThrow(updatedServer)
        }
        #expect(observedCommittedMetadata)
        #expect(manager.servers == [server])
        #expect(passwordProbe.values[server.id] == "old-secret")
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
        let persistedData = try #require(defaults.data(forKey: UserDefaultsKeys.servers))
        #expect(try JSONDecoder().decode([ServerConfiguration].self, from: persistedData) == [server])
    }

    @Test func serverDeletionRecoveryPreservesLiveProfileWhenCrashPrecedesMetadataCommit() throws {
        let suiteName = "sh.glas.test.server-delete-precommit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = migrationServer()
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        let journal = ServerCredentialDeletionJournal(
            version: ServerCredentialDeletionJournal.currentVersion,
            entries: [.init(serverID: server.id, operation: .deleteServer, createdAt: Date())]
        )
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: ServerManager.credentialDeletionJournalDefaultsKey
        )
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "live-secret"

        let restarted = ServerManager(
            defaults: defaults,
            passwordStore: passwordProbe.store
        )

        #expect(restarted.servers == [server])
        #expect(passwordProbe.values[server.id] == "live-secret")
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
    }

    @Test func serverDeletionRecoveryRemovesOrphanWhenCrashFollowsMetadataCommit() throws {
        let suiteName = "sh.glas.test.server-delete-postcommit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = migrationServer()
        defaults.set(try JSONEncoder().encode([ServerConfiguration]()), forKey: UserDefaultsKeys.servers)
        let journal = ServerCredentialDeletionJournal(
            version: ServerCredentialDeletionJournal.currentVersion,
            entries: [.init(serverID: server.id, operation: .deleteServer, createdAt: Date())]
        )
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: ServerManager.credentialDeletionJournalDefaultsKey
        )
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "orphan-secret"

        let restarted = ServerManager(
            defaults: defaults,
            passwordStore: passwordProbe.store
        )

        #expect(restarted.servers.isEmpty)
        #expect(passwordProbe.values[server.id] == nil)
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
    }

    @Test func passwordAuthChangeRecoveryPreservesSecretWhenCrashPrecedesMetadataCommit() throws {
        let suiteName = "sh.glas.test.password-auth-precommit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let server = migrationServer()
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        let journal = ServerCredentialDeletionJournal(
            version: ServerCredentialDeletionJournal.currentVersion,
            entries: [.init(
                serverID: server.id,
                operation: .removePasswordAuthentication,
                createdAt: Date()
            )]
        )
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: ServerManager.credentialDeletionJournalDefaultsKey
        )
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[server.id] = "live-password"

        let restarted = ServerManager(
            defaults: defaults,
            passwordStore: passwordProbe.store
        )

        #expect(restarted.servers == [server])
        #expect(passwordProbe.values[server.id] == "live-password")
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
    }

    @Test func passwordAuthChangeRecoveryRemovesOrphanWhenCrashFollowsMetadataCommit() throws {
        let suiteName = "sh.glas.test.password-auth-postcommit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var server = migrationServer()
        let serverID = server.id
        server.authMethod = .sshKey
        server.sshKeyID = UUID()
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        let journal = ServerCredentialDeletionJournal(
            version: ServerCredentialDeletionJournal.currentVersion,
            entries: [.init(
                serverID: serverID,
                operation: .removePasswordAuthentication,
                createdAt: Date()
            )]
        )
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: ServerManager.credentialDeletionJournalDefaultsKey
        )
        let passwordProbe = ServerPasswordProbe()
        passwordProbe.values[serverID] = "orphan-password"

        let restarted = ServerManager(
            defaults: defaults,
            passwordStore: passwordProbe.store
        )

        #expect(restarted.servers == [server])
        #expect(passwordProbe.values[serverID] == nil)
        #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
    }

    @Test func serverCredentialRecoveryRetainsSecretWhenCatalogIsAmbiguous() throws {
        let server = migrationServer()
        let fixtures: [(String, Data?)] = [
            ("missing", nil),
            ("malformed", Data("not-json".utf8)),
            ("oversized", Data(repeating: 0, count: ServerManager.maximumServerCatalogBytes + 1))
        ]

        for (label, catalogData) in fixtures {
            let suiteName = "sh.glas.test.server-catalog-\(label).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            if let catalogData {
                defaults.set(catalogData, forKey: UserDefaultsKeys.servers)
            }
            let journal = ServerCredentialDeletionJournal(
                version: ServerCredentialDeletionJournal.currentVersion,
                entries: [.init(
                    serverID: server.id,
                    operation: .deleteServer,
                    createdAt: Date()
                )]
            )
            defaults.set(
                try JSONEncoder().encode(journal),
                forKey: ServerManager.credentialDeletionJournalDefaultsKey
            )
            let passwordProbe = ServerPasswordProbe()
            passwordProbe.values[server.id] = "must-survive"

            let restarted = ServerManager(
                defaults: defaults,
                passwordStore: passwordProbe.store
            )

            #expect(restarted.servers.isEmpty)
            #expect(passwordProbe.values[server.id] == "must-survive")
            #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) != nil)
        }
    }

    @Test func invalidServerCatalogBlocksAddUpdateDeleteAndCredentialAccess() throws {
        let fixtures: [(String, Any)] = [
            ("malformed", Data("not-json".utf8)),
            ("oversized", Data(repeating: 0, count: ServerManager.maximumServerCatalogBytes + 1)),
            ("wrong-type", "not-data")
        ]

        for (label, persistedValue) in fixtures {
            let suiteName = "sh.glas.test.server-fail-closed-\(label).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(persistedValue, forKey: UserDefaultsKeys.servers)

            var credentialReads = 0
            var credentialWrites = 0
            var credentialDeletes = 0
            var catalogWrites = 0
            let passwordStore = ServerPasswordStore(
                retrieve: { _ in
                    credentialReads += 1
                    throw SecretStoreError.notFound
                },
                save: { _, _ in credentialWrites += 1 },
                delete: { _ in credentialDeletes += 1 }
            )
            let manager = ServerManager(
                defaults: defaults,
                passwordStore: passwordStore,
                serverDataWriter: { _ in catalogWrites += 1 }
            )
            let server = migrationServer()

            #expect(manager.serverCatalogLoadError == .invalidServerCatalog)
            #expect(throws: ServerManagerError.invalidServerCatalog) {
                try manager.addServerOrThrow(server, password: "must-not-be-stored")
            }

            // Exercise update and delete from a populated in-memory view to prove
            // the retained failure state, not an empty array, is the mutation gate.
            manager.servers = [server]
            var updated = server
            updated.name = "Must not persist"
            #expect(throws: ServerManagerError.invalidServerCatalog) {
                try manager.updateServerOrThrow(updated, password: "must-not-be-stored")
            }
            #expect(throws: ServerManagerError.invalidServerCatalog) {
                try manager.deleteServer(server)
            }

            #expect(manager.servers == [server])
            #expect(credentialReads == 0)
            #expect(credentialWrites == 0)
            #expect(credentialDeletes == 0)
            #expect(catalogWrites == 0)
            #expect(defaults.object(forKey: UserDefaultsKeys.servers) as? String
                == persistedValue as? String)
            if let originalData = persistedValue as? Data {
                #expect(defaults.data(forKey: UserDefaultsKeys.servers) == originalData)
            }
            #expect(defaults.data(forKey: ServerManager.credentialDeletionJournalDefaultsKey) == nil)
        }
    }

    @Test func invalidSSHKeyCatalogBlocksAddRenameDeleteAndSecretAccess() throws {
        let fixtures: [(String, Any)] = [
            ("malformed", Data("not-json".utf8)),
            ("oversized", Data(repeating: 0, count: SettingsManager.maximumSSHKeyCatalogBytes + 1)),
            ("wrong-type", ["not": "data"])
        ]

        var encodedKey = ByteBuffer()
        encodedKey.writeString("openssh-key-v1\0")
        for value in ["none", "none", ""] {
            encodedKey.writeInteger(UInt32(value.utf8.count), endianness: .big)
            encodedKey.writeString(value)
        }
        encodedKey.writeInteger(UInt32(1), endianness: .big)
        encodedKey.writeInteger(UInt32(15), endianness: .big)
        encodedKey.writeInteger(UInt32("ssh-ed25519".utf8.count), endianness: .big)
        encodedKey.writeString("ssh-ed25519")
        let privateKey = syntheticOpenSSHPrivateKey(from: encodedKey)

        for (label, persistedValue) in fixtures {
            let suiteName = "sh.glas.test.ssh-key-fail-closed-\(label).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(persistedValue, forKey: UserDefaultsKeys.sshKeys)

            var secretReads = 0
            var secretWrites = 0
            var secretDeletes = 0
            var catalogWrites = 0
            let lifecycle = SSHKeyLifecycleStore(
                retrieve: { _ in
                    secretReads += 1
                    return nil
                },
                delete: { _ in secretDeletes += 1 },
                restore: { _, _ in secretWrites += 1 },
                addIfAbsent: { _, _ in
                    secretWrites += 1
                    return true
                }
            )
            let settings = SettingsManager(
                settingsDefaults: defaults,
                sshKeyDefaults: defaults,
                sshKeyLifecycleStore: lifecycle,
                sshKeyCatalogWriter: { _ in catalogWrites += 1 }
            )
            let existingKey = StoredSSHKey(
                name: "Retained",
                algorithm: "Ed25519",
                storageKind: .imported,
                algorithmKind: .ed25519,
                migrationState: .migrated
            )

            #expect(settings.sshKeyCatalogLoadError != nil)
            #expect(throws: SettingsPersistenceError.self) {
                try settings.addSSHKey(
                    name: "Must not persist",
                    privateKey: privateKey,
                    passphrase: nil
                )
            }

            settings.sshKeys = [existingKey]
            #expect(throws: SettingsPersistenceError.self) {
                try settings.renameSSHKeyOrThrow(existingKey.id, name: "Must not rename")
            }
            #expect(throws: SettingsPersistenceError.self) {
                try settings.deleteSSHKey(existingKey.id)
            }

            #expect(settings.sshKeys == [existingKey])
            #expect(secretReads == 0)
            #expect(secretWrites == 0)
            #expect(secretDeletes == 0)
            #expect(catalogWrites == 0)
            if let originalData = persistedValue as? Data {
                #expect(defaults.data(forKey: UserDefaultsKeys.sshKeys) == originalData)
            } else {
                #expect(defaults.object(forKey: UserDefaultsKeys.sshKeys) as? [String: String]
                    == persistedValue as? [String: String])
            }
            #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil)
        }
    }

    @Test func importedSSHKeyCreationVerifiesCatalogAndDeletesSecretOnRollback() throws {
        let suiteName = "sh.glas.test.ssh-key-create-rollback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([StoredSSHKey]()), forKey: UserDefaultsKeys.sshKeys)

        var encodedKey = ByteBuffer()
        encodedKey.writeString("openssh-key-v1\0")
        for value in ["none", "none", ""] {
            encodedKey.writeInteger(UInt32(value.utf8.count), endianness: .big)
            encodedKey.writeString(value)
        }
        encodedKey.writeInteger(UInt32(1), endianness: .big)
        encodedKey.writeInteger(UInt32(15), endianness: .big)
        encodedKey.writeInteger(UInt32("ssh-ed25519".utf8.count), endianness: .big)
        encodedKey.writeString("ssh-ed25519")
        let privateKey = syntheticOpenSSHPrivateKey(from: encodedKey)

        var storedMaterial: SSHKeyMaterial?
        let lifecycle = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in storedMaterial = nil },
            restore: { _, material in storedMaterial = material },
            addIfAbsent: { _, material in
                guard case nil = storedMaterial else { return false }
                storedMaterial = material
                return true
            }
        )
        var catalogWrites = 0
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycle,
            sshKeyCatalogWriter: { data in
                catalogWrites += 1
                defaults.set(
                    catalogWrites == 1 ? Data("malformed".utf8) : data,
                    forKey: UserDefaultsKeys.sshKeys
                )
            }
        )

        #expect(throws: SettingsPersistenceError.self) {
            try settings.addSSHKey(name: "Rollback", privateKey: privateKey, passphrase: nil)
        }
        #expect(settings.sshKeys.isEmpty)
        #expect(storedMaterial == nil)
        #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil)
        let persisted = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeys))
        #expect(try JSONDecoder().decode([StoredSSHKey].self, from: persisted).isEmpty)
    }

    @Test func sshKeyDeletionPersistsMetadataFirstAndRestoresSecretAndReferencesOnFailure() throws {
        let keySuiteName = "sh.glas.test.ssh-key-delete.\(UUID().uuidString)"
        let serverSuiteName = "sh.glas.test.ssh-key-server-delete.\(UUID().uuidString)"
        let keyDefaults = UserDefaults(suiteName: keySuiteName)!
        let serverDefaults = UserDefaults(suiteName: serverSuiteName)!
        defer {
            keyDefaults.removePersistentDomain(forName: keySuiteName)
            serverDefaults.removePersistentDomain(forName: serverSuiteName)
        }

        let keyID = UUID()
        let key = StoredSSHKey(
            id: keyID,
            name: "Imported",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        var server = migrationServer()
        server.authMethod = .sshKey
        server.sshKeyID = keyID
        let serverManager = ServerManager(loadImmediately: false, defaults: serverDefaults)
        serverManager.servers = [server]
        try serverManager.persistServersOrThrow()
        keyDefaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)

        let material = SSHKeyMaterial(
            privateKey: SecureBytes(Data("private-key".utf8)),
            passphrase: SecureBytes(Data("passphrase".utf8))
        )
        var observedMetadataRemoval = false
        var restoredSecret = false
        var storedMaterial: SSHKeyMaterial? = material
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in
                let keyData = try #require(keyDefaults.data(forKey: UserDefaultsKeys.sshKeys))
                let persistedKeys = try JSONDecoder().decode([StoredSSHKey].self, from: keyData)
                let serverData = try #require(serverDefaults.data(forKey: UserDefaultsKeys.servers))
                let persistedServers = try JSONDecoder().decode([ServerConfiguration].self, from: serverData)
                observedMetadataRemoval = persistedKeys.isEmpty && persistedServers.first?.sshKeyID == nil
                storedMaterial = nil
                throw CredentialMigrationProbeError.queryFailure
            },
            restore: { _, restored in
                restoredSecret = true
                storedMaterial = restored
            },
            addIfAbsent: { _, restored in
                guard case nil = storedMaterial else { return false }
                restoredSecret = true
                storedMaterial = restored
                return true
            }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: keyDefaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        #expect(throws: CredentialMigrationProbeError.self) {
            try settings.deleteSSHKey(keyID, serverManager: serverManager)
        }
        #expect(observedMetadataRemoval)
        #expect(restoredSecret)
        #expect(storedMaterial?.privateKey.toData() == material.privateKey.toData())
        #expect(storedMaterial?.passphrase?.toData() == material.passphrase?.toData())
        #expect(settings.sshKeys == [key])
        #expect(serverManager.servers.first?.sshKeyID == keyID)
        let journalData = try #require(keyDefaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let journal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: journalData)
        #expect(journal.entries.first?.phase == .recoveryRequired)
        #expect(!String(decoding: journalData, as: UTF8.self).contains("private-key"))
        #expect(!String(decoding: journalData, as: UTF8.self).contains("passphrase"))
    }

    @Test func sshKeyDeletionJournalRollsForwardPartialArtifactsAfterSimulatedRestart() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Interrupted",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([StoredSSHKey]()), forKey: UserDefaultsKeys.sshKeys)
        defaults.set(try JSONEncoder().encode(SSHKeyDeletionJournal(
            version: SSHKeyDeletionJournal.currentVersion,
            entries: [.init(
                key: key,
                referencedServerIDs: [],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                // Simulate interruption after metadata committed but before the
                // journal phase write; persisted metadata remains authoritative.
                phase: .prepared,
                recoveryMessage: nil
            )]
        )), forKey: UserDefaultsKeys.sshKeyDeletionJournal)

        var hasArtifacts = true
        var deleteCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in nil },
            delete: { _ in
                deleteCount += 1
                hasArtifacts = false
            },
            restore: { _, _ in },
            addIfAbsent: { _, _ in false },
            hasAnyArtifacts: { _ in hasArtifacts }
        )

        let restarted = SettingsManager(
            loadImmediately: true,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )

        #expect(deleteCount == 1)
        #expect(!hasArtifacts)
        #expect(restarted.sshKeys.isEmpty)
        #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil)
        #expect(restarted.sshKeyDeletionRecoveryError == nil)
    }

    @Test func sshKeyDeletionRetainsActionableJournalWhenSecretRestoreReadbackDiffers() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-restore-mismatch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Restore mismatch",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        let original = SSHKeyMaterial(
            privateKey: SecureBytes(Data("original-private-key".utf8)),
            passphrase: SecureBytes(Data("original-passphrase".utf8))
        )
        let mismatched = SSHKeyMaterial(
            privateKey: SecureBytes(Data("different-private-key".utf8)),
            passphrase: SecureBytes(Data("original-passphrase".utf8))
        )
        var storedMaterial: SSHKeyMaterial? = original
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in
                storedMaterial = nil
                throw CredentialMigrationProbeError.queryFailure
            },
            restore: { _, _ in storedMaterial = mismatched },
            addIfAbsent: { _, _ in
                guard case nil = storedMaterial else { return false }
                storedMaterial = mismatched
                return true
            }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        do {
            try settings.deleteSSHKey(key.id)
            Issue.record("Secret restoration with mismatched readback must fail")
        } catch let error as SettingsPersistenceError {
            if case .rollbackFailed = error {
                // Expected: the restored bytes did not exactly match the original material.
            } else {
                Issue.record("Expected rollbackFailed, received \(error)")
            }
        }

        #expect(settings.sshKeyDeletionRecoveryError == SettingsPersistenceError.rollbackFailed.localizedDescription)
        #expect(settings.sshKeys == [key])
        let journalData = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let journal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: journalData)
        #expect(journal.entries.first?.phase == .recoveryRequired)
        #expect(journal.entries.first?.recoveryMessage == SettingsPersistenceError.rollbackFailed.localizedDescription)
        #expect(!String(decoding: journalData, as: UTF8.self).contains("original-private-key"))
        #expect(!String(decoding: journalData, as: UTF8.self).contains("original-passphrase"))

        let restarted = SettingsManager(
            loadImmediately: true,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        #expect(restarted.sshKeyDeletionRecoveryError == SettingsPersistenceError.rollbackFailed.localizedDescription)
        let retainedData = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let retainedJournal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: retainedData)
        #expect(retainedJournal.entries.first?.phase == .recoveryRequired)
        #expect(storedMaterial?.privateKey.toData() == mismatched.privateKey.toData())
    }

    @Test func sshKeyDeletionRollbackPreservesConcurrentSecretReplacement() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-concurrent-replacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Concurrent replacement",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        let original = SSHKeyMaterial(
            privateKey: SecureBytes(Data("original-private-key".utf8)),
            passphrase: nil
        )
        let replacement = SSHKeyMaterial(
            privateKey: SecureBytes(Data("concurrent-private-key".utf8)),
            passphrase: nil
        )
        var storedMaterial: SSHKeyMaterial? = original
        var restoreCount = 0
        var atomicAddAttemptCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in
                storedMaterial = nil
                throw CredentialMigrationProbeError.queryFailure
            },
            restore: { _, restored in
                restoreCount += 1
                storedMaterial = restored
            },
            addIfAbsent: { _, restored in
                atomicAddAttemptCount += 1
                // Simulate another process winning the atomic SecItemAdd race.
                storedMaterial = replacement
                _ = restored
                return false
            }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        #expect(throws: SettingsPersistenceError.self) {
            try settings.deleteSSHKey(key.id)
        }
        #expect(restoreCount == 0)
        #expect(atomicAddAttemptCount == 1)
        #expect(storedMaterial?.privateKey.toData() == replacement.privateKey.toData())
        #expect(settings.sshKeyDeletionRecoveryError == SettingsPersistenceError.rollbackFailed.localizedDescription)
        let journalData = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let journal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: journalData)
        #expect(journal.entries.first?.phase == .recoveryRequired)
    }

    @Test func legacySecureEnclaveDeletionRollbackNeverDowngradesToImportedStorage() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-legacy-se.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Legacy Secure Enclave",
            algorithm: "ECDSA P-256",
            storageKind: .secureEnclave,
            algorithmKind: .ecdsaP256,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        let original = SSHKeyMaterial(
            privateKey: SecureBytes(Data("SECURE_ENCLAVE_P256:bGVnYWN5LXJhdy1rZXk=".utf8)),
            passphrase: nil
        )
        var storedMaterial: SSHKeyMaterial? = original
        var atomicAddAttemptCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in
                storedMaterial = nil
                throw CredentialMigrationProbeError.queryFailure
            },
            restore: { _, restored in storedMaterial = restored },
            addIfAbsent: { _, restored in
                atomicAddAttemptCount += 1
                storedMaterial = restored
                return true
            }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        #expect(throws: SettingsPersistenceError.self) {
            try settings.deleteSSHKey(key.id)
        }
        #expect(atomicAddAttemptCount == 0)
        #expect(storedMaterial == nil)
        #expect(settings.sshKeyDeletionRecoveryError == SettingsPersistenceError.rollbackFailed.localizedDescription)
        let journalData = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let journal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: journalData)
        #expect(journal.entries.first?.phase == .recoveryRequired)
    }

    @Test func legacySecureEnclaveDeletionAcceptsOnlyVerifiedHardwareBackedRecovery() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-legacy-se-verified.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Verified Legacy Secure Enclave",
            algorithm: "ECDSA P-256",
            storageKind: .secureEnclave,
            algorithmKind: .ecdsaP256,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        let original = SSHKeyMaterial(
            privateKey: SecureBytes(Data("SECURE_ENCLAVE_P256:dmVyaWZpZWQ=".utf8)),
            passphrase: nil
        )
        var storedMaterial: SSHKeyMaterial? = original
        var provenanceVerificationCount = 0
        var atomicAddAttemptCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in storedMaterial },
            delete: { _ in throw CredentialMigrationProbeError.queryFailure },
            restore: { _, restored in storedMaterial = restored },
            addIfAbsent: { _, restored in
                atomicAddAttemptCount += 1
                storedMaterial = restored
                return true
            },
            verifiesLegacySecureEnclaveBacking: { _, material in
                provenanceVerificationCount += 1
                return material.privateKey.toData() == original.privateKey.toData()
            }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        #expect(throws: CredentialMigrationProbeError.self) {
            try settings.deleteSSHKey(key.id)
        }
        #expect(provenanceVerificationCount == 1)
        #expect(atomicAddAttemptCount == 0)
        #expect(storedMaterial?.privateKey.toData() == original.privateKey.toData())
        #expect(settings.sshKeys == [key])
        #expect(settings.sshKeyDeletionRecoveryError?.contains("restored and verified") == true)
    }

    @Test func sshKeyDeletionRemovesPartialArtifactsWhenMaterialRetrievalIsNil() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-partial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Partial representation",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        var hasArtifacts = true
        var deleteCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in nil },
            delete: { _ in
                deleteCount += 1
                hasArtifacts = false
            },
            restore: { _, _ in },
            addIfAbsent: { _, _ in false },
            hasAnyArtifacts: { _ in hasArtifacts }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        try settings.deleteSSHKey(key.id)

        #expect(deleteCount == 1)
        #expect(!hasArtifacts)
        #expect(settings.sshKeys.isEmpty)
        #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil)
    }

    @Test func sshKeyDeletionFailureWithUnrecoverablePartialArtifactsFailsClosed() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-partial-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Unrecoverable partial representation",
            algorithm: "ECDSA P-256",
            storageKind: .secureEnclave,
            algorithmKind: .ecdsaP256,
            migrationState: .migrated
        )
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        var hasArtifacts = true
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in nil },
            delete: { _ in
                hasArtifacts = false
                throw CredentialMigrationProbeError.queryFailure
            },
            restore: { _, _ in },
            addIfAbsent: { _, _ in false },
            hasAnyArtifacts: { _ in hasArtifacts }
        )
        let settings = SettingsManager(
            loadImmediately: false,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )
        settings.sshKeys = [key]

        #expect(throws: SettingsPersistenceError.self) {
            try settings.deleteSSHKey(key.id)
        }

        #expect(!hasArtifacts)
        #expect(settings.sshKeys == [key])
        #expect(settings.sshKeyDeletionRecoveryError == SettingsPersistenceError.rollbackFailed.localizedDescription)
        let journalData = try #require(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal))
        let journal = try JSONDecoder().decode(SSHKeyDeletionJournal.self, from: journalData)
        #expect(journal.entries.first?.phase == .recoveryRequired)
        #expect(journal.entries.first?.recoveryMessage == SettingsPersistenceError.rollbackFailed.localizedDescription)
    }

    @Test func sshKeyDeletionJournalAbortsBeforeMetadataCommitAndPreservesSecret() throws {
        let suiteName = "sh.glas.test.ssh-key-delete-ambiguous.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = StoredSSHKey(
            id: UUID(),
            name: "Ambiguous",
            algorithm: "Ed25519",
            storageKind: .imported,
            algorithmKind: .ed25519,
            migrationState: .migrated
        )
        var server = migrationServer()
        server.authMethod = .sshKey
        server.sshKeyID = key.id
        defaults.set(try JSONEncoder().encode([key]), forKey: UserDefaultsKeys.sshKeys)
        defaults.set(try JSONEncoder().encode([server]), forKey: UserDefaultsKeys.servers)
        defaults.set(try JSONEncoder().encode(SSHKeyDeletionJournal(
            version: SSHKeyDeletionJournal.currentVersion,
            entries: [.init(
                key: key,
                referencedServerIDs: [server.id],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                phase: .prepared,
                recoveryMessage: nil
            )]
        )), forKey: UserDefaultsKeys.sshKeyDeletionJournal)
        let material = SSHKeyMaterial(
            privateKey: SecureBytes(Data("still-present".utf8)),
            passphrase: nil
        )
        var deleteCount = 0
        let lifecycleStore = SSHKeyLifecycleStore(
            retrieve: { _ in material },
            delete: { _ in deleteCount += 1 },
            restore: { _, _ in },
            addIfAbsent: { _, _ in false }
        )

        let restarted = SettingsManager(
            loadImmediately: true,
            sshKeyDefaults: defaults,
            sshKeyLifecycleStore: lifecycleStore
        )

        #expect(restarted.sshKeys == [key])
        #expect(deleteCount == 0)
        #expect(restarted.sshKeyDeletionRecoveryError == nil)
        #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) == nil)
    }

    @Test func sshKeyDeletionJournalTreatsMissingOrMalformedCatalogAsAmbiguous() throws {
        for catalogData in [nil, Data("{".utf8)] as [Data?] {
            let suiteName = "sh.glas.test.ssh-key-delete-catalog-ambiguous.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let key = StoredSSHKey(
                id: UUID(),
                name: "Catalog ambiguity",
                algorithm: "Ed25519",
                storageKind: .imported,
                algorithmKind: .ed25519,
                migrationState: .migrated
            )
            if let catalogData {
                defaults.set(catalogData, forKey: UserDefaultsKeys.sshKeys)
            }
            defaults.set(try JSONEncoder().encode(SSHKeyDeletionJournal(
                version: SSHKeyDeletionJournal.currentVersion,
                entries: [.init(
                    key: key,
                    referencedServerIDs: [],
                    createdAt: Date(),
                    phase: .prepared,
                    recoveryMessage: nil
                )]
            )), forKey: UserDefaultsKeys.sshKeyDeletionJournal)
            let material = SSHKeyMaterial(
                privateKey: SecureBytes(Data("must-survive".utf8)),
                passphrase: nil
            )
            var deleteCount = 0
            let lifecycleStore = SSHKeyLifecycleStore(
                retrieve: { _ in material },
                delete: { _ in deleteCount += 1 },
                restore: { _, _ in },
                addIfAbsent: { _, _ in false }
            )

            let restarted = SettingsManager(
                loadImmediately: true,
                sshKeyDefaults: defaults,
                sshKeyLifecycleStore: lifecycleStore
            )

            #expect(deleteCount == 0)
            #expect(restarted.sshKeyDeletionRecoveryError != nil)
            #expect(defaults.data(forKey: UserDefaultsKeys.sshKeyDeletionJournal) != nil)
        }
    }

    private func trustedHostEntry(
        host: String = "example.com",
        port: Int = 22,
        algorithm: String = "ssh-ed25519",
        key: String = "legacy-host-key",
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TrustedHostKeyEntry {
        let keyData = Data(key.utf8)
        let canonicalFingerprint = PinnedSSHHostKey.sha256Fingerprint(for: keyData)
        let unpaddedFingerprint = String(canonicalFingerprint.dropFirst("SHA256:".count))
        let legacyFingerprint = unpaddedFingerprint
            + String(repeating: "=", count: (4 - unpaddedFingerprint.count % 4) % 4)
        return TrustedHostKeyEntry(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprintSHA256: legacyFingerprint,
            keyDataBase64: keyData.base64EncodedString(),
            addedAt: addedAt
        )
    }

    private func migrationDefaults(_ suffix: String) -> (name: String, defaults: UserDefaults) {
        let name = "sh.glas.test.host-trust.\(suffix).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func migrationReport(from defaults: UserDefaults) throws -> HostTrustMigrationReport {
        let data = try #require(defaults.data(forKey: UserDefaultsKeys.hostTrustMigrationReport))
        return try JSONDecoder().decode(HostTrustMigrationReport.self, from: data)
    }

    @Test func hostTrustMigrationCandidateValidationRejectsMalformedFields() {
        let valid = trustedHostEntry()
        let malformedEntries = [
            TrustedHostKeyEntry(
                host: valid.host,
                port: valid.port,
                algorithm: valid.algorithm,
                fingerprintSHA256: valid.fingerprintSHA256,
                keyDataBase64: "not base64",
                addedAt: valid.addedAt
            ),
            TrustedHostKeyEntry(
                host: valid.host,
                port: valid.port,
                algorithm: valid.algorithm,
                fingerprintSHA256: valid.fingerprintSHA256,
                keyDataBase64: "",
                addedAt: valid.addedAt
            ),
            TrustedHostKeyEntry(
                host: "   ",
                port: valid.port,
                algorithm: valid.algorithm,
                fingerprintSHA256: valid.fingerprintSHA256,
                keyDataBase64: valid.keyDataBase64,
                addedAt: valid.addedAt
            ),
            TrustedHostKeyEntry(
                host: valid.host,
                port: 0,
                algorithm: valid.algorithm,
                fingerprintSHA256: valid.fingerprintSHA256,
                keyDataBase64: valid.keyDataBase64,
                addedAt: valid.addedAt
            ),
            TrustedHostKeyEntry(
                host: valid.host,
                port: valid.port,
                algorithm: valid.algorithm,
                fingerprintSHA256: "SHA256:not-the-key",
                keyDataBase64: valid.keyDataBase64,
                addedAt: valid.addedAt
            ),
        ]

        for entry in malformedEntries {
            #expect(throws: (any Error).self) {
                _ = try KeychainManager.pinnedHostKey(from: entry)
            }
        }
    }

    @Test @MainActor func hostTrustMigrationMigratesGlobalOnlySource() throws {
        let fixture = migrationDefaults("global")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let entry = trustedHostEntry()
        fixture.defaults.set(
            try JSONEncoder().encode([entry]),
            forKey: UserDefaultsKeys.trustedHostKeys
        )
        let probe = HostTrustStoreProbe()

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(manager.servers.isEmpty)
        #expect(probe.records.count == 1)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == nil)
        #expect(
            fixture.defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion)
                == ServerManager.currentHostTrustMigrationVersion
        )
        let report = try migrationReport(from: fixture.defaults)
        #expect(report.state == .completed)
        #expect(report.globalSourceCount == 1)
        #expect(report.serverSourceCount == 0)
        #expect(report.uniqueCandidateCount == 1)
        #expect(report.verifiedCount == 1)
    }

    @Test @MainActor func hostTrustMigrationCombinesAndDeduplicatesSources() throws {
        let fixture = migrationDefaults("combined")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let entry = trustedHostEntry()
        fixture.defaults.set(
            try JSONEncoder().encode([entry]),
            forKey: UserDefaultsKeys.trustedHostKeys
        )
        var server = ServerConfiguration(
            name: "Legacy",
            host: entry.host,
            port: entry.port,
            username: "user"
        )
        server.trustedHostKeys = [entry]
        fixture.defaults.set(
            try JSONEncoder().encode([server]),
            forKey: UserDefaultsKeys.servers
        )
        let probe = HostTrustStoreProbe()

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(probe.saveCount == 1)
        #expect(probe.records.count == 1)
        #expect(manager.servers.first?.trustedHostKeys == nil)
        let persistedData = try #require(fixture.defaults.data(forKey: UserDefaultsKeys.servers))
        let persistedServers = try JSONDecoder().decode([ServerConfiguration].self, from: persistedData)
        #expect(persistedServers.first?.trustedHostKeys == nil)
        let report = try migrationReport(from: fixture.defaults)
        #expect(report.globalSourceCount == 1)
        #expect(report.serverSourceCount == 1)
        #expect(report.uniqueCandidateCount == 1)
        #expect(report.duplicateCount == 1)
    }

    @Test @MainActor func hostTrustMigrationRetainsInvalidLegacySources() throws {
        let fixture = migrationDefaults("invalid")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let invalid = TrustedHostKeyEntry(
            host: "example.com",
            port: 22,
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:not-the-key",
            keyDataBase64: "not base64",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let globalData = try JSONEncoder().encode([invalid])
        fixture.defaults.set(globalData, forKey: UserDefaultsKeys.trustedHostKeys)
        var server = ServerConfiguration(
            name: "Legacy",
            host: invalid.host,
            port: invalid.port,
            username: "user"
        )
        server.trustedHostKeys = [invalid]
        let serverData = try JSONEncoder().encode([server])
        fixture.defaults.set(serverData, forKey: UserDefaultsKeys.servers)
        let probe = HostTrustStoreProbe()

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(probe.saveCount == 0)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == globalData)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.servers) == serverData)
        #expect(fixture.defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion) == 0)
        #expect(manager.servers.first?.trustedHostKeys == [invalid])
        #expect(try migrationReport(from: fixture.defaults).state == .failed)
    }

    @Test @MainActor func hostTrustMigrationRetainsSourcesWhenStoreFails() throws {
        let fixture = migrationDefaults("store-failure")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let entry = trustedHostEntry()
        let globalData = try JSONEncoder().encode([entry])
        fixture.defaults.set(globalData, forKey: UserDefaultsKeys.trustedHostKeys)
        let probe = HostTrustStoreProbe()
        probe.failSaves = true

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(probe.saveCount == 1)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == globalData)
        #expect(fixture.defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion) == 0)
        #expect(try migrationReport(from: fixture.defaults).state == .failed)
    }

    @Test @MainActor func hostTrustMigrationRetainsSourcesOnExistingKeyConflict() throws {
        let fixture = migrationDefaults("key-conflict")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let legacyEntry = trustedHostEntry(key: "legacy-key")
        let globalData = try JSONEncoder().encode([legacyEntry])
        fixture.defaults.set(globalData, forKey: UserDefaultsKeys.trustedHostKeys)
        let existingEntry = trustedHostEntry(key: "different-current-key")
        let existingRecord = try KeychainManager.pinnedHostKey(from: existingEntry)
        let probe = HostTrustStoreProbe()
        probe.records[existingRecord.storageAccount] = existingRecord

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(probe.saveCount == 0)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == globalData)
        #expect(fixture.defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion) == 0)
        #expect(try migrationReport(from: fixture.defaults).failureCode == "conflicting-keys")
    }

    @Test @MainActor func hostTrustMigrationRetainsSourcesWhenReadbackFails() throws {
        let fixture = migrationDefaults("readback-failure")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let entry = trustedHostEntry()
        let globalData = try JSONEncoder().encode([entry])
        fixture.defaults.set(globalData, forKey: UserDefaultsKeys.trustedHostKeys)
        let probe = HostTrustStoreProbe()
        probe.omitRecordsOnReadback = true

        let manager = ServerManager(
            loadImmediately: false,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        manager.loadServersIfNeeded()

        #expect(probe.saveCount == 1)
        #expect(fixture.defaults.data(forKey: UserDefaultsKeys.trustedHostKeys) == globalData)
        #expect(fixture.defaults.integer(forKey: UserDefaultsKeys.hostTrustMigrationVersion) == 0)
        #expect(try migrationReport(from: fixture.defaults).failureCode == "keychain-readback-mismatch")
    }

    @Test @MainActor func hostTrustMigrationIsIdempotentAfterCompletion() throws {
        let fixture = migrationDefaults("idempotent")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let entry = trustedHostEntry()
        fixture.defaults.set(
            try JSONEncoder().encode([entry]),
            forKey: UserDefaultsKeys.trustedHostKeys
        )
        let probe = HostTrustStoreProbe()

        _ = ServerManager(
            loadImmediately: true,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )
        let firstSaveCount = probe.saveCount
        let firstReport = try migrationReport(from: fixture.defaults)

        _ = ServerManager(
            loadImmediately: true,
            defaults: fixture.defaults,
            hostTrustStore: probe.store
        )

        #expect(firstSaveCount == 1)
        #expect(probe.saveCount == firstSaveCount)
        #expect(try migrationReport(from: fixture.defaults) == firstReport)
    }

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
        #expect(settings.glassFrost == "ultraThin")
        #expect(settings.backgroundFill == 0.0)
        #expect(settings.interactiveGlass == true)
        #expect(settings.glassTint == "None")
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
            override.backgroundFill = 0.8
            override.interactiveGlass = false
        }

        let result = settings.sessionOverride(for: sessionID)
        #expect(result?.backgroundFill == 0.8)
        #expect(result?.interactiveGlass == false)
    }

    // MARK: - Layout Persistence Tests

    @Test func legacyLayoutServerIDsMigrateToVersionedSessionIntentions() throws {
        let layoutID = UUID()
        let firstServerID = UUID()
        let secondServerID = UUID()
        let legacyRecord: [String: Any] = [
            "id": layoutID.uuidString,
            "name": "Legacy Layout",
            "serverIDs": [firstServerID.uuidString, secondServerID.uuidString],
            "createdAt": 123.0
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyRecord)

        let decoded = try JSONDecoder().decode(LayoutPreset.self, from: legacyData)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.needsMigration)
        #expect(decoded.serverIDs == [firstServerID, secondServerID])
        #expect(decoded.sessionIntents.allSatisfy { $0.isSupported })

        let migrated = decoded.migratedToCurrentSchema()
        let canonicalData = try JSONEncoder().encode(migrated)
        let canonicalObject = try #require(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )

        #expect(migrated.schemaVersion == LayoutPreset.currentSchemaVersion)
        #expect(!migrated.needsMigration)
        #expect(canonicalObject["sessionIntents"] != nil)
        #expect(canonicalObject["serverIDs"] == nil)
    }

    @Test func layoutRestorationPreservesDuplicateSessionIntentions() throws {
        let server = ServerConfiguration(
            name: "Shared Endpoint",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let preset = LayoutPreset(name: "Two Terminals", serverIDs: [server.id, server.id])
        let roundTripped = try JSONDecoder().decode(
            LayoutPreset.self,
            from: JSONEncoder().encode(preset)
        )

        let plan = LayoutRestorationPlan(preset: roundTripped, availableServers: [server])

        #expect(roundTripped.serverIDs == [server.id, server.id])
        #expect(plan.targets.count == 2)
        #expect(plan.targets.allSatisfy { $0.server.id == server.id })
        #expect(plan.failures.isEmpty)
    }

    @Test func layoutRestorationAggregatesMissingServersWithoutDiscardingValidSessions() {
        let availableServer = ServerConfiguration(
            name: "Available",
            host: "available.example.com",
            port: 22,
            username: "user"
        )
        let missingServerID = UUID()
        let preset = LayoutPreset(
            name: "Partial Layout",
            serverIDs: [missingServerID, availableServer.id]
        )

        let plan = LayoutRestorationPlan(preset: preset, availableServers: [availableServer])

        #expect(plan.targets.count == 1)
        #expect(plan.targets.first?.server.id == availableServer.id)
        #expect(plan.failures.count == 1)
        #expect(plan.failures.first?.contains("Session 1") == true)
        #expect(plan.failures.first?.contains("no longer exists") == true)
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

    @Test @MainActor func userFacingMessageForUnsupportedAuthMethod() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        )
        let message = SSHConnection.userFacingMessage(
            for: SSHError.unsupportedAuthMethod("SSH Agent authentication is unavailable in this release."),
            server: server
        )
        #expect(message == "SSH Agent authentication is unavailable in this release.")
    }

    @Test @MainActor func userFacingMessageForInvalidPort() {
        let server = ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 70_000,
            username: "user"
        )

        let message = SSHConnection.userFacingMessage(for: SSHError.invalidPort(server.port), server: server)

        #expect(message.contains("70000"))
        #expect(message.contains("1 through 65535"))
    }

    @Test @MainActor func keyExchangeNegotiationFailureDetection() {
        let error = LegacyKEXFixture()

        #expect(SSHConnection.isKeyExchangeNegotiationFailure(error))
        #expect(!SSHConnection.shouldRetryWithLegacyAlgorithms(error, enabled: false))
        #expect(SSHConnection.shouldRetryWithLegacyAlgorithms(error, enabled: true))
    }

    @Test func legacyAlgorithmsAreDisabledForExistingServerRecords() throws {
        var server = ServerConfiguration(
            name: "Legacy",
            host: "legacy.example.com",
            port: 22,
            username: "user"
        )
        server.allowLegacyAlgorithms = nil

        let encoded = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: encoded)

        #expect(decoded.allowLegacyAlgorithms == nil)
        #expect(decoded.legacyAlgorithmsEnabled == false)
    }

    @Test @MainActor func channelClosedErrorDetection() {
        #expect(SSHConnection.isChannelClosedError(ChannelError.eof))
        #expect(SSHConnection.isChannelClosedError(ChannelError.alreadyClosed))
        #expect(SSHConnection.isChannelClosedError(ChannelError.inputClosed))
        #expect(SSHConnection.isChannelClosedError(ChannelError.outputClosed))
        #expect(!SSHConnection.isChannelClosedError(ChannelError.connectPending))
        #expect(!SSHConnection.isChannelClosedError(SSHError.connectionFailed))
    }

    @Test func generatedCommandPolicyAllowsOnlyClassifiedReadOnlyCommands() {
        #expect(GeneratedCommandPolicy.assess("ls -la").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("git status").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("rm -rf build").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("cat script | sh").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("sudo ls").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("curl https://example.com").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("git reset --hard").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("find . -delete").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("ls\nrm file").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("find . -fprint /tmp/glas-proof").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("find . -fls /tmp/glas-proof").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("less -o /tmp/copied-secret /etc/passwd").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("rg --pre touch pattern .").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("hostname attacker-controlled-name").requiresConfirmation)
        #expect(GeneratedCommandPolicy.assess("date -s @0").requiresConfirmation)
    }

    @Test func generatedCommandPolicyRejectsControlAndUnicodeFormatSpoofing() {
        #expect(GeneratedCommandPolicy.assess("ls -la").isExecutable)

        let visuallySpoofedCommands = [
            "ls\u{0000}-la",
            "echo safe\u{202E}txt",
            "git \u{2066}status\u{2069}",
            "rm\u{200B} -rf build",
        ]
        for command in visuallySpoofedCommands {
            let assessment = GeneratedCommandPolicy.assess(command)
            #expect(!assessment.isExecutable)
            #expect(assessment.reasons.contains {
                $0.contains("control or invisible Unicode formatting")
            })
        }
    }

    @Test func aiResponseParserExtractsRequiredLabeledSections() throws {
        let suggestion = try #require(AIResponseParser.commandSuggestion(from: """
        COMMAND: ls -la
        EXPLANATION: Lists all files, including hidden files.
        RISK: safe
        """))
        #expect(suggestion.command == "ls -la")
        #expect(suggestion.explanation == "Lists all files, including hidden files.")
        #expect(suggestion.riskLevel == "safe")

        let explanation = try #require(AIResponseParser.errorExplanation(from: """
        PROBLEM: The directory does not exist.
        FIX:
        REASONING: No automatic fix is safe without the intended path.
        """))
        #expect(explanation.problem == "The directory does not exist.")
        #expect(explanation.suggestedFix.isEmpty)
        #expect(explanation.reasoning == "No automatic fix is safe without the intended path.")
    }

    @Test func aiResponseParserRejectsMissingSections() {
        #expect(AIResponseParser.commandSuggestion(from: "COMMAND: ls") == nil)
        #expect(AIResponseParser.errorExplanation(
            from: "PROBLEM: failed\nREASONING: unknown"
        ) == nil)
        #expect(AIResponseParser.commandSuggestion(from: """
        COMMAND: ls
        EXPLANATION: first
        EXPLANATION: duplicate
        RISK: safe
        """) == nil)
        #expect(AIResponseParser.commandSuggestion(from: """
        COMMAND: ls
        EXPLANATION: lists files
        RISK: unknown
        """) == nil)
        #expect(AIResponseParser.commandSuggestion(from: """
        COMMAND: ```sh
        ls
        ```
        EXPLANATION: lists files
        RISK: safe
        """) == nil)
    }

    @Test func aiResponseParserNormalizesLegacyCarriageReturns() throws {
        let suggestion = try #require(AIResponseParser.commandSuggestion(
            from: "COMMAND: pwd\rEXPLANATION: Prints the current directory.\rRISK: SAFE"
        ))
        #expect(suggestion.command == "pwd")
        #expect(suggestion.riskLevel == "safe")
    }

    @Test func sftpBasenamePolicyRejectsTraversalAndSeparators() {
        #expect(SFTPBrowserView.isSafeBasename("report.txt"))
        #expect(SFTPBrowserView.isSafeBasename("résumé.txt"))
        #expect(!SFTPBrowserView.isSafeBasename(""))
        #expect(!SFTPBrowserView.isSafeBasename("."))
        #expect(!SFTPBrowserView.isSafeBasename(".."))
        #expect(!SFTPBrowserView.isSafeBasename("../secret"))
        #expect(!SFTPBrowserView.isSafeBasename("folder/file"))
        #expect(!SFTPBrowserView.isSafeBasename("folder\\file"))
        #expect(!SFTPBrowserView.isSafeBasename("/absolute"))
        #expect(!SFTPBrowserView.isSafeBasename(" trailing "))
        #expect(!SFTPBrowserView.isSafeBasename("nul\0byte"))
        #expect(!SFTPBrowserView.isSafeBasename("line\nbreak.txt"))
        #expect(!SFTPBrowserView.isSafeBasename("report\u{202E}txt.exe"))
        #expect(!SFTPBrowserView.isSafeBasename("zero\u{200B}width.txt"))
        #expect(!SFTPBrowserView.isSafeBasename("re\u{301}sume\u{301}.txt"))
        #expect(SFTPBrowserView.isSafeBasename("r\u{00E9}sum\u{00E9}.txt"))
    }

    @Test func sftpContainmentRejectsParentTraversal() {
        let folder = URL(fileURLWithPath: "/tmp/glas-sftp-destination", isDirectory: true)

        #expect(SFTPBrowserView.isContained(folder.appendingPathComponent("safe.txt"), in: folder))
        #expect(!SFTPBrowserView.isContained(folder.appendingPathComponent("../escape.txt"), in: folder))
    }

    @Test func sftpLocalFileOpenRejectsSymbolicLinks() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("glas-sftp-no-follow-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.txt")
        let link = folder.appendingPathComponent("partial-link")
        try Data("trusted".utf8).write(to: source)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: source)

        #expect(throws: (any Error).self) {
            try SFTPBrowserView.localFileIdentityNoFollow(at: link)
        }
        #expect(try SFTPBrowserView.localFileIdentityNoFollow(at: source).size == 7)
    }

    @Test func sftpRetainedDestinationDirectoryPreventsParentSwapRedirection() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("glas-sftp-directory-fd-\(UUID().uuidString)", isDirectory: true)
        let selectedPath = root.appendingPathComponent("selected", isDirectory: true)
        let retainedPath = root.appendingPathComponent("retained", isDirectory: true)
        let victim = root.appendingPathComponent("victim.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: selectedPath, withIntermediateDirectories: false)
        try Data("untouched".utf8).write(to: victim)
        defer { try? fileManager.removeItem(at: root) }

        let openedDirectory = try SFTPBrowserView.openLocalDirectoryNoFollow(at: selectedPath)
        defer { try? openedDirectory.directory.close() }

        // Replace the selected pathname after acquisition. Every transfer operation
        // must remain anchored to the directory inode the user actually selected.
        try fileManager.moveItem(at: selectedPath, to: retainedPath)
        try fileManager.createDirectory(at: selectedPath, withIntermediateDirectories: false)
        let replacementPartial = selectedPath.appendingPathComponent("partial")
        try fileManager.createSymbolicLink(at: replacementPartial, withDestinationURL: victim)

        let partial = try SFTPBrowserView.createProtectedTemporaryFile(
            in: openedDirectory.directory,
            name: "partial"
        )
        try partial.file.write(contentsOf: Data("download".utf8))
        try partial.file.synchronize()
        let completedIdentity = try SFTPBrowserView.localFileIdentity(for: partial.file)
        try SFTPBrowserView.moveLocalFileNoClobber(
            in: openedDirectory.directory,
            sourceName: "partial",
            destinationName: "report.txt",
            matching: completedIdentity
        )
        try partial.file.close()

        #expect(try Data(contentsOf: retainedPath.appendingPathComponent("report.txt")) == Data("download".utf8))
        #expect(try fileManager.destinationOfSymbolicLink(atPath: replacementPartial.path) == victim.path)
        #expect(try Data(contentsOf: victim) == Data("untouched".utf8))
        #expect(
            try SFTPBrowserView.localDirectoryIdentity(for: openedDirectory.directory)
                == openedDirectory.identity
        )

        let cleanup = try SFTPBrowserView.createProtectedTemporaryFile(
            in: openedDirectory.directory,
            name: "cleanup"
        )
        try cleanup.file.close()
        let replacementCleanup = selectedPath.appendingPathComponent("cleanup")
        try fileManager.createSymbolicLink(at: replacementCleanup, withDestinationURL: victim)
        try SFTPBrowserView.removeLocalFileIfMatching(
            in: openedDirectory.directory,
            name: "cleanup",
            identity: cleanup.identity
        )

        #expect(!fileManager.fileExists(atPath: retainedPath.appendingPathComponent("cleanup").path))
        #expect(try fileManager.destinationOfSymbolicLink(atPath: replacementCleanup.path) == victim.path)
        #expect(try Data(contentsOf: victim) == Data("untouched".utf8))
    }

    @Test func sftpRetainedSourceDescriptorDetectsInPlaceMutation() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("glas-sftp-source-identity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.txt")
        try Data("before".utf8).write(to: source)
        let opened = try SFTPBrowserView.openLocalSourceNoFollow(at: source)
        defer { try? opened.file.close() }

        let writer = try FileHandle(forWritingTo: source)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data("after!".utf8))
        try writer.synchronize()
        try writer.close()

        let changedIdentity = try SFTPBrowserView.localFileIdentity(for: opened.file)
        #expect(changedIdentity.isSameFile(as: opened.identity))
        #expect(changedIdentity != opened.identity)
        #expect(!SFTPBrowserView.localFile(opened.file, matches: opened.identity))
    }

    @Test func sftpCommitGateObservesTaskCancellation() async {
        let task = Task { () -> Bool in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Continue to the actual commit gate after cancellation wakes the task.
            }
            do {
                try SFTPBrowserView.checkCancellationBeforeCommit()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()

        #expect(await task.value)
    }

    @Test func sftpDownloadResumeIdentityBindsRemoteSourceVersion() {
        let serverID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = SFTPBrowserView.downloadResumeIdentity(
            serverID: serverID,
            remotePath: "/exports/report.txt",
            size: 4_096,
            modificationTime: modified
        )

        #expect(identity == SFTPBrowserView.downloadResumeIdentity(
            serverID: serverID,
            remotePath: "/exports/report.txt",
            size: 4_096,
            modificationTime: modified
        ))
        #expect(identity != SFTPBrowserView.downloadResumeIdentity(
            serverID: serverID,
            remotePath: "/exports/report.txt",
            size: 4_097,
            modificationTime: modified
        ))
        #expect(identity != SFTPBrowserView.downloadResumeIdentity(
            serverID: serverID,
            remotePath: "/exports/report.txt",
            size: 4_096,
            modificationTime: modified.addingTimeInterval(1)
        ))
    }

    @Test func sftpUploadResumeIdentityBindsDestinationAndLocalSource() {
        let serverID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let identity = SFTPBrowserView.uploadResumeIdentity(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        )

        #expect(identity == SFTPBrowserView.uploadResumeIdentity(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        ))
        #expect(identity != SFTPBrowserView.uploadResumeIdentity(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report (2).txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        ))
        #expect(identity != SFTPBrowserView.uploadResumeIdentity(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_193,
            sourceModificationTime: 1_700_000_000
        ))
    }

    @Test func sftpDownloadResumeDecisionRejectsUnsafeAndReplacesOversizedCandidates() {
        #expect(SFTPBrowserView.localResumeDecision(
            fileExists: false,
            isRegularAndContained: false,
            size: nil,
            expectedSize: 4_096
        ) == .create)
        #expect(SFTPBrowserView.localResumeDecision(
            fileExists: true,
            isRegularAndContained: true,
            size: 2_048,
            expectedSize: 4_096
        ) == .resume(offset: 2_048))
        #expect(SFTPBrowserView.localResumeDecision(
            fileExists: true,
            isRegularAndContained: true,
            size: 4_097,
            expectedSize: 4_096
        ) == .replaceOversized)
        #expect(SFTPBrowserView.localResumeDecision(
            fileExists: true,
            isRegularAndContained: false,
            size: 2_048,
            expectedSize: 4_096
        ) == .rejectUnsafe)
        #expect(SFTPBrowserView.localResumeDecision(
            fileExists: true,
            isRegularAndContained: true,
            size: 2_048,
            expectedSize: nil
        ) == .rejectUnsafe)
        #expect(SFTPBrowserView.resumeChunksMatch(
            source: Data("verified prefix".utf8),
            retained: Data("verified prefix".utf8)
        ))
        #expect(!SFTPBrowserView.resumeChunksMatch(
            source: Data("verified prefix".utf8),
            retained: Data("corrupt prefix!".utf8)
        ))
        #expect(!SFTPBrowserView.resumeChunksMatch(source: Data(), retained: Data()))
    }

    @Test func sftpUploadResumeRecordRequiresEveryBoundIdentityField() throws {
        let serverID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let record = SFTPUploadResumeRecord(
            version: SFTPUploadResumeRecord.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000,
            partialName: ".glas-sh-upload-11111111-2222-3333-4444-555555555555.partial"
        )

        #expect(record.matches(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        ))
        let decodedRecord = try JSONDecoder().decode(
            SFTPUploadResumeRecord.self,
            from: JSONEncoder().encode(record)
        )
        #expect(decodedRecord.matches(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        ))
        #expect(!record.matches(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report (2).txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_000
        ))
        #expect(!record.matches(
            serverID: serverID,
            remoteDirectory: "/incoming",
            finalName: "report.txt",
            sourceName: "report.txt",
            sourceSize: 8_192,
            sourceModificationTime: 1_700_000_001
        ))
    }

    @Test func sftpUploadMetadataNeverDropsUnresolvedMappingsAtCapacity() {
        let fullDirectory = Set((0..<128).map { "\($0).json" })

        #expect(!SFTPBrowserView.canReserveUploadMetadataRecord(
            existingRecordNames: fullDirectory,
            requestedName: "new.json",
            maximumCount: 128
        ))
        #expect(SFTPBrowserView.canReserveUploadMetadataRecord(
            existingRecordNames: fullDirectory,
            requestedName: "64.json",
            maximumCount: 128
        ))
        #expect(SFTPBrowserView.canReserveUploadMetadataRecord(
            existingRecordNames: ["existing.json"],
            requestedName: "new.json",
            maximumCount: 128
        ))
    }

    @Test func tailscaleFormEncodingPreventsDelimiterSmuggling() {
        let body = TailscaleClient.formEncodedBody([
            ("client id", "a+b&c=d/secret")
        ])

        #expect(String(decoding: body, as: UTF8.self) == "client+id=a%2Bb%26c%3Dd%2Fsecret")
    }

    @Test func tailscaleOAuthTokenCacheBindsCredentialIdentityExpiryAndClear() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credentialsA = (clientID: "client-a", clientSecret: "secret-a")
        let credentialsB = (clientID: "client-b", clientSecret: "secret-b")
        var cache = TailscaleOAuthTokenCache()

        let storedA = cache.store("token-a", expiresIn: 3_600, for: credentialsA, now: now)
        let cachedA = cache.token(for: credentialsA, now: now.addingTimeInterval(60))
        let rotatedCredentialMiss = cache.token(for: credentialsB, now: now.addingTimeInterval(60))
        #expect(storedA)
        #expect(cachedA == "token-a")
        #expect(rotatedCredentialMiss == nil)

        let storedB = cache.store("token-b", expiresIn: 60, for: credentialsB, now: now)
        let expiredB = cache.token(for: credentialsB, now: now.addingTimeInterval(31))
        let acceptedEmpty = cache.store("", expiresIn: 3_600, for: credentialsA, now: now)
        let acceptedShortLifetime = cache.store("token", expiresIn: 30, for: credentialsA, now: now)
        #expect(storedB)
        #expect(expiredB == nil)
        #expect(!acceptedEmpty)
        #expect(!acceptedShortLifetime)

        let restoredA = cache.store("token-a", expiresIn: 3_600, for: credentialsA, now: now)
        #expect(restoredA)
        cache.clear()
        let cleared = cache.token(for: credentialsA, now: now)
        #expect(cleared == nil)
    }

    @Test func recorderPreservesFragmentedUTF8Scalars() {
        var pending = Data()
        let euro = Array("€".utf8)

        #expect(SessionRecorder.decodeAvailableUTF8(&pending, appending: Data(euro.prefix(2))) == nil)
        #expect(pending.count == 2)
        #expect(SessionRecorder.decodeAvailableUTF8(&pending, appending: Data(euro.suffix(1))) == "€")
        #expect(pending.isEmpty)
    }

    @Test func recorderFilenamePolicyBindsPathToRecordingIdentity() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let validFilename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"

        #expect(SessionRecorder.isValidRecordingFilename(
            validFilename,
            sessionID: sessionID,
            recordingID: recordingID
        ))
        #expect(!SessionRecorder.isValidRecordingFilename(
            "../\(validFilename)",
            sessionID: sessionID,
            recordingID: recordingID
        ))
        #expect(!SessionRecorder.isValidRecordingFilename(
            "\(sessionID.uuidString)_\(UUID().uuidString).cast",
            sessionID: sessionID,
            recordingID: recordingID
        ))
    }

    @Test @MainActor func invalidRecordingIndexBlocksStartAndDeleteWithoutTouchingFiles() throws {
        let fixtures: [(String, Data)] = [
            ("malformed", Data("not-json".utf8)),
            (
                "oversized",
                Data(repeating: 0, count: SessionRecorder.maximumRecordingIndexBytes + 1)
            )
        ]

        for (label, indexData) in fixtures {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("glas-recording-index-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let recordingID = UUID()
            let sessionID = UUID()
            let filename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
            let recording = SessionRecording(
                id: recordingID,
                sessionID: sessionID,
                serverName: "Retained",
                host: "retained.example.com",
                startTime: Date(timeIntervalSince1970: 1_700_000_000),
                endTime: Date(timeIntervalSince1970: 1_700_000_010),
                eventCount: 1,
                filename: filename,
                capturesInput: false,
                isComplete: true
            )
            let indexURL = directory.appendingPathComponent("index.json")
            let castURL = directory.appendingPathComponent(filename)
            let castData = Data("evidence-must-survive".utf8)
            try indexData.write(to: indexURL)
            try castData.write(to: castURL)
            let originalNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

            let recorder = SessionRecorder(recordingsDirectory: directory)
            recorder.start(
                sessionID: UUID(),
                serverName: "Must not start",
                host: "blocked.example.com",
                width: 80,
                height: 24
            )

            #expect(!recorder.isRecording)
            #expect(recorder.lastError != nil)
            #expect(throws: SessionRecordingStorageError.self) {
                try SessionRecorder.deleteRecording(recording, at: directory)
            }
            #expect(try Data(contentsOf: indexURL) == indexData)
            #expect(try Data(contentsOf: castURL) == castData)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                == originalNames)
            #expect(SessionRecorder.recordingCatalogLoadError != nil)
        }
    }

    @Test @MainActor func recordingDeletionRollsBackQuarantineWhenIndexWriteDoesNotCommit() throws {
        struct InjectedIndexFailure: Error {}

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glas-recording-delete-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingID = UUID()
        let sessionID = UUID()
        let filename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: "Rollback",
            host: "rollback.example.com",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_010),
            eventCount: 1,
            filename: filename,
            capturesInput: false,
            isComplete: true
        )
        try SessionRecorder.saveRecordings([recording], at: directory)
        let indexURL = directory.appendingPathComponent("index.json")
        let originalIndex = try Data(contentsOf: indexURL)
        let finalURL = directory.appendingPathComponent(filename)
        let partialURL = directory.appendingPathComponent(".\(filename).partial")
        let finalData = Data("final-evidence".utf8)
        let partialData = Data("partial-evidence".utf8)
        try finalData.write(to: finalURL)
        try partialData.write(to: partialURL)

        #expect(throws: InjectedIndexFailure.self) {
            try SessionRecorder.deleteRecording(
                recording,
                at: directory,
                indexWriter: { _, _ in throw InjectedIndexFailure() }
            )
        }

        #expect(try Data(contentsOf: indexURL) == originalIndex)
        #expect(try Data(contentsOf: finalURL) == finalData)
        #expect(try Data(contentsOf: partialURL) == partialData)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".\(filename).deleting").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".\(filename).partial.deleting").path
        ))
    }

    @Test @MainActor func recordingDeletionAcceptsVerifiedCommitAfterWriterReportsFailure() throws {
        struct InjectedPostCommitFailure: Error {}

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glas-recording-delete-postcommit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingID = UUID()
        let sessionID = UUID()
        let filename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: "Committed",
            host: "committed.example.com",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_010),
            eventCount: 1,
            filename: filename,
            capturesInput: false,
            isComplete: true
        )
        try SessionRecorder.saveRecordings([recording], at: directory)
        let finalURL = directory.appendingPathComponent(filename)
        let partialURL = directory.appendingPathComponent(".\(filename).partial")
        try Data("final-evidence".utf8).write(to: finalURL)
        try Data("partial-evidence".utf8).write(to: partialURL)

        try SessionRecorder.deleteRecording(
            recording,
            at: directory,
            indexWriter: { recordings, directory in
                try SessionRecorder.saveRecordings(recordings, at: directory)
                throw InjectedPostCommitFailure()
            }
        )

        #expect(try SessionRecorder.verifiedRecordings(at: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".\(filename).deleting").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".\(filename).partial.deleting").path
        ))
    }

    @Test @MainActor func recordingDeletionReconcilesCrashQuarantineFromVerifiedIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glas-recording-delete-reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingID = UUID()
        let sessionID = UUID()
        let filename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: "Recovery",
            host: "recovery.example.com",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_010),
            eventCount: 1,
            filename: filename,
            capturesInput: false,
            isComplete: true
        )
        let finalURL = directory.appendingPathComponent(filename)
        let quarantineURL = directory.appendingPathComponent(".\(filename).deleting")
        let evidence = Data("crash-evidence".utf8)

        try SessionRecorder.saveRecordings([recording], at: directory)
        try evidence.write(to: finalURL)
        try FileManager.default.moveItem(at: finalURL, to: quarantineURL)

        #expect(try SessionRecorder.verifiedRecordings(at: directory) == [recording])
        #expect(try Data(contentsOf: finalURL) == evidence)
        #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))

        try SessionRecorder.saveRecordings([], at: directory)
        try FileManager.default.moveItem(at: finalURL, to: quarantineURL)

        #expect(try SessionRecorder.verifiedRecordings(at: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    @Test @MainActor func recorderRecoveryPreservesInterruptedStateAndStableEndTime() {
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)
        let interruptionTime = startTime.addingTimeInterval(75)
        let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: "example",
            host: "example.com",
            startTime: startTime,
            endTime: nil,
            eventCount: 12,
            filename: "\(sessionID.uuidString)_\(recordingID.uuidString).cast",
            capturesInput: false,
            isComplete: false
        )

        let recovered = SessionRecorder.recoveredInterruptedRecording(
            recording,
            modificationDate: interruptionTime
        )
        let recoveredAgain = SessionRecorder.recoveredInterruptedRecording(
            recovered,
            modificationDate: interruptionTime.addingTimeInterval(300)
        )

        #expect(!recovered.isComplete)
        #expect(recovered.endTime == interruptionTime)
        #expect(!recoveredAgain.isComplete)
        #expect(recoveredAgain.endTime == interruptionTime)
    }

    @Test @MainActor func recorderDeletionRequiresVerifiedAbsence() throws {
        struct InjectedRemovalFailure: Error {}

        let url = URL(fileURLWithPath: "/recordings/incomplete.cast")
        var exists = true
        var removeCalls = 0

        #expect(throws: SessionRecordingStorageError.deletionNotVerified(filename: "incomplete.cast")) {
            try SessionRecorder.removeItemVerifyingAbsence(
                at: url,
                itemExists: { _ in exists },
                removeItem: { _ in removeCalls += 1 }
            )
        }
        #expect(removeCalls == 1)

        let removedDespiteProviderError = try SessionRecorder.removeItemVerifyingAbsence(
            at: url,
            itemExists: { _ in exists },
            removeItem: { _ in
                removeCalls += 1
                exists = false
                throw InjectedRemovalFailure()
            }
        )
        #expect(removedDespiteProviderError)
        #expect(removeCalls == 2)

        let alreadyAbsent = try SessionRecorder.removeItemVerifyingAbsence(
            at: url,
            itemExists: { _ in false },
            removeItem: { _ in Issue.record("Removal must not run for an absent file") }
        )
        #expect(!alreadyAbsent)
    }

    @Test @MainActor func recorderFailedDeletionRetainsIncompleteIndexEntryForRetry() throws {
        let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: "example",
            host: "example.com",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_030),
            eventCount: 5,
            filename: "\(sessionID.uuidString)_\(recordingID.uuidString).cast",
            capturesInput: false,
            isComplete: false
        )

        let retained = SessionRecorder.updatedIndex(
            [],
            recording: recording,
            retainRecording: true
        )
        let removedAfterVerifiedDeletion = SessionRecorder.updatedIndex(
            retained,
            recording: recording,
            retainRecording: false
        )

        let retainedRecording = try #require(retained.first)
        #expect(retained.count == 1)
        #expect(retainedRecording.id == recordingID)
        #expect(!retainedRecording.isComplete)
        #expect(removedAfterVerifiedDeletion.isEmpty)
    }

    @Test func recorderAggregatePolicyBoundsCountBytesAndAgeWithoutPruning() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = SessionRecordingStoragePolicy(
            maximumCount: 2,
            maximumAggregateBytes: 100,
            maximumAge: 24 * 60 * 60
        )

        try BoundedStorage.validateRecordingCollection(
            SessionRecordingStorageUsage(
                recordingCount: 1,
                totalBytes: 99,
                oldestStartTime: now.addingTimeInterval(-24 * 60 * 60)
            ),
            now: now,
            policy: policy
        )

        #expect(throws: SessionRecordingStorageError.maximumCountReached(limit: 2)) {
            try BoundedStorage.validateRecordingCollection(
                SessionRecordingStorageUsage(
                    recordingCount: 2,
                    totalBytes: 99,
                    oldestStartTime: now
                ),
                now: now,
                policy: policy
            )
        }
        #expect(throws: SessionRecordingStorageError.maximumAggregateBytesReached(limit: 100)) {
            try BoundedStorage.validateRecordingCollection(
                SessionRecordingStorageUsage(
                    recordingCount: 1,
                    totalBytes: 100,
                    oldestStartTime: now
                ),
                now: now,
                policy: policy
            )
        }
        #expect(throws: SessionRecordingStorageError.retentionReviewRequired(maximumAgeDays: 1)) {
            try BoundedStorage.validateRecordingCollection(
                SessionRecordingStorageUsage(
                    recordingCount: 1,
                    totalBytes: 99,
                    oldestStartTime: now.addingTimeInterval(-(24 * 60 * 60 + 1))
                ),
                now: now,
                policy: policy
            )
        }
    }

    @Test func terminalPastePolicyReviewsMultilineAndLargePayloads() {
        #expect(!SwiftTermPastePolicy.requiresReview("echo safe"))
        #expect(SwiftTermPastePolicy.requiresReview("echo one\necho two"))
        #expect(SwiftTermPastePolicy.requiresReview(
            String(repeating: "a", count: SwiftTermPastePolicy.directPasteMaximumBytes + 1)
        ))
    }

    @Test func terminalPastePolicyPreservesBracketedPasteFraming() {
        let framed = SwiftTermPastePolicy.framedData(for: "one\ntwo", bracketed: true)
        #expect(framed == Data("\u{1B}[200~one\ntwo\u{1B}[201~".utf8))
        #expect(SwiftTermPastePolicy.framedData(for: "one", bracketed: false) == Data("one".utf8))
    }

    @Test func terminalPastePolicyRejectsOversizedPayloadWithoutRetainingContent() throws {
        let text = String(repeating: "x", count: SwiftTermPastePolicy.maximumPayloadBytes + 1)
        let request = try #require(SwiftTermPastePolicy.reviewRequest(for: text, bracketed: false))

        #expect(request.exceedsMaximumSize)
        #expect(request.content.isEmpty)
        #expect(!SwiftTermPastePolicy.isAllowed(text))
    }

    #if canImport(UIKit)
    @Test func terminalRendererDiagnosticsDoNotInventUnobservedBackingState() {
        let model = SwiftTermHostModel()

        #expect(model.rendererDiagnostics.backend == .awaitingWindow)
        #expect(!model.rendererDiagnostics.isWindowAttached)
        #expect(model.rendererDiagnostics.hostBackingIsClear == nil)
        #expect(model.rendererDiagnostics.rendererBackingIsClear == nil)
        #expect(model.rendererDiagnostics.preservesTransparentBacking == nil)
        #expect(model.rendererDiagnostics.failureDescription == nil)
    }

    @Test func terminalHardwareKeyPolicyUsesCorrectXtermSequences() {
        #expect(
            SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: .keyboardF10)
                == Array("\u{1B}[21~".utf8)
        )
        #expect(
            SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: .keyboardF12)
                == Array("\u{1B}[24~".utf8)
        )
        #expect(
            SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: .keyboardF13)
                == Array("\u{1B}[25~".utf8)
        )
        #expect(
            SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: .keyboardF24)
                == Array("\u{1B}[45~".utf8)
        )
        #expect(SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: .keyboardF9) == nil)
        #expect(!SwiftTermRuntimeSettings(
            cursorStyle: "Block",
            blinkingCursor: true,
            scrollbackLines: 500
        ).optionAsMetaKey)
    }

    @Test @MainActor func terminalRendererActivatesAfterWindowAttachmentWithClearBacking() async throws {
        let model = SwiftTermHostModel()
        let hostView = SwiftTermHostView(
            model: model,
            theme: SwiftTermTheme(
                fontSize: 14,
                foreground: (1, 1, 1),
                background: (0, 0, 0, 0),
                cursor: (1, 1, 1)
            ),
            runtimeSettings: SwiftTermRuntimeSettings(
                cursorStyle: "Block",
                blinkingCursor: true,
                scrollbackLines: 500
            ),
            onSendData: { _ in },
            onResize: { _, _ in }
        )
        let controller = UIHostingController(rootView: hostView)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        let detachedDiagnostics = model.rendererDiagnostics
        #expect(detachedDiagnostics.backend == .awaitingWindow)
        #expect(!detachedDiagnostics.isWindowAttached)
        #expect(detachedDiagnostics.hostBackingIsClear == nil)
        #expect(detachedDiagnostics.rendererBackingIsClear == nil)
        #expect(detachedDiagnostics.failureDescription == nil)

        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        for _ in 0..<20 where model.rendererDiagnostics.backend == .awaitingWindow {
            controller.view.layoutIfNeeded()
            await Task.yield()
        }

        let attachedDiagnostics = model.rendererDiagnostics
        #expect(attachedDiagnostics.isWindowAttached)
        #if canImport(MetalKit)
        #expect(attachedDiagnostics.backend == .metal)
        #expect(attachedDiagnostics.failureDescription == nil)
        #expect(attachedDiagnostics.rendererBackingIsClear == true)
        #else
        #expect(attachedDiagnostics.backend == .coreGraphicsFallback)
        #expect(attachedDiagnostics.failureDescription != nil)
        #expect(attachedDiagnostics.rendererBackingIsClear == nil)
        #endif
        #expect(attachedDiagnostics.hostBackingIsClear == true)
        #expect(attachedDiagnostics.preservesTransparentBacking == true)
    }

    @Test func terminalITermFileReferenceRetainsOnlyBoundedMetadata() throws {
        let content = Array(
            "File=name=cmVwb3J0LnR4dA==;size=5;inline=0:SGVsbG8=".utf8
        )

        let kind = SwiftTermITermContentPolicy.semanticEventKind(for: content[...])
        guard case .fileReference(let reference) = kind else {
            Issue.record("Expected a file-reference semantic event")
            return
        }

        #expect(reference.suggestedName == "report.txt")
        #expect(reference.declaredByteCount == 5)
        #expect(reference.encodedPayloadByteCount == 8)
        #expect(!reference.requestsInlineDisplay)

        let unknownContent = Array("SetUserVar=token=cmVkYWN0ZWQ=".utf8)
        let unknownKind = SwiftTermITermContentPolicy.semanticEventKind(for: unknownContent[...])
        guard case .unhandledITermContent(let command, let byteCount) = unknownKind else {
            Issue.record("Expected an unhandled iTerm-content semantic event")
            return
        }
        #expect(command == "SetUserVar")
        #expect(byteCount == unknownContent.count)
    }

    @Test func terminalOSC52PolicyDeniesEveryRequestFormWithoutDecodingContent() {
        let write = SwiftTermOSC52Policy.evaluate(Array("c;SGVsbG8=".utf8)[...])
        #expect(write.disposition == .deniedWrite)
        #expect(write.encodedPayloadByteCount == 8)

        let query = SwiftTermOSC52Policy.evaluate(Array("c;?".utf8)[...])
        #expect(query.disposition == .deniedReadQuery)

        let unsupported = SwiftTermOSC52Policy.evaluate(Array("p;SGVsbG8=".utf8)[...])
        #expect(unsupported.disposition == .deniedUnsupportedSelection)

        let malformed = SwiftTermOSC52Policy.evaluate(Array("c;not base64".utf8)[...])
        #expect(malformed.disposition == .rejectedMalformed)

        let oversized = Array("c;".utf8) + Array(
            repeating: UInt8(ascii: "A"),
            count: SwiftTermOSC52Policy.maximumEncodedPayloadBytes + 4
        )
        let oversizedDecision = SwiftTermOSC52Policy.evaluate(oversized[...])
        #expect(oversizedDecision.disposition == .rejectedOversized)
        #expect(oversizedDecision.requestByteCount == oversized.count)
    }

    @Test @MainActor func terminalSemanticEventsFlowFromSwiftTermCallbacks() async throws {
        let model = SwiftTermHostModel()
        var streamedEvents: [SwiftTermSemanticEvent] = []
        var emittedData: [Data] = []
        let subscription = model.semanticEventPublisher.sink { event in
            streamedEvents.append(event)
        }
        defer { subscription.cancel() }
        let hostView = SwiftTermHostView(
            model: model,
            theme: SwiftTermTheme(
                fontSize: 14,
                foreground: (1, 1, 1),
                background: (0, 0, 0, 0),
                cursor: (1, 1, 1)
            ),
            runtimeSettings: SwiftTermRuntimeSettings(
                cursorStyle: "Block",
                blinkingCursor: true,
                scrollbackLines: 500
            ),
            onSendData: { emittedData.append($0) },
            onResize: { _, _ in }
        )
        let controller = UIHostingController(rootView: hostView)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)

        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = controller.view.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        for _ in 0..<20 where model.rendererDiagnostics.hostBackingIsClear == nil {
            controller.view.layoutIfNeeded()
            await Task.yield()
        }

        let terminalInput = [
            Data("\u{1B}]7;file://vision-pro/private/tmp\u{07}".utf8),
            Data(
                "\u{1B}]1337;File=name=cmVwb3J0LnR4dA==;size=5;inline=0:SGVsbG8=\u{07}".utf8
            ),
            Data("terminal output".utf8),
            Data("\u{1B}]52;c;SGVs".utf8),
            Data("bG8=\u{07}".utf8)
        ]
        for (index, data) in terminalInput.enumerated() {
            model.ingest(data: data, nonce: UInt64(index + 1))
        }

        for _ in 0..<40 {
            let hasWorkingDirectory = model.semanticEvents.contains { event in
                guard case .workingDirectoryChanged(let directory) = event.kind else { return false }
                return directory == "file://vision-pro/private/tmp"
            }
            let hasFileReference = model.semanticEvents.contains { event in
                guard case .fileReference(let reference) = event.kind else { return false }
                return reference.suggestedName == "report.txt"
                    && reference.declaredByteCount == 5
            }
            let hasDisplayRange = model.semanticEvents.contains { event in
                if case .displayRangeChanged = event.kind { return true }
                return false
            }
            let hasOSC52Denial = model.semanticEvents.contains { event in
                guard case .osc52Denied(let decision) = event.kind else { return false }
                return decision.disposition == .deniedWrite
                    && decision.encodedPayloadByteCount == 8
            }
            if hasWorkingDirectory && hasFileReference && hasDisplayRange && hasOSC52Denial {
                break
            }
            controller.view.layoutIfNeeded()
            await Task.yield()
        }

        let events = model.semanticEvents
        #expect(events.count <= SwiftTermHostModel.semanticEventHistoryLimit)
        #expect(Array(streamedEvents.suffix(events.count)) == events)
        #expect(events.allSatisfy {
            $0.schemaVersion == SwiftTermSemanticEvent.currentSchemaVersion
        })
        #expect(events.map(\.sequence) == events.map(\.sequence).sorted())
        #expect(events.contains { event in
            guard case .workingDirectoryChanged(let directory) = event.kind else { return false }
            return directory == "file://vision-pro/private/tmp"
        })
        #expect(events.contains { event in
            guard case .fileReference(let reference) = event.kind else { return false }
            return reference.suggestedName == "report.txt"
                && reference.declaredByteCount == 5
                && reference.encodedPayloadByteCount == 8
        })
        #expect(events.contains { event in
            if case .displayRangeChanged(let startY, let endY) = event.kind {
                return startY <= endY
            }
            return false
        })
        #expect(events.contains { event in
            guard case .osc52Denied(let decision) = event.kind else { return false }
            return decision.disposition == .deniedWrite
                && decision.requestByteCount == 10
                && decision.encodedPayloadByteCount == 8
        })

        func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        guard let terminalView = descendants(of: controller.view).first(where: {
            $0.accessibilityLabel == "Terminal"
        }) else {
            Issue.record("The hosted SwiftTerm view was not exposed as a terminal accessibility element")
            return
        }
        guard let textInput = terminalView as? any UITextInput else {
            Issue.record("The hosted SwiftTerm view does not conform to UITextInput")
            return
        }

        #expect(terminalView.isAccessibilityElement)
        #expect(terminalView.accessibilityValue?.contains("terminal output") == true)
        #expect(model.performanceDiagnostics.receivedChunkCount == UInt64(terminalInput.count))
        #expect(
            model.performanceDiagnostics.receivedByteCount
                == UInt64(terminalInput.reduce(0) { $0 + $1.count })
        )
        #expect(
            model.performanceDiagnostics.totalFeedDurationNanoseconds
                >= model.performanceDiagnostics.maximumFeedDurationNanoseconds
        )

        let inputChunkBaseline = model.performanceDiagnostics.emittedInputChunkCount
        let inputByteBaseline = model.performanceDiagnostics.emittedInputByteCount
        let emittedDataBaseline = emittedData.count
        textInput.setMarkedText("点", selectedRange: NSRange(location: 1, length: 0))
        #expect(model.isComposingText)
        #expect(emittedData.count == emittedDataBaseline)
        textInput.unmarkText()
        #expect(!model.isComposingText)
        #expect(emittedData.last == Data("点".utf8))
        #expect(
            model.performanceDiagnostics.emittedInputChunkCount
                == inputChunkBaseline + 1
        )
        #expect(
            model.performanceDiagnostics.emittedInputByteCount
                == inputByteBaseline + UInt64(Data("点".utf8).count)
        )

        let committedDataCount = emittedData.count
        textInput.setMarkedText("取消", selectedRange: NSRange(location: 2, length: 0))
        #expect(model.isComposingText)
        textInput.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        #expect(!model.isComposingText)
        #expect(emittedData.count == committedDataCount)
    }
    #endif

    @Test func terminalExternalLinkPolicyAllowsOnlyBoundedCredentialFreeWebURLs() throws {
        let request = try #require(SwiftTermExternalLinkPolicy.validatedRequest(
            for: "HTTPS://ExAmPle.com:8443/path?q=1#section"
        ))

        #expect(request.url.scheme == "https")
        #expect(request.normalizedHost == "example.com")
        #expect(request.port == 8443)
        #expect(request.exactURL == "https://ExAmPle.com:8443/path?q=1#section")

        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "javascript:alert(1)") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "file:///etc/passwd") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https://user:secret@example.com") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https:///missing-host") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: " https://example.com") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https://example.com/\nnext") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https://example.com%0A.evil") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https://example.com%0D.evil") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(for: "https://example.com%E2%80%AE.evil") == nil)
        #expect(SwiftTermExternalLinkPolicy.validatedRequest(
            for: "https://example.com/" + String(
                repeating: "a",
                count: SwiftTermExternalLinkPolicy.maximumURLBytes
            )
        ) == nil)
    }

    @Test func generatedCommandConfirmationKeepsTheReviewedExactSnapshot() {
        var editableCommand = "rm -rf ./build"
        let confirmation = GeneratedCommandConfirmation(command: editableCommand)
        editableCommand = "pwd"

        #expect(confirmation.exactCommand == "rm -rf ./build")
        #expect(confirmation.assessment.requiresConfirmation)
        #expect(confirmation.assessment.reasons.contains("Destructive or system-modifying utility"))
        #expect(editableCommand != confirmation.exactCommand)
    }

    @Test func terminalRuntimeSettingsClampScrollbackAtBothBounds() {
        #expect(SwiftTermRuntimeSettings(
            cursorStyle: "Block",
            blinkingCursor: true,
            scrollbackLines: -1
        ).scrollbackLines == 0)
        #expect(SwiftTermRuntimeSettings(
            cursorStyle: "Block",
            blinkingCursor: true,
            scrollbackLines: 100_000
        ).scrollbackLines == 100_000)
        #expect(SwiftTermRuntimeSettings(
            cursorStyle: "Block",
            blinkingCursor: true,
            scrollbackLines: Int.max
        ).scrollbackLines == 100_000)
    }

    @Test @MainActor func settingsMigrationPrefersCanonicalOpacityAndBoundsScrollback() {
        #expect(SettingsManager.resolvedWindowOpacity(canonical: 0.25, legacy: 0.9) == 0.25)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: nil, legacy: 0.9) == 0.9)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: 2, legacy: nil) == 1)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: -1, legacy: nil) == 0)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: Double.infinity, legacy: 0.9) == 0)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: true, legacy: 0.9) == 0)
        #expect(SettingsManager.resolvedWindowOpacity(canonical: "opaque", legacy: 0.9) == 0)
        #expect(SettingsManager.clampedScrollbackLines(-1) == 0)
        #expect(SettingsManager.clampedScrollbackLines(10_000) == 10_000)
        #expect(SettingsManager.clampedScrollbackLines(Int.max) == 100_000)
    }

    @Test @MainActor func terminalGlassAppearancePreservesIndependentEndpointMatrix() {
        let cases: [(opacity: Double, blur: Double, paints: Bool, frosts: Bool, transparent: Bool)] = [
            (0, 0, false, false, true),
            (0, 1, false, true, false),
            (1, 0, true, false, false),
            (1, 1, true, true, false)
        ]

        for value in cases {
            let appearance = TerminalGlassAppearance(opacity: value.opacity, blur: value.blur)
            #expect(appearance.opacity == value.opacity)
            #expect(appearance.blur == value.blur)
            #expect(appearance.paintsTheme == value.paints)
            #expect(appearance.compositesBlur == value.frosts)
            #expect(appearance.isFullyTransparent == value.transparent)
        }

        #expect(TerminalGlassAppearance(opacity: -1, blur: 2) == .init(opacity: 0, blur: 1))
        #expect(TerminalGlassAppearance(opacity: .nan, blur: .infinity) == .init(opacity: 0, blur: 0))
    }

    @Test @MainActor func terminalGlassAppearanceResolvesOverridesPerDimension() {
        let globalOpacity = 0.25
        let globalBlur = 0.75

        #expect(TerminalGlassAppearance.resolved(
            globalOpacity: globalOpacity,
            globalBlur: globalBlur,
            sessionOverride: nil
        ) == .init(opacity: 0.25, blur: 0.75))
        #expect(TerminalGlassAppearance.resolved(
            globalOpacity: globalOpacity,
            globalBlur: globalBlur,
            sessionOverride: TerminalSessionOverride(windowOpacity: 1)
        ) == .init(opacity: 1, blur: 0.75))
        #expect(TerminalGlassAppearance.resolved(
            globalOpacity: globalOpacity,
            globalBlur: globalBlur,
            sessionOverride: TerminalSessionOverride(blurBackground: 0)
        ) == .init(opacity: 0.25, blur: 0))
        #expect(TerminalGlassAppearance.resolved(
            globalOpacity: globalOpacity,
            globalBlur: globalBlur,
            sessionOverride: TerminalSessionOverride(windowOpacity: 0, blurBackground: 1)
        ) == .init(opacity: 0, blur: 1))
    }

    @Test @MainActor func appearanceSettingsRoundTripCanonicalGlobalAndSessionValues() throws {
        let suiteName = "sh.glas.tests.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.91, forKey: UserDefaultsKeys.backgroundFill)
        let sessionID = UUID()
        let settings = SettingsManager(
            loadImmediately: false,
            settingsDefaults: defaults,
            sshKeyDefaults: defaults
        )
        settings.windowOpacity = 0.37
        settings.blurBackground = 0.64
        settings.updateSessionOverride(for: sessionID) { override in
            override.windowOpacity = 0
            override.blurBackground = 1
        }
        settings.saveSettings()

        #expect(defaults.double(forKey: UserDefaultsKeys.windowOpacity) == 0.37)
        #expect(defaults.double(forKey: UserDefaultsKeys.blurBackground) == 0.64)
        #expect(defaults.object(forKey: UserDefaultsKeys.backgroundFill) == nil)

        let reloaded = SettingsManager(
            settingsDefaults: defaults,
            sshKeyDefaults: defaults
        )
        #expect(reloaded.windowOpacity == 0.37)
        #expect(reloaded.blurBackground == 0.64)
        #expect(reloaded.sessionOverride(for: sessionID)?.windowOpacity == 0)
        #expect(reloaded.sessionOverride(for: sessionID)?.blurBackground == 1)
    }

    @Test @MainActor func appearanceMigrationPrefersCanonicalOpacityAndMigratesBooleanOrNumericBlur() throws {
        let booleanSuite = "sh.glas.tests.appearance.boolean.\(UUID().uuidString)"
        let booleanDefaults = try #require(UserDefaults(suiteName: booleanSuite))
        booleanDefaults.removePersistentDomain(forName: booleanSuite)
        defer { booleanDefaults.removePersistentDomain(forName: booleanSuite) }
        booleanDefaults.set(0.2, forKey: UserDefaultsKeys.windowOpacity)
        booleanDefaults.set(0.9, forKey: UserDefaultsKeys.backgroundFill)
        booleanDefaults.set(true, forKey: UserDefaultsKeys.blurBackground)

        let booleanMigrated = SettingsManager(
            settingsDefaults: booleanDefaults,
            sshKeyDefaults: booleanDefaults
        )
        #expect(booleanMigrated.windowOpacity == 0.2)
        #expect(booleanMigrated.blurBackground == 1)
        #expect(booleanDefaults.object(forKey: UserDefaultsKeys.backgroundFill) == nil)
        #expect(SettingsManager.resolvedBlurBackground(false) == 0)

        let numericSuite = "sh.glas.tests.appearance.numeric.\(UUID().uuidString)"
        let numericDefaults = try #require(UserDefaults(suiteName: numericSuite))
        numericDefaults.removePersistentDomain(forName: numericSuite)
        defer { numericDefaults.removePersistentDomain(forName: numericSuite) }
        numericDefaults.set(0.42, forKey: UserDefaultsKeys.blurBackground)
        let numericMigrated = SettingsManager(
            settingsDefaults: numericDefaults,
            sshKeyDefaults: numericDefaults
        )
        #expect(numericMigrated.blurBackground == 0.42)
        #expect(SettingsManager.resolvedBlurBackground(-1.0) == 0)
        #expect(SettingsManager.resolvedBlurBackground(2.0) == 1)
        #expect(SettingsManager.resolvedBlurBackground(Double.nan) == 0)
        #expect(SettingsManager.resolvedBlurBackground("maximum") == 0)
    }

    @Test func sessionAppearancePayloadMigratesLegacyBlurAndEncodesOnlyCanonicalKeys() throws {
        let booleanTrue = try JSONDecoder().decode(
            TerminalSessionOverride.self,
            from: Data(#"{"blurBackground":true}"#.utf8)
        )
        let booleanFalse = try JSONDecoder().decode(
            TerminalSessionOverride.self,
            from: Data(#"{"blurBackground":false}"#.utf8)
        )
        let numeric = try JSONDecoder().decode(
            TerminalSessionOverride.self,
            from: Data(#"{"blurBackground":0.42}"#.utf8)
        )
        let canonicalWins = try JSONDecoder().decode(
            TerminalSessionOverride.self,
            from: Data(#"{"windowOpacity":0.2,"backgroundFill":0.9,"blurBackground":2}"#.utf8)
        )

        #expect(booleanTrue.blurBackground == 1)
        #expect(booleanFalse.blurBackground == 0)
        #expect(numeric.blurBackground == 0.42)
        #expect(canonicalWins.windowOpacity == 0.2)
        #expect(canonicalWins.blurBackground == 1)

        let invalid = TerminalSessionOverride(windowOpacity: .nan, blurBackground: -Double.infinity)
        #expect(invalid.windowOpacity == 0)
        #expect(invalid.blurBackground == 0)

        let encoded = try JSONEncoder().encode(canonicalWins)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["windowOpacity"] as? Double == 0.2)
        #expect(object["blurBackground"] as? Double == 1)
        #expect(object["backgroundFill"] == nil)
    }

    @Test func boundedStorageRejectsLimitsAndPreservesHeadroom() throws {
        try BoundedStorage.validateWrite(
            currentBytes: 100,
            incomingBytes: 20,
            maximumBytes: 120,
            availableCapacity: 70,
            headroom: 50
        )

        #expect(throws: BoundedStorageError.sizeLimitExceeded(limit: 119)) {
            try BoundedStorage.validateWrite(
                currentBytes: 100,
                incomingBytes: 20,
                maximumBytes: 119,
                availableCapacity: 1_000,
                headroom: 50
            )
        }

        #expect(throws: BoundedStorageError.insufficientFreeSpace(required: 70, available: 69)) {
            try BoundedStorage.validateWrite(
                currentBytes: 100,
                incomingBytes: 20,
                maximumBytes: 120,
                availableCapacity: 69,
                headroom: 50
            )
        }

        #expect(throws: BoundedStorageError.sizeLimitExceeded(limit: UInt64.max)) {
            try BoundedStorage.validateWrite(
                currentBytes: UInt64.max,
                incomingBytes: 1,
                maximumBytes: UInt64.max,
                availableCapacity: UInt64.max,
                headroom: 0
            )
        }
    }

    @Test @MainActor func socks5GreetingWaitsForAllMethodsAndRequiresUsernamePassword() {
        var fragmented = ByteBuffer(bytes: [0x05, 0x02, 0x00])
        #expect(PortForwardManager.parseSOCKS5Greeting(from: &fragmented) == .incomplete)
        #expect(fragmented.readerIndex == 0)

        fragmented.writeInteger(UInt8(0x02))
        #expect(PortForwardManager.parseSOCKS5Greeting(from: &fragmented) == .selectUsernamePassword)
        #expect(fragmented.readableBytes == 0)

        var unsupported = ByteBuffer(bytes: [0x05, 0x01, 0x00])
        #expect(PortForwardManager.parseSOCKS5Greeting(from: &unsupported) == .rejectAuthenticationMethods)
    }

    @Test @MainActor func socks5RFC1929ParserIsIncrementalBoundedAndPreservesCoalescedRequest() throws {
        var authentication = ByteBuffer(bytes: [0x01, 0x04, 0x75, 0x73])
        #expect(PortForwardManager.parseSOCKS5Authentication(from: &authentication) == .incomplete)
        #expect(authentication.readerIndex == 0)

        authentication.writeBytes([0x65, 0x72, 0x06])
        authentication.writeBytes(Array("secret".utf8))
        authentication.writeBytes([0x05, 0x01, 0x00, 0x01])
        let parsed = PortForwardManager.parseSOCKS5Authentication(from: &authentication)
        let presented: SOCKS5CredentialBytes
        guard case .authenticate(let credentials) = parsed else {
            Issue.record("Expected parsed RFC 1929 credentials")
            return
        }
        presented = credentials
        #expect(presented.username == Array("user".utf8))
        #expect(presented.password == Array("secret".utf8))
        #expect(authentication.getBytes(
            at: authentication.readerIndex,
            length: authentication.readableBytes
        ) == [0x05, 0x01, 0x00, 0x01])

        var emptyUsername = ByteBuffer(bytes: [0x01, 0x00])
        #expect(PortForwardManager.parseSOCKS5Authentication(from: &emptyUsername) == .invalidCredentials)
        var wrongVersion = ByteBuffer(bytes: [0x02, 0x01])
        #expect(PortForwardManager.parseSOCKS5Authentication(from: &wrongVersion) == .invalidVersion)
        #expect(PortForwardManager.maximumSOCKS5AuthenticationBytes == 513)

        var boundedBuffer = ByteBuffer(bytes: Array(
            repeating: UInt8(0),
            count: PortForwardManager.maximumSOCKS5BufferedHandshakeBytes
        ))
        var excess = ByteBuffer(bytes: [0x00])
        #expect(!PortForwardManager.appendSOCKS5HandshakeBytes(&excess, to: &boundedBuffer))
    }

    @Test @MainActor func socks5CredentialPolicyValidatesUTF8LengthsAndComparesBothFields() throws {
        let expected = try #require(PortForwardManager.socks5Credentials(
            username: "user",
            password: "secret"
        ))
        #expect(PortForwardManager.socks5Credentials(username: "", password: "secret") == nil)
        #expect(PortForwardManager.socks5Credentials(username: "user", password: "") == nil)
        #expect(PortForwardManager.socks5Credentials(
            username: String(repeating: "u", count: 256),
            password: "secret"
        ) == nil)

        #expect(PortForwardManager.authenticateSOCKS5(presented: expected, expected: expected))
        #expect(!PortForwardManager.authenticateSOCKS5(
            presented: .init(username: Array("user".utf8), password: Array("secreu".utf8)),
            expected: expected
        ))
        #expect(!PortForwardManager.authenticateSOCKS5(
            presented: .init(username: Array("admin".utf8), password: Array("secret".utf8)),
            expected: expected
        ))
        #expect(!PortForwardManager.constantTimeSOCKS5FieldEquals(
            Array("user".utf8),
            Array("user\0".utf8)
        ))
    }

    @Test @MainActor func socks5CredentialsRemainManagerMemoryOnlyAndLegacyDynamicAddFailsClosed() throws {
        let sessionID = UUID()
        let legacyManager = PortForwardManager()
        let legacyForward = PortForward(type: .dynamic, localPort: 10_80, remotePort: 0)
        legacyManager.addForward(legacyForward, to: sessionID)
        #expect(legacyManager.forwards(for: sessionID).first?.status == .error)
        #expect(legacyManager.configureSOCKS5Credentials(
            for: legacyForward.id,
            username: "proxy-user",
            password: "session-secret"
        ))
        #expect(legacyManager.forwards(for: sessionID).first?.status == .inactive)

        let manager = PortForwardManager()
        let forward = PortForward(type: .dynamic, localPort: 10_81, remotePort: 0)
        #expect(manager.addForward(
            forward,
            to: sessionID,
            socks5Username: "proxy-user",
            socks5Password: "session-secret"
        ))
        let encodedForward = String(decoding: try JSONEncoder().encode(forward), as: UTF8.self)
        #expect(!encodedForward.contains("proxy-user"))
        #expect(!encodedForward.contains("session-secret"))
    }

    @Test func socks5ConnectionLimiterRejectsExcessPreAuthenticationClients() async {
        let limiter = SOCKS5ConnectionLimiter(maximumConnections: 2)

        #expect(await limiter.acquire())
        #expect(await limiter.acquire())
        #expect(!(await limiter.acquire()))
        await limiter.release()
        #expect(await limiter.acquire())
        #expect(PortForwardManager.maximumConcurrentSOCKS5Connections == 64)
        #expect(PortForwardManager.socks5HandshakeTimeout == .seconds(15))
    }

    @Test func socks5HandshakePermitReleasesItsSlotExactlyOnce() async {
        let limiter = SOCKS5ConnectionLimiter(maximumConnections: 1)
        #expect(await limiter.acquire())
        let permit = SOCKS5ConnectionPermit(limiter: limiter)

        await permit.release()
        await permit.release()

        #expect(await limiter.acquire())
        #expect(!(await limiter.acquire()))
    }

    @Test @MainActor func socks5ConnectParserPreservesCoalescedPayload() {
        let domain = Array("example.com".utf8)
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(domain.count)]
        bytes.append(contentsOf: domain)
        bytes.append(contentsOf: [0x01, 0xBB])
        bytes.append(contentsOf: Array("GET /".utf8))
        var buffer = ByteBuffer(bytes: bytes)

        #expect(
            PortForwardManager.parseSOCKS5ConnectRequest(from: &buffer)
                == .connect(SOCKS5Target(host: "example.com", port: 443))
        )
        #expect(buffer.readString(length: buffer.readableBytes) == "GET /")
    }

    @Test @MainActor func socks5ConnectParserHandlesFragmentedIPv4AndValidatesHeader() {
        var fragmented = ByteBuffer(bytes: [0x05, 0x01, 0x00, 0x01, 127])
        #expect(PortForwardManager.parseSOCKS5ConnectRequest(from: &fragmented) == .incomplete)
        #expect(fragmented.readerIndex == 0)

        fragmented.writeBytes([0, 0, 1, 0x1F, 0x90])
        #expect(
            PortForwardManager.parseSOCKS5ConnectRequest(from: &fragmented)
                == .connect(SOCKS5Target(host: "127.0.0.1", port: 8080))
        )

        var badReserved = ByteBuffer(bytes: [0x05, 0x01, 0x01, 0x01])
        #expect(PortForwardManager.parseSOCKS5ConnectRequest(from: &badReserved) == .invalidReservedByte)

        var unsupportedCommand = ByteBuffer(bytes: [0x05, 0x02, 0x00, 0x01])
        #expect(PortForwardManager.parseSOCKS5ConnectRequest(from: &unsupportedCommand) == .unsupportedCommand)
    }

    // MARK: - TerminalSession Lifecycle Tests

    @Test @MainActor func savedSessionPolicyResolvesCurrentProfileAndFailsClosedAfterDeletion() async throws {
        let original = ServerConfiguration(
            name: "Saved",
            host: "old.example.com",
            username: "user",
            authMethod: .sshKey,
            sshKeyID: UUID()
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [original]
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false
        )
        let settings = SettingsManager(loadImmediately: false)
        let session = TerminalSession(server: original)
        manager.registerSession(session)

        var current = original
        current.name = "Current"
        current.host = "current.example.com"
        serverManager.servers = [current]

        let context = try manager.reconnectContext(for: session)
        #expect(context.server == current)
        #expect(context.password == nil)

        serverManager.servers = []

        do {
            _ = try await manager.createAuthorizedSession(
                for: original,
                settingsManager: settings
            )
            Issue.record("A deleted saved profile must not launch from a stale value")
        } catch SessionOpenError.savedServerNotFound {
            // Expected.
        } catch {
            Issue.record("Expected savedServerNotFound, received \(error)")
        }

        do {
            _ = try await manager.duplicateAuthorizedSession(
                from: session,
                settingsManager: settings
            )
            Issue.record("A deleted saved profile must not duplicate from session state")
        } catch SessionOpenError.savedServerNotFound {
            // Expected.
        } catch {
            Issue.record("Expected savedServerNotFound, received \(error)")
        }

        do {
            try await manager.reconnect(session, settingsManager: settings)
            Issue.record("A deleted saved profile must not reconnect from session state")
        } catch SessionOpenError.savedServerNotFound {
            // Expected.
        } catch {
            Issue.record("Expected savedServerNotFound, received \(error)")
        }

        do {
            _ = try await manager.createAuthorizedSessionByServerID(
                original.id,
                settingsManager: settings
            )
            Issue.record("A deleted layout target must not launch")
        } catch SessionOpenError.savedServerNotFound {
            // Expected.
        } catch {
            Issue.record("Expected savedServerNotFound, received \(error)")
        }
    }

    @Test @MainActor func transientSessionPasswordRemainsMemoryBoundUntilUnregister() throws {
        let transient = ServerConfiguration(
            name: "Quick Connect",
            host: "transient.example.com",
            username: "user"
        )
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false
        )
        let session = TerminalSession(server: transient)
        manager.registerTransientSession(session, password: "memory-only-password")

        let reconnect = try manager.reconnectContext(for: session)
        #expect(reconnect.server == transient)
        #expect(reconnect.password == "memory-only-password")

        do {
            _ = try SessionManager.decodeTransientPassword(
                SecureBytes(Data([0xFF, 0xFE]))
            )
            Issue.record("Malformed transient credential bytes must fail closed")
        } catch SessionOpenError.invalidTransientCredentialEncoding {
            // Expected.
        } catch {
            Issue.record("Expected invalidTransientCredentialEncoding, received \(error)")
        }

        manager.closeSession(session)

        do {
            _ = try manager.reconnectContext(for: session)
            Issue.record("Unregister must discard transient reconnect state")
        } catch SessionOpenError.sessionNotRegistered {
            // Expected.
        } catch {
            Issue.record("Expected sessionNotRegistered, received \(error)")
        }
    }

    @Test @MainActor func abandoningPendingHostTrustClosesAndUnregistersInvisibleSession() {
        let server = ServerConfiguration(
            name: "Pending Trust",
            host: "pending.example.com",
            username: "user"
        )
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false
        )
        let session = TerminalSession(server: server)
        session.pendingHostKeyChallenge = HostKeyTrustChallenge(
            host: server.host,
            port: server.port,
            algorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:test-fixture",
            keyDataBase64: Data("test-key".utf8).base64EncodedString(),
            reason: .unknown
        )
        manager.registerTransientSession(session, password: "memory-only-password")

        manager.closePendingHostTrustSession(session)

        #expect(session.pendingHostKeyChallenge == nil)
        #expect(session.state == .disconnected)
        #expect(manager.session(for: session.id) == nil)
    }

    @Test @MainActor func connectionPreparationPreservesDeclaredJumpHostOrder() throws {
        let firstHop = ServerConfiguration(
            name: "First Hop",
            host: "first.example.com",
            username: "first"
        )
        let secondHop = ServerConfiguration(
            name: "Second Hop",
            host: "second.example.com",
            username: "second"
        )
        let target = ServerConfiguration(
            name: "Target",
            host: "target.example.com",
            username: "target",
            jumpHostIDs: [firstHop.id, secondHop.id]
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [secondHop, target, firstHop]
        var retrievalOrder: [UUID] = []
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { server in
                retrievalOrder.append(server.id)
                return "password"
            }
        )

        let prepared = try manager.prepareConnection(for: target)

        #expect(retrievalOrder == [target.id, firstHop.id, secondHop.id])
        #expect(prepared.jumpHostChain.map(\.id) == [firstHop.id, secondHop.id])
        #expect(prepared.authentication.jumpHosts.map(\.serverID) == [firstHop.id, secondHop.id])
    }

    @Test @MainActor func jumpHostPasswordPreparationDistinguishesMissingFromUnavailable() {
        let hop = ServerConfiguration(
            name: "Jump",
            host: "jump.example.com",
            username: "jump"
        )
        let target = ServerConfiguration(
            name: "Target",
            host: "target.example.com",
            username: "target",
            jumpHostIDs: [hop.id]
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [target, hop]

        let missingManager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { server in
                if server.id == hop.id { throw SecretStoreError.notFound }
                return "target-password"
            }
        )
        do {
            _ = try missingManager.prepareConnection(for: target)
            Issue.record("A missing jump-host password must fail preparation")
        } catch let error as SessionOpenError {
            if case .missingPassword(let server, .jumpHost(1)) = error {
                #expect(server.id == hop.id)
            } else {
                Issue.record("Expected jump-host missingPassword, received \(error)")
            }
        } catch {
            Issue.record("Expected SessionOpenError, received \(error)")
        }

        let unavailableManager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { server in
                if server.id == hop.id {
                    throw SecretStoreError.queryFailed(status: -25_308)
                }
                return "target-password"
            }
        )
        do {
            _ = try unavailableManager.prepareConnection(for: target)
            Issue.record("A locked or failed Keychain query must fail preparation")
        } catch let error as SessionOpenError {
            if case .credentialUnavailable(let server, .jumpHost(1)) = error {
                #expect(server.id == hop.id)
            } else {
                Issue.record("Expected jump-host credentialUnavailable, received \(error)")
            }
        } catch {
            Issue.record("Expected SessionOpenError, received \(error)")
        }
    }

    @Test @MainActor func initialLaunchPreparesEveryCredentialBeforeSessionRegistration() async {
        let hop = ServerConfiguration(
            name: "Jump",
            host: "jump.example.com",
            username: "jump"
        )
        let target = ServerConfiguration(
            name: "Target",
            host: "target.example.com",
            username: "target",
            jumpHostIDs: [hop.id]
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [target, hop]
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { server in
                if server.id == hop.id { throw SecretStoreError.notFound }
                return "target-password"
            }
        )

        do {
            _ = try await manager.createAuthorizedSession(
                for: target,
                settingsManager: SettingsManager(loadImmediately: false)
            )
            Issue.record("Initial launch must prepare the full jump chain before connecting")
        } catch let error as SessionOpenError {
            if case .missingPassword(let server, .jumpHost(1)) = error {
                #expect(server.id == hop.id)
            } else {
                Issue.record("Expected jump-host missingPassword, received \(error)")
            }
        } catch {
            Issue.record("Expected SessionOpenError, received \(error)")
        }

        #expect(manager.sessions.isEmpty)
    }

    @Test @MainActor func reconnectPreparationRefreshesCurrentJumpHostAndFailsAfterDeletion() throws {
        let originalHop = ServerConfiguration(
            name: "Jump",
            host: "old-jump.example.com",
            username: "jump"
        )
        let target = ServerConfiguration(
            name: "Target",
            host: "target.example.com",
            username: "target",
            jumpHostIDs: [originalHop.id]
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [target, originalHop]
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { _ in "password" }
        )
        let session = TerminalSession(server: target)
        manager.registerSession(session)

        var currentHop = originalHop
        currentHop.host = "current-jump.example.com"
        serverManager.servers = [target, currentHop]

        let context = try manager.reconnectContext(for: session)
        let refreshed = try manager.prepareConnection(for: context.server)
        #expect(refreshed.jumpHostChain == [currentHop])

        serverManager.servers = [target]
        do {
            _ = try manager.prepareConnection(for: context.server)
            Issue.record("Deleting a current jump host must block reconnect preparation")
        } catch SessionOpenError.jumpHostNotFound {
            // Expected.
        } catch {
            Issue.record("Expected jumpHostNotFound, received \(error)")
        }
    }

    @Test @MainActor func manualReconnectCancelsAutomaticReconnectBeforeCredentialQuery() async {
        let target = ServerConfiguration(
            name: "Target",
            host: "target.example.com",
            username: "target"
        )
        let session = TerminalSession(server: target)
        var stateObservedDuringQuery: SessionState?
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [target]
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrievePassword: { _ in
                stateObservedDuringQuery = session.state
                throw SecretStoreError.queryFailed(status: -25_308)
            }
        )
        manager.registerSession(session)
        session.state = .reconnecting

        do {
            try await manager.reconnect(
                session,
                settingsManager: SettingsManager(loadImmediately: false)
            )
            Issue.record("Credential query failure must block reconnect")
        } catch let error as SessionOpenError {
            if case .credentialUnavailable(let server, .target) = error {
                #expect(server.id == target.id)
            } else {
                Issue.record("Expected target credentialUnavailable, received \(error)")
            }
        } catch {
            Issue.record("Expected SessionOpenError, received \(error)")
        }

        #expect(stateObservedDuringQuery == .disconnected)
    }

    @Test @MainActor func corruptSSHKeyMaterialMapsToTypedSessionError() {
        let keyID = UUID()
        let target = ServerConfiguration(
            name: "Key Target",
            host: "key.example.com",
            username: "target",
            authMethod: .sshKey,
            sshKeyID: keyID
        )
        let serverManager = ServerManager(loadImmediately: false)
        serverManager.servers = [target]
        let manager = SessionManager(
            serverManager: serverManager,
            loadImmediately: false,
            retrieveSSHKey: { _ in
                SSHKeyMaterial(
                    privateKey: SecureBytes(Data([0xFF, 0xFE])),
                    passphrase: nil
                )
            }
        )

        do {
            _ = try manager.prepareConnection(for: target)
            Issue.record("Corrupt SSH key bytes must fail preparation")
        } catch let error as SessionOpenError {
            if case .invalidSSHKey(let server, .target) = error {
                #expect(server.id == target.id)
            } else {
                Issue.record("Expected target invalidSSHKey, received \(error)")
            }
        } catch {
            Issue.record("Expected SessionOpenError, received \(error)")
        }
    }

    @Test @MainActor func sessionManagerLifecycleHookStopsForwardsOnceBeforeEveryDetachTransition() {
        let detachingTransitions: [TerminalSessionLifecycleTransition] = [
            .manualReconnect,
            .automaticReconnect,
            .explicitDisconnect,
            .cleanRemoteExit,
        ]

        for transition in detachingTransitions {
            let session = TerminalSession(server: ServerConfiguration(
                name: "Lifecycle",
                host: "example.com",
                username: "user"
            ))
            var stoppedSessionIDs: [UUID] = []
            var hookObservedAttachedConnection = false
            let manager = SessionManager(
                serverManager: ServerManager(loadImmediately: false),
                loadImmediately: false,
                stopSessionForwards: { sessionID in
                    hookObservedAttachedConnection = session.getSSHConnection() != nil
                    stoppedSessionIDs.append(sessionID)
                }
            )
            manager.registerSession(session)

            _ = session.detachSSHConnection(for: transition)
            _ = session.detachSSHConnection(for: transition)

            #expect(hookObservedAttachedConnection)
            #expect(stoppedSessionIDs == [session.id])
            #expect(session.getSSHConnection() == nil)
        }
    }

    @Test @MainActor func sessionManagerLifecycleHookStopsForwardsOnceForTerminalError() {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Lifecycle",
            host: "example.com",
            username: "user"
        ))
        var stoppedSessionIDs: [UUID] = []
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false,
            stopSessionForwards: { stoppedSessionIDs.append($0) }
        )
        manager.registerSession(session)

        session.reportError("transport failed")
        session.reportError("duplicate transport callback")

        #expect(stoppedSessionIDs == [session.id])
        #expect(session.state == .error("duplicate transport callback"))
        #expect(session.getSSHConnection() == nil)
    }

    @Test @MainActor func closeSessionUsesLifecycleHookAndPreservesUnregisterBehavior() {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Lifecycle",
            host: "example.com",
            username: "user"
        ))
        var stoppedSessionIDs: [UUID] = []
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false,
            stopSessionForwards: { stoppedSessionIDs.append($0) }
        )
        manager.registerSession(session)

        manager.closeSession(session)

        #expect(stoppedSessionIDs == [session.id])
        #expect(session.state == .disconnected)
        #expect(manager.session(for: session.id) == nil)
    }

    @Test @MainActor func closeSessionPurgesSOCKS5CredentialsAfterAwaitedForwardShutdown() async {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Lifecycle",
            host: "example.com",
            username: "user"
        ))
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false
        )
        manager.registerSession(session)
        let forward = PortForward(type: .dynamic, localPort: 10_82, remotePort: 0)
        #expect(manager.portForwardManager.addForward(
            forward,
            to: session.id,
            socks5Username: "proxy-user",
            socks5Password: "session-secret"
        ))
        #expect(manager.portForwardManager.hasSOCKS5Credentials(for: forward.id))

        manager.closeSession(session)
        await session.awaitLifecycleCleanup()
        for _ in 0..<10 where !manager.portForwardManager.forwards(for: session.id).isEmpty {
            await Task.yield()
        }

        #expect(manager.portForwardManager.forwards(for: session.id).isEmpty)
        #expect(!manager.portForwardManager.hasSOCKS5Credentials(for: forward.id))
    }

    @Test @MainActor func reconnectShutdownRetainsForwardRowsAndSOCKS5Credentials() async {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Lifecycle",
            host: "example.com",
            username: "user"
        ))
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false
        )
        manager.registerSession(session)
        let forward = PortForward(type: .dynamic, localPort: 10_83, remotePort: 0)
        #expect(manager.portForwardManager.addForward(
            forward,
            to: session.id,
            socks5Username: "proxy-user",
            socks5Password: "session-secret"
        ))

        _ = session.detachSSHConnection(for: .manualReconnect)
        await session.awaitLifecycleCleanup()

        #expect(manager.session(for: session.id) === session)
        #expect(manager.portForwardManager.forwards(for: session.id).map(\.id) == [forward.id])
        #expect(manager.portForwardManager.hasSOCKS5Credentials(for: forward.id))
    }

    @Test @MainActor func unregisterPurgeDoesNotRaceSessionReregistration() async {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Lifecycle",
            host: "example.com",
            username: "user"
        ))
        let manager = SessionManager(
            serverManager: ServerManager(loadImmediately: false),
            loadImmediately: false
        )
        manager.registerSession(session)
        let forward = PortForward(type: .dynamic, localPort: 10_84, remotePort: 0)
        #expect(manager.portForwardManager.addForward(
            forward,
            to: session.id,
            socks5Username: "proxy-user",
            socks5Password: "session-secret"
        ))

        manager.closeSession(session)
        manager.registerSession(session)
        await session.awaitLifecycleCleanup()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(manager.session(for: session.id) === session)
        #expect(manager.portForwardManager.forwards(for: session.id).map(\.id) == [forward.id])
        #expect(manager.portForwardManager.hasSOCKS5Credentials(for: forward.id))
    }

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

        session.feedTerminalData(Data("final remote bytes".utf8))

        session.handleCleanRemoteExit()

        #expect(session.state == .disconnected)
        #expect(session.connectionProgress == nil)
        #expect(session.closeWindowNonce == initialNonce &+ 1)
        #expect(session.drainTerminalInputChunks() == [Data("final remote bytes".utf8)])
    }

    @Test @MainActor func terminalSessionClearPreservesBufferedOutputBeforeClearSequence() {
        let session = TerminalSession(server: ServerConfiguration(
            name: "Test",
            host: "example.com",
            port: 22,
            username: "user"
        ))

        session.feedTerminalData(Data("tail".utf8))
        session.clearScreen()

        #expect(session.drainTerminalInputChunks() == [
            Data("tail".utf8),
            Data("\u{1B}[2J\u{1B}[H".utf8),
        ])
    }

    @Test @MainActor func terminalSessionSerializesMixedOutboundWrites() async {
        let probe = TerminalWriteProbe()
        let session = TerminalSession(
            server: ServerConfiguration(
                name: "Test",
                host: "example.com",
                port: 22,
                username: "user"
            ),
            terminalWriteSink: { data in
                try await probe.receive(data)
            }
        )
        session.state = .connected

        session.sendTerminalData(Data("first".utf8))
        session.sendCommand("second")
        session.sendTerminalData(Data("third".utf8))
        await session.waitUntilTerminalWritesComplete()

        #expect(probe.writes == [
            Data("first".utf8),
            Data("second\n".utf8),
            Data("third".utf8),
        ])
    }

    @Test @MainActor func terminalSessionRejectsInputOutsideConnectedState() async {
        let probe = TerminalWriteProbe()
        let session = TerminalSession(
            server: ServerConfiguration(
                name: "Test",
                host: "example.com",
                port: 22,
                username: "user"
            ),
            terminalWriteSink: { data in
                try await probe.receive(data)
            }
        )

        session.state = .reconnecting
        session.sendTerminalData(Data("not sent".utf8))
        session.sendCommand("also not sent")
        await session.waitUntilTerminalWritesComplete()

        #expect(probe.writes.isEmpty)
        #expect(session.output.last?.text == "Error: terminal is not connected.")
    }

    @Test @MainActor func terminalSessionSurfacesFailureWhenDiscardedQueueContainsCommand() async {
        let session = TerminalSession(
            server: ServerConfiguration(
                name: "Test",
                host: "example.com",
                port: 22,
                username: "user"
            ),
            terminalWriteSink: { _ in throw TerminalWriteFailure() }
        )
        session.state = .connected

        session.sendTerminalData(Data("raw".utf8))
        session.sendCommand("visible command")
        await session.waitUntilTerminalWritesComplete()

        #expect(session.output.contains { $0.text.hasPrefix("Error:") })
    }

    @Test @MainActor func terminalSessionCoalescesRapidRemotePTYResizes() async {
        let probe = TerminalResizeProbe()
        let session = TerminalSession(
            server: ServerConfiguration(
                name: "Test",
                host: "example.com",
                port: 22,
                username: "user"
            ),
            terminalResizeSink: { rows, columns in
                try await probe.receive(rows: rows, columns: columns)
            }
        )
        session.state = .connected

        session.updateTerminalGeometry(rows: 24, columns: 80)
        while probe.resizes.isEmpty {
            await Task.yield()
        }
        session.updateTerminalGeometry(rows: 30, columns: 100)
        session.updateTerminalGeometry(rows: 40, columns: 120)
        await session.waitUntilTerminalResizesComplete()

        #expect(probe.resizes == ["24x80", "40x120"])
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
