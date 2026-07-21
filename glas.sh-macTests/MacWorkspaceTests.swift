import AppKit
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import RealityKitContent
import SwiftUI
import Testing
@testable import glas_sh

@Suite(.serialized)
struct MacWorkspaceTests {
    private static let hostKeyValidationFixture =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfkNV4OS33ImTXvorZr72q4v5XhVEQKfvqsxOEJ/XaR"

    @Test func restorationStateRoundTripsEveryPaneIntentAndSplitProperty() throws {
        let workspaceID = UUID()
        let serverID = UUID()
        let localPane = MacWorkspacePane(id: UUID(), intent: .local)
        let sshPane = MacWorkspacePane(id: UUID(), intent: .ssh(serverID: serverID))
        let split = MacWorkspaceSplit(
            id: UUID(),
            axis: .vertical,
            fraction: 0.37,
            first: .pane(localPane),
            second: .pane(sshPane)
        )
        var state = MacWorkspaceRestorationState(id: workspaceID)
        state.root = .split(split)
        state.focusedPaneID = sshPane.id

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            MacWorkspaceRestorationState.self,
            from: encoded
        )

        #expect(try decoded.validated(for: workspaceID) == state)
        #expect(decoded.root?.paneIDs == [localPane.id, sshPane.id])
        #expect(decoded.root?.pane(id: sshPane.id)?.intent.serverID == serverID)
    }

    @Test func blankLaunchRequestRoundTripsAndDecodesLegacyRequests() throws {
        let workspaceID = UUID()
        let request = MacWorkspaceLaunchRequest(
            workspaceID: workspaceID,
            startsEmpty: true
        )

        let decoded = try JSONDecoder().decode(
            MacWorkspaceLaunchRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "workspaceID": workspaceID.uuidString
        ])
        let legacyRequest = try JSONDecoder().decode(
            MacWorkspaceLaunchRequest.self,
            from: legacyData
        )
        #expect(legacyRequest.workspaceID == workspaceID)
        #expect(!legacyRequest.startsEmpty)
    }

    @Test @MainActor func workgroupLaunchRequestCarriesOnlyDisplayMetadataAndOpaqueTicket() throws {
        let broker = MacStartupCommandBroker(capacity: 4)
        let secretCommand = "printf launch-secret-7f36"
        let ticketID = try #require(broker.issue(command: secretCommand))
        let workgroupID = UUID()
        let request = MacWorkspaceLaunchRequest(
            initialPaneIntent: .local,
            workgroupID: workgroupID,
            workgroupName: "Production",
            workgroupColor: .cyan,
            tabLabel: "Metrics",
            startupTicketID: ticketID
        )

        let encoded = try JSONEncoder().encode(request)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedText.contains(secretCommand))
        #expect(encodedText.contains(ticketID.uuidString))

        let decoded = try JSONDecoder().decode(MacWorkspaceLaunchRequest.self, from: encoded)
        #expect(decoded == request)
        #expect(decoded.workgroupID == workgroupID)
        #expect(decoded.workgroupName == "Production")
        #expect(decoded.workgroupColor == .cyan)
        #expect(decoded.tabLabel == "Metrics")
        #expect(decoded.initialPaneIntent == .local)
    }

    @Test @MainActor func startupCommandBrokerIsBoundedAndClaimsExactlyOnce() throws {
        let broker = MacStartupCommandBroker(capacity: 2)
        let first = try #require(broker.issue(command: "echo first"))
        let second = try #require(broker.issue(command: "echo second"))
        let third = try #require(broker.issue(command: "echo third"))

        #expect(broker.pendingCount == 2)
        #expect(broker.claim(first) == nil)
        #expect(broker.claim(second)?.command == "echo second")
        #expect(broker.claim(second) == nil)
        #expect(broker.claim(third)?.command == "echo third")
        #expect(broker.pendingCount == 0)
    }

    @Test @MainActor func restoredWorkspaceNeverReplaysStartupTicket() throws {
        let fixture = try WorkspaceDefaultsFixture()
        defer { fixture.cleanup() }
        let original = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        original.focus(try #require(original.focusedPaneID))

        let broker = MacStartupCommandBroker()
        let ticketID = try #require(broker.issue(command: "echo must-not-replay"))
        let restored = MacWorkspaceController(
            request: MacWorkspaceLaunchRequest(
                workspaceID: fixture.workspaceID,
                initialPaneIntent: .local,
                startupTicketID: ticketID
            ),
            startupCommandBroker: broker,
            defaults: fixture.defaults
        )

        #expect(restored.claimStartupCommand(for: try #require(restored.focusedPaneID)) == nil)
        #expect(broker.pendingCount == 0)
    }

    @Test @MainActor func workgroupLauncherCreatesAClaimableSingleUseRequest() throws {
        let broker = MacStartupCommandBroker()
        var opened: [MacWorkspaceLaunchRequest] = []
        let requests = MacWorkgroupLauncher.launch(
            workgroupID: UUID(),
            name: "Operations",
            color: .orange,
            items: [MacWorkgroupLaunchItem(
                intent: .local,
                label: "Local",
                startupCommand: "uptime"
            )],
            broker: broker,
            openWindow: { opened.append($0) }
        )

        #expect(requests == opened)
        let request = try #require(requests.first)
        #expect(request.workgroupName == "Operations")
        #expect(request.tabLabel == "Local")
        #expect(request.workgroupColor == .orange)
        #expect(broker.claim(try #require(request.startupTicketID))?.command == "uptime")
        #expect(broker.pendingCount == 0)
    }

    @Test func hostKeyValidatorRunsOnNIOEventLoopWithoutActorIsolationTrap() async throws {
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: Self.hostKeyValidationFixture)
        var wireBuffer = ByteBufferAllocator().buffer(capacity: 128)
        _ = hostKey.write(to: &wireBuffer)
        let trustedKeyBase64 = Data(wireBuffer.readableBytesView).base64EncodedString()
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

        let trustedBox = HostKeyChallengeBox()
        let trustedValidator = PromptingHostKeyValidator(
            host: "trusted.example.com",
            port: 22,
            trustedKeyBase64Set: [trustedKeyBase64],
            verificationMode: .ask,
            challengeBox: trustedBox
        )
        let trustedPromise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            trustedValidator.validateHostKey(
                hostKey: hostKey,
                validationCompletePromise: trustedPromise
            )
        }
        try await trustedPromise.futureResult.get()
        #expect(trustedBox.take() == nil)

        let unknownBox = HostKeyChallengeBox()
        let unknownValidator = PromptingHostKeyValidator(
            host: "unknown.example.com",
            port: 2222,
            trustedKeyBase64Set: [],
            verificationMode: .ask,
            challengeBox: unknownBox
        )
        let unknownPromise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            unknownValidator.validateHostKey(
                hostKey: hostKey,
                validationCompletePromise: unknownPromise
            )
        }
        do {
            try await unknownPromise.futureResult.get()
            Issue.record("An unknown host key must require an explicit trust decision")
        } catch let error as HostKeyTrustRequiredError {
            #expect(error.challenge.host == "unknown.example.com")
            #expect(error.challenge.port == 2222)
            #expect(error.challenge.algorithm == "ssh-ed25519")
            #expect(error.challenge.reason == .unknown)
        }
        #expect(unknownBox.take()?.reason == .unknown)

        let changedBox = HostKeyChallengeBox()
        let changedValidator = PromptingHostKeyValidator(
            host: "changed.example.com",
            port: 22,
            trustedKeyBase64Set: ["different-key"],
            verificationMode: .strict,
            challengeBox: changedBox
        )
        let changedPromise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            changedValidator.validateHostKey(
                hostKey: hostKey,
                validationCompletePromise: changedPromise
            )
        }
        do {
            try await changedPromise.futureResult.get()
            Issue.record("A changed host key must fail strict verification")
        } catch let error as HostKeyTrustRequiredError {
            #expect(error.challenge.reason == .changed)
            #expect(error.challenge.keyDataBase64 == trustedKeyBase64)
        }
        #expect(changedBox.take()?.reason == .changed)
    }

    @Test @MainActor func workspaceWindowRegistryRemovesOrphanedPendingTabs() {
        let registry = MacWorkspaceWindowRegistry()
        let sourceID = UUID()
        let destinationID = UUID()
        let sourceWindow = NSWindow()

        registry.register(sourceWindow, workspaceID: sourceID)
        registry.prepareTab(
            sourceWorkspaceID: sourceID,
            destinationWorkspaceID: destinationID
        )
        #expect(registry.pendingTabCount == 1)

        registry.unregister(sourceID)
        #expect(registry.pendingTabCount == 0)
    }

    @Test @MainActor func workspaceWindowRegistryAssemblesBatchInSavedOrder() {
        let registry = MacWorkspaceWindowRegistry()
        let workspaceIDs = [UUID(), UUID(), UUID()]
        let windows = ["One", "Two", "Three"].map { title in
            let window = NSWindow()
            window.title = title
            window.isReleasedWhenClosed = false
            return window
        }
        defer { windows.forEach { $0.close() } }

        registry.prepareTabBatch(workspaceIDs: workspaceIDs)
        #expect(registry.pendingBatchCount == 1)
        registry.register(windows[2], workspaceID: workspaceIDs[2])
        registry.register(windows[0], workspaceID: workspaceIDs[0])
        registry.register(windows[1], workspaceID: workspaceIDs[1])

        #expect(registry.pendingBatchCount == 0)
        #expect(windows[0].tabbedWindows?.map(\.title) == ["One", "Two", "Three"])
    }

    @Test @MainActor func appleTerminalThemeImporterUsesOnlyAllowlistedVisualFields() throws {
        let fallbackBackground = CodableColor(
            sRGBRed: 0.12,
            green: 0.23,
            blue: 0.34,
            alpha: 0.45
        )
        var fallback = TerminalTheme.default
        fallback.background = fallbackBackground
        let textColor = NSColor(
            calibratedRed: 0.95,
            green: 0.20,
            blue: 0.10,
            alpha: 1
        )
        let redColor = NSColor(
            calibratedRed: 0.80,
            green: 0.05,
            blue: 0.03,
            alpha: 1
        )
        let lightProfileBackground = NSColor(
            calibratedRed: 0.95,
            green: 0.94,
            blue: 0.92,
            alpha: 1
        )
        let profile: [String: Any] = [
            "name": "Imported Apple Profile",
            "TextColor": try NSKeyedArchiver.archivedData(
                withRootObject: textColor,
                requiringSecureCoding: true
            ),
            "ANSIRedColor": try NSKeyedArchiver.archivedData(
                withRootObject: redColor,
                requiringSecureCoding: true
            ),
            "Font": try NSKeyedArchiver.archivedData(
                withRootObject: NSFont(name: "Menlo", size: 17)!,
                requiringSecureCoding: true
            ),
            "BackgroundColor": try NSKeyedArchiver.archivedData(
                withRootObject: lightProfileBackground,
                requiringSecureCoding: true
            ),
            "BackgroundBlur": 0.9,
            "CommandString": "must never be imported",
            "WorkingDirectory": "/private/tmp",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .binary,
            options: 0
        )

        let imported = try TerminalThemeImportService.importTheme(
            from: data,
            fallback: fallback
        )

        #expect(imported.id == fallback.id)
        #expect(imported.name == "Imported Apple Profile")
        #expect(imported.background == fallbackBackground)
        #expect(imported.foreground.red > 0.9)
        #expect(imported.red.red > 0.75)
        #expect(imported.fontName == "Menlo-Regular")
        #expect(imported.fontSize == 17)
        #expect(imported.green == fallback.green)
        #expect(imported.preferredAppearance == .light)
    }

    @Test @MainActor func appleTerminalThemeImporterRejectsInvalidAndOversizedInput() throws {
        let invalidProfile: [String: Any] = [
            "name": "Invalid",
            "TextColor": "not an archived NSColor",
        ]
        let invalidData = try PropertyListSerialization.data(
            fromPropertyList: invalidProfile,
            format: .binary,
            options: 0
        )

        #expect(throws: TerminalThemeImportError.self) {
            try TerminalThemeImportService.importTheme(
                from: invalidData,
                fallback: .default
            )
        }
        #expect(throws: TerminalThemeImportError.self) {
            try TerminalThemeImportService.importTheme(
                from: Data(count: TerminalThemeImportService.maximumImportBytes + 1),
                fallback: .default
            )
        }
    }

    @Test @MainActor func shippedAppleClearDarkProfileImportsWithMonospacedFallback() throws {
        let url = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/Clear Dark.terminal"
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        var fallback = TerminalTheme.default
        fallback.fontName = "SF Mono"
        fallback.fontSize = 14
        let fallbackBackground = fallback.background

        let imported = try TerminalThemeImportService.importTheme(
            from: url,
            fallback: fallback
        )

        #expect(imported.name == "Clear Dark")
        #expect(imported.fontName == "SF Mono")
        #expect(imported.fontSize == 12)
        #expect(imported.background == fallbackBackground)
        #expect(imported.ansiColors.count == 16)
        #expect(imported.preferredAppearance == .dark)
    }

    @Test @MainActor func homebrewProfileInheritsAppleDefaultANSIPalette() throws {
        let url = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/Homebrew.terminal"
        )
        var fallback = TerminalTheme.default
        fallback.red = CodableColor(sRGBRed: 1, green: 0, blue: 1)

        let imported = try TerminalThemeImportService.importTheme(
            from: url,
            fallback: fallback
        )

        #expect(imported.name == "Homebrew")
        #expect(imported.foreground != TerminalTheme.appleClearDarkForeground)
        #expect(imported.ansiColors == TerminalTheme.appleClearDarkANSIColors)
        #expect(imported.preferredAppearance == .dark)
    }

    @Test @MainActor func blankFallbackNeverOverridesRestoredWorkspace() throws {
        let fixture = try WorkspaceDefaultsFixture()
        defer { fixture.cleanup() }

        let blankController = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            startsEmptyIfUnrestored: true,
            defaults: fixture.defaults
        )
        #expect(blankController.isEmpty)

        blankController.addPane(intent: .local, axis: .vertical)
        let persistedPaneID = try #require(blankController.focusedPaneID)

        let restoredController = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            startsEmptyIfUnrestored: true,
            defaults: fixture.defaults
        )
        #expect(!restoredController.isEmpty)
        #expect(restoredController.focusedPaneID == persistedPaneID)
        #expect(restoredController.focusedPane?.intent == .local)
    }

    @Test func validationRejectsUnsupportedSchemasAndInvalidPaneIntentShapes() throws {
        let validState = MacWorkspaceRestorationState()
        let futureState = try replacingTopLevelValue(
            in: validState,
            key: "schemaVersion",
            value: MacWorkspaceRestorationState.currentSchemaVersion + 1
        )

        #expect(
            throws: MacWorkspaceStateError.unsupportedWorkspaceVersion(
                MacWorkspaceRestorationState.currentSchemaVersion + 1
            )
        ) {
            try futureState.validated()
        }

        let futureIntent = Data(
            #"{"schemaVersion":2,"kind":"local"}"#.utf8
        )
        #expect(throws: MacWorkspaceStateError.unsupportedPaneIntentVersion(2)) {
            try JSONDecoder().decode(MacWorkspacePaneIntent.self, from: futureIntent)
        }

        let serverID = UUID()
        let localWithServer = Data(
            #"{"schemaVersion":1,"kind":"local","serverID":"\#(serverID.uuidString)"}"#.utf8
        )
        #expect(throws: MacWorkspaceStateError.invalidPaneIntent) {
            try JSONDecoder().decode(MacWorkspacePaneIntent.self, from: localWithServer)
        }

        let sshWithoutServer = Data(
            #"{"schemaVersion":1,"kind":"ssh"}"#.utf8
        )
        #expect(throws: MacWorkspaceStateError.invalidPaneIntent) {
            try JSONDecoder().decode(MacWorkspacePaneIntent.self, from: sshWithoutServer)
        }
    }

    @Test func validationBindsWorkspaceIdentityAndFocusToExistingPanes() throws {
        let state = MacWorkspaceRestorationState()
        #expect(throws: MacWorkspaceStateError.workspaceIdentityMismatch) {
            try state.validated(for: UUID())
        }

        var missingFocus = state
        missingFocus.focusedPaneID = UUID()
        #expect(throws: MacWorkspaceStateError.invalidFocus) {
            try missingFocus.validated()
        }

        var emptyWithFocus = state
        emptyWithFocus.root = nil
        #expect(throws: MacWorkspaceStateError.invalidFocus) {
            try emptyWithFocus.validated()
        }

        emptyWithFocus.focusedPaneID = nil
        #expect(try emptyWithFocus.validated() == emptyWithFocus)
    }

    @Test func validationRejectsDuplicateNodeIdentity() {
        let duplicateID = UUID()
        let pane = MacWorkspacePane(id: duplicateID, intent: .local)
        var state = MacWorkspaceRestorationState()
        state.root = .split(MacWorkspaceSplit(
            axis: .horizontal,
            first: .pane(pane),
            second: .pane(pane)
        ))
        state.focusedPaneID = duplicateID

        #expect(throws: MacWorkspaceStateError.duplicateNodeIdentity) {
            try state.validated()
        }
    }

    @Test func validationRejectsInvalidFractionsDepthAndPaneCount() {
        for boundaryFraction in [0.1, 0.9] {
            var state = MacWorkspaceRestorationState()
            state.root = .split(MacWorkspaceSplit(
                axis: .vertical,
                fraction: boundaryFraction,
                first: .pane(MacWorkspacePane(intent: .local)),
                second: .pane(MacWorkspacePane(intent: .local))
            ))
            state.focusedPaneID = state.root?.paneIDs.first
            let validated = try? state.validated()
            #expect(validated == state)
        }

        for invalidFraction in [-1.0, 0.09, 0.91, 2.0, .infinity, .nan] {
            var state = MacWorkspaceRestorationState()
            state.root = .split(MacWorkspaceSplit(
                axis: .horizontal,
                fraction: invalidFraction,
                first: .pane(MacWorkspacePane(intent: .local)),
                second: .pane(MacWorkspacePane(intent: .local))
            ))
            state.focusedPaneID = state.root?.paneIDs.first

            #expect(throws: MacWorkspaceStateError.invalidSplitFraction) {
                try state.validated()
            }
        }

        var tooDeep = MacWorkspaceRestorationState()
        tooDeep.root = nestedNode(depth: MacWorkspaceRestorationState.maximumDepth + 1)
        tooDeep.focusedPaneID = tooDeep.root?.paneIDs.first
        #expect(throws: MacWorkspaceStateError.tooDeep) {
            try tooDeep.validated()
        }

        var tooMany = MacWorkspaceRestorationState()
        tooMany.root = balancedNode(
            paneCount: MacWorkspaceRestorationState.maximumPaneCount + 1
        )
        tooMany.focusedPaneID = tooMany.root?.paneIDs.first
        #expect(throws: MacWorkspaceStateError.tooManyPanes) {
            try tooMany.validated()
        }
    }

    @Test @MainActor func controllerSplitsFocusesClampsAndCollapsesPanes() throws {
        let fixture = try WorkspaceDefaultsFixture()
        defer { fixture.cleanup() }
        let controller = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        let sessionManager = SessionManager(loadImmediately: false)
        let initialPaneID = try #require(controller.focusedPaneID)

        controller.addPane(intent: .local, axis: .horizontal)
        let secondPaneID = try #require(controller.focusedPaneID)
        #expect(secondPaneID != initialPaneID)
        #expect(controller.state.root?.paneIDs == [initialPaneID, secondPaneID])

        let rootSplitID: UUID
        if case .split(let split) = controller.state.root {
            rootSplitID = split.id
            #expect(split.axis == .horizontal)
        } else {
            Issue.record("Adding a pane did not create a split root")
            return
        }

        controller.updateSplitFraction(rootSplitID, fraction: 4)
        if case .split(let split) = controller.state.root {
            #expect(split.fraction == 0.9)
        }

        controller.focus(initialPaneID)
        controller.addPane(intent: .ssh(serverID: UUID()), axis: .vertical)
        let thirdPaneID = try #require(controller.focusedPaneID)
        #expect(controller.state.root?.paneIDs == [initialPaneID, thirdPaneID, secondPaneID])
        #expect(controller.focusedPane?.intent.kind == .ssh)

        controller.focus(UUID())
        #expect(controller.focusedPaneID == thirdPaneID)
        controller.focusNextPane()
        #expect(controller.focusedPaneID == secondPaneID)
        controller.focusNextPane()
        #expect(controller.focusedPaneID == initialPaneID)

        controller.removePane(initialPaneID, sessionManager: sessionManager)
        #expect(controller.state.root?.paneIDs == [thirdPaneID, secondPaneID])
        #expect(controller.focusedPaneID == thirdPaneID)
        controller.removePane(thirdPaneID, sessionManager: sessionManager)
        controller.removePane(secondPaneID, sessionManager: sessionManager)
        #expect(controller.isEmpty)
        #expect(controller.focusedPaneID == nil)

        controller.addPane(intent: .local, axis: .vertical)
        #expect(controller.state.root?.paneIDs.count == 1)
        #expect(controller.focusedPane?.intent == .local)
    }

    @Test @MainActor func controllerPersistsOnlyBoundedNonsecretRestorationData() throws {
        let fixture = try WorkspaceDefaultsFixture()
        defer { fixture.cleanup() }
        let serverID = UUID()
        let controller = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        controller.addPane(intent: .ssh(serverID: serverID), axis: .vertical)

        let persisted = try #require(fixture.defaults.data(forKey: fixture.storageKey))
        let text = try #require(String(data: persisted, encoding: .utf8))
        #expect(persisted.count <= 128 * 1024)
        #expect(text.localizedCaseInsensitiveContains(serverID.uuidString))

        let forbiddenKeys = [
            "password", "privatekey", "passphrase", "credential", "oauth",
            "token", "environmentvariables", "preparedauthentication", "pty"
        ]
        for key in forbiddenKeys {
            #expect(!text.localizedCaseInsensitiveContains(key))
        }
        let sentinelSecrets = [
            "workspace-test-password-7d98b7",
            "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
            "workspace-test-oauth-secret-57bda1"
        ]
        for secret in sentinelSecrets {
            #expect(!text.contains(secret))
        }

        let restored = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        #expect(restored.state == controller.state)
        #expect(restored.sessionsByPaneID.isEmpty)
        #expect(restored.loadingPaneIDs.isEmpty)

        let oversized = Data(repeating: 0x41, count: 128 * 1024 + 1)
        fixture.defaults.set(oversized, forKey: fixture.storageKey)
        let boundedFallback = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        #expect(boundedFallback.workspaceID == fixture.workspaceID)
        #expect(boundedFallback.state.root?.paneIDs.count == 1)
        #expect(fixture.defaults.data(forKey: fixture.storageKey) == oversized)
    }

    @Test @MainActor func closedWorkspaceRejectsLateOrNewSSHPreparation() async throws {
        let fixture = try WorkspaceDefaultsFixture()
        defer { fixture.cleanup() }
        let controller = MacWorkspaceController(
            workspaceID: fixture.workspaceID,
            defaults: fixture.defaults
        )
        let sessionManager = SessionManager(loadImmediately: false)
        let settingsManager = SettingsManager(loadImmediately: false)
        let serverID = UUID()
        controller.addPane(intent: .ssh(serverID: serverID), axis: .horizontal)
        let pane = try #require(controller.focusedPane)

        controller.closeAllSessions(sessionManager: sessionManager)
        #expect(controller.isClosed)
        await controller.prepareSSHPaneIfNeeded(
            pane,
            sessionManager: sessionManager,
            settingsManager: settingsManager
        )

        #expect(controller.sessionsByPaneID.isEmpty)
        #expect(controller.loadingPaneIDs.isEmpty)
        #expect(controller.error(for: pane.id) == nil)
    }

    @Test @MainActor func transparencyAndBlurRemainIndependentAtEveryEndpoint() throws {
        let cases: [(
            opacity: Double,
            blur: Double,
            paintsTheme: Bool,
            compositesBlur: Bool,
            fullyTransparent: Bool
        )] = [
            (0, 0, false, false, true),
            (0, 1, false, true, false),
            (1, 0, true, false, false),
            (1, 1, true, true, false)
        ]

        for value in cases {
            let appearance = TerminalGlassAppearance(
                opacity: value.opacity,
                blur: value.blur
            )
            #expect(appearance.opacity == value.opacity)
            #expect(appearance.blur == value.blur)
            #expect(appearance.paintsTheme == value.paintsTheme)
            #expect(appearance.compositesBlur == value.compositesBlur)
            #expect(appearance.isFullyTransparent == value.fullyTransparent)
        }

        #expect(
            TerminalGlassAppearance(opacity: -1, blur: 2)
                == TerminalGlassAppearance(opacity: 0, blur: 1)
        )
        #expect(
            TerminalGlassAppearance(opacity: .nan, blur: .infinity)
                == TerminalGlassAppearance(opacity: 0, blur: 0)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.alphaValue = 0.73
        window.styleMask.remove(.fullSizeContentView)
        MacTerminalWindowPolicy.apply(window, tabbingIdentifier: "sh.glas.test")
        MacTerminalWindowPolicy.apply(window, tabbingIdentifier: "sh.glas.test")

        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.alphaValue == 0.73)
        #expect(window.tabbingIdentifier == "sh.glas.test")
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(!window.titlebarAppearsTransparent)

        let contentView = try #require(window.contentView)
        let themeFrame = try #require(contentView.superview)
        let materialViews = themeFrame.subviews.compactMap {
            $0 as? MacTerminalTitlebarMaterialView
        }
        let materialView = try #require(materialViews.first)
        #expect(materialViews.count == 1)
        #expect(materialView.identifier == MacTerminalTitlebarMaterialView.materialIdentifier)
        #expect(materialView.contentBoundary === contentView)
        #expect(materialView.state == .followsWindowActiveState)
        #expect(materialView.hitTest(.zero) == nil)
    }

    @Test func terminalCanvasAppearancePreservesIncreaseContrast() {
        #expect(
            MacTerminalVisualEffect(amount: 0.5).state
                == .followsWindowActiveState
        )
        #expect(MacTerminalVisualEffect.clampedAmount(-1) == 0)
        #expect(MacTerminalVisualEffect.clampedAmount(0.35) == 0.35)
        #expect(MacTerminalVisualEffect.clampedAmount(2) == 1)
        #expect(MacTerminalVisualEffect.clampedAmount(.nan) == 0)
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .automatic,
                increaseContrast: false
            ) == nil
        )
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .automatic,
                increaseContrast: true
            ) == nil
        )
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .light,
                increaseContrast: false
            ) == .aqua
        )
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .light,
                increaseContrast: true
            ) == .accessibilityHighContrastAqua
        )
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .dark,
                increaseContrast: false
            ) == .darkAqua
        )
        #expect(
            MacTerminalVisualEffect.resolvedAppearanceName(
                for: .dark,
                increaseContrast: true
            ) == .accessibilityHighContrastDarkAqua
        )
    }

    @Test func localTerminalExitPolicyClosesOnlyAfterCleanShellExit() {
        #expect(MacLocalTerminalExitPolicy.shouldClose(exitCode: 0))
        #expect(!MacLocalTerminalExitPolicy.shouldClose(exitCode: 1))
        #expect(!MacLocalTerminalExitPolicy.shouldClose(exitCode: 143))
        #expect(!MacLocalTerminalExitPolicy.shouldClose(exitCode: nil))
    }

    @Test @MainActor func localPTYTeardownKillsAndReapsSignalIgnoringShell() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "glas-local-pty-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let configuration = SwiftTermLocalProcessConfiguration(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; printf '%d' $$ > \"$1\"; while :; do sleep 1; done",
                "glas-local-pty-test",
                pidFile.path
            ],
            executableName: "sh",
            currentDirectory: FileManager.default.temporaryDirectory.path
        )
        let model = SwiftTermHostModel()
        let processState = SwiftTermLocalProcessState()
        let terminal = SwiftTermLocalProcessHostView(
            model: model,
            processState: processState,
            configuration: configuration,
            theme: SwiftTermTheme(
                fontSize: 13,
                foreground: (1, 1, 1),
                background: (0, 0, 0, 0),
                cursor: (1, 1, 1)
            ),
            runtimeSettings: SwiftTermRuntimeSettings(
                cursorStyle: "block",
                blinkingCursor: false,
                scrollbackLines: 100
            )
        )
        var hostingView: NSHostingView<SwiftTermLocalProcessHostView>? = NSHostingView(
            rootView: terminal
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        let pidWasWritten = await waitForCondition(seconds: 2) {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        #expect(pidWasWritten)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let processID = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            if kill(processID, 0) == 0 {
                _ = kill(processID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processID, &status, 0)
            }
        }
        #expect(processState.isRunning)

        window.contentView = nil
        hostingView = nil
        window.close()

        let processWasReaped = await waitForCondition(seconds: 4) {
            errno = 0
            let signalResult = kill(processID, 0)
            return signalResult == -1 && errno == ESRCH
        }
        #expect(processWasReaped)
        var status: Int32 = 0
        errno = 0
        #expect(waitpid(processID, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        let processIsRunning = processState.isRunning
        #expect(!processIsRunning)
    }

    @Test @MainActor func exitedLocalPTYRestartsInTheExistingTerminal() async throws {
        let configuration = SwiftTermLocalProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.1; exit 7"],
            executableName: "sh",
            currentDirectory: FileManager.default.temporaryDirectory.path
        )
        let model = SwiftTermHostModel()
        let processState = SwiftTermLocalProcessState()
        var terminationCount = 0
        var readyCount = 0
        let terminal = SwiftTermLocalProcessHostView(
            model: model,
            processState: processState,
            configuration: configuration,
            theme: SwiftTermTheme(
                fontSize: 13,
                foreground: (1, 1, 1),
                background: (0, 0, 0, 0),
                cursor: (1, 1, 1)
            ),
            runtimeSettings: SwiftTermRuntimeSettings(
                cursorStyle: "block",
                blinkingCursor: false,
                scrollbackLines: 100
            ),
            onProcessReady: { readyCount += 1 },
            onProcessTerminated: { _ in terminationCount += 1 }
        )
        var hostingView: NSHostingView<SwiftTermLocalProcessHostView>? = NSHostingView(
            rootView: terminal
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        #expect(await waitForCondition(seconds: 3) {
            terminationCount == 1 && processState.exitCode == 7
        })
        #expect(readyCount == 1)
        #expect(processState.restart(configuration))
        #expect(await waitForCondition(seconds: 3) {
            terminationCount == 2 && processState.exitCode == 7
        })
        #expect(readyCount == 2)

        window.contentView = nil
        hostingView = nil
        window.close()
        #expect(!processState.isRunning)
    }

    @Test @MainActor func remoteOSC52IsDeniedAndRecordedOnMac() async {
        let model = SwiftTermHostModel()
        let terminal = SwiftTermHostView(
            model: model,
            theme: SwiftTermTheme(
                fontSize: 13,
                foreground: (1, 1, 1),
                background: (0, 0, 0, 0),
                cursor: (1, 1, 1)
            ),
            runtimeSettings: SwiftTermRuntimeSettings(
                cursorStyle: "block",
                blinkingCursor: false,
                scrollbackLines: 100
            ),
            onSendData: { _ in },
            onResize: { _, _ in }
        )
        var hostingView: NSHostingView<SwiftTermHostView>? = NSHostingView(rootView: terminal)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        model.ingest(data: Data("\u{1B}]52;c;SGVs".utf8), nonce: 1)
        model.ingest(data: Data("bG8=\u{07}".utf8), nonce: 2)

        #expect(await waitForCondition(seconds: 2) {
            model.semanticEvents.contains { event in
                guard case .osc52Denied(let decision) = event.kind else { return false }
                return decision.disposition == .deniedWrite
                    && decision.encodedPayloadByteCount == 8
            }
        })

        window.contentView = nil
        hostingView = nil
        window.close()
    }
}

private struct WorkspaceDefaultsFixture {
    let suiteName: String
    let workspaceID = UUID()
    let defaults: UserDefaults

    init() throws {
        suiteName = "sh.glas.mac-workspace-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    var storageKey: String {
        "\(UserDefaultsKeys.macWorkspaceRestoration).\(workspaceID.uuidString.lowercased())"
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func replacingTopLevelValue(
    in state: MacWorkspaceRestorationState,
    key: String,
    value: Any
) throws -> MacWorkspaceRestorationState {
    let encoded = try JSONEncoder().encode(state)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object[key] = value
    return try JSONDecoder().decode(
        MacWorkspaceRestorationState.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func nestedNode(depth: Int) -> MacWorkspaceNode {
    guard depth > 1 else {
        return .pane(MacWorkspacePane(intent: .local))
    }
    return .split(MacWorkspaceSplit(
        axis: depth.isMultiple(of: 2) ? .horizontal : .vertical,
        first: .pane(MacWorkspacePane(intent: .local)),
        second: nestedNode(depth: depth - 1)
    ))
}

private func balancedNode(paneCount: Int) -> MacWorkspaceNode {
    guard paneCount > 1 else {
        return .pane(MacWorkspacePane(intent: .local))
    }
    let firstCount = paneCount / 2
    return .split(MacWorkspaceSplit(
        axis: paneCount.isMultiple(of: 2) ? .horizontal : .vertical,
        first: balancedNode(paneCount: firstCount),
        second: balancedNode(paneCount: paneCount - firstCount)
    ))
}

@MainActor
private func waitForCondition(
    seconds: Double,
    condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
