import XCTest

final class ConnectionLibraryUITests: XCTestCase {
    private static let credentialCleanupEnvironmentKey = "GLAS_UI_TEST_CREDENTIAL_CLEANUP"
    private static let credentialCleanupIdentifier = "ui-test-credential-cleanup-complete"
    private var app: XCUIApplication!
    private var testServerName = ""
    private var testServerTag = ""

    @MainActor
    private func prepareApp() {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        testServerName = "Connection Library UI Test \(suffix)"
        testServerTag = "UI Test \(suffix)"
        app = XCUIApplication()
        app.launchEnvironment[Self.credentialCleanupEnvironmentKey] = "1"
        #if os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()

        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            self.dismissSavePasswordPromptIfPresent()
            self.terminateAndWait(self.app)
            self.app = nil
            self.launchCredentialCleanupApp()
        }

        XCTAssertTrue(
            credentialCleanupMarker.waitForExistence(timeout: 15),
            "The app must remove stale UI-test profiles and shared credentials before testing."
        )
        #if os(macOS)
        focusConnectionLibraryWindow()
        #endif
        XCTAssertTrue(
            library.waitForExistence(timeout: 15),
            "The connection library should be the app's initial surface."
        )
    }

    @MainActor
    func testLibraryModesSettingsAndUnconfiguredNetwork() {
        prepareApp()
        #if !os(visionOS)
        let allConnectionsScope = buttonOrElement(
            identifier: "connection-library-scope-all-connections"
        )
        XCTAssertTrue(allConnectionsScope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            allConnectionsScope.label.hasPrefix("All Connections,"),
            "The Library section should name its aggregate route All Connections."
        )
        #endif
        openAllConnections()
        XCTAssertTrue(resultsConnections.waitForExistence(timeout: 5))
        XCTAssertTrue(
            addServerAction.waitForExistence(timeout: 5),
            "Every Connections result surface should expose its shared Add Server action."
        )

        navigate(to: "Favorites", scopeIdentifier: "connection-library-scope-favorites")
        navigate(to: "Recent", scopeIdentifier: "connection-library-scope-recent")
        navigate(to: "Workgroups", scopeIdentifier: "connection-library-scope-workgroups")
        XCTAssertTrue(
            resultsWorkgroups.waitForExistence(timeout: 5),
            "Selecting Workgroups should display the shared workgroup projection."
        )

        #if !os(macOS)
        XCTAssertFalse(
            element(identifier: "connection-library-mode-network").exists
                || element(identifier: "connection-library-scope-network").exists,
            "Network should be absent on the clean test installation when credentials are not configured."
        )
        #endif

        openAllConnections()
        verifySettingsRoundTrip()
    }

    #if os(macOS)
    @MainActor
    func testMacAddServerCancellationAndLocalTerminalRoute() {
        prepareApp()
        openAllConnections()
        verifyConnectionLibraryToolbar()
        verifyAddServerPresentationAndDismissal()
        verifyLocalTerminalRouteKeepsLibraryOpen()
    }

    @MainActor
    func testMacConnectionRowUsesItsFullWidthForSelectionAndDoubleClick() {
        prepareApp()
        openAllConnections()
        createTestServer()

        XCTAssertTrue(
            app.staticTexts["Select a connection to get started."].waitForExistence(timeout: 5),
            "A populated Library with no selection should show only the selection prompt."
        )
        XCTAssertFalse(
            app.buttons["connection-library-add-server-empty-detail"].exists,
            "A populated Library should not duplicate creation actions in the detail pane."
        )
        XCTAssertFalse(
            app.buttons["connection-library-local-terminal-empty-detail"].exists,
            "A populated Library should not duplicate Local Terminal in the detail pane."
        )
        XCTAssertFalse(
            app.buttons["Actions for \(testServerName)"].exists,
            "Connection rows should not reserve horizontal space for a visible actions menu."
        )

        activate(testServerNameLabel)
        assertTestServerDetailIsVisible(
            "Clicking the connection label should select the row and reveal its details."
        )

        openAllConnections()
        XCTAssertFalse(selectedServerConnectAction.exists)

        let row = testServerContainer
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            row.frame.width,
            testServerNameLabel.frame.width + 20,
            "The connection row hit surface should span beyond its label content."
        )
        row.coordinate(
            withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)
        ).click()
        assertTestServerDetailIsVisible(
            "Clicking the trailing row surface should select the connection."
        )

        let existingWorkspaceIDs = Set(terminalWorkspaceWindows.map(\.identifier))
        row.doubleClick()
        let workspaceOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.terminalWorkspaceWindows.contains {
                    !existingWorkspaceIDs.contains($0.identifier)
                        && $0.staticTexts[self.testServerName].exists
                }
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [workspaceOpened], timeout: 10),
            .completed,
            "Double-clicking any row content should open that saved connection."
        )
        if let terminalWindow = terminalWorkspaceWindows.first(where: {
            !existingWorkspaceIDs.contains($0.identifier)
                && $0.staticTexts[testServerName].exists
        }) {
            closeTerminalWorkspace(terminalWindow)
        }
    }

    @MainActor
    func testMacNativeTerminalChromeAndSidebarSmoke() {
        prepareApp()
        openAllConnections()

        let connectionsWindow = firstExistingConnectionLibraryWindow()
        let terminalWindow = openLocalTerminalWorkspace()
        terminalWindow.click()

        XCTAssertTrue(
            terminalWindow.staticTexts["Local"].waitForExistence(timeout: 3),
            "The native title bar should expose the focused terminal identity."
        )
        XCTAssertFalse(
            terminalWindow.staticTexts["Terminal"].exists,
            "A local workspace should not retain the generic Terminal title."
        )

        let newTabAction = terminalWindow.buttons["mac-workspace-new-tab"].firstMatch
        XCTAssertTrue(
            newTabAction.waitForExistence(timeout: 3),
            "The workspace should expose one native New Terminal Tab action."
        )
        XCTAssertEqual(
            terminalWindow.buttons.matching(identifier: "mac-workspace-new-tab").count,
            1,
            "The native title bar must not expose duplicate New Terminal Tab actions."
        )
        XCTAssertEqual(
            terminalWindow.buttons.matching(
                NSPredicate(format: "label == %@", "New Terminal Tab")
            ).count,
            1,
            "The active terminal tool cluster must defer tab creation to its workspace shell."
        )

        let connectionsAction = terminalWindow.buttons["Connections"].firstMatch
        XCTAssertTrue(connectionsAction.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            connectionsAction.frame.midY,
            terminalWindow.frame.midY,
            "Terminal actions must live in the native title-bar toolbar, not a footer."
        )

        let sidebarToggles = terminalWindow.buttons.matching(
            NSPredicate(format: "label IN %@", ["Show Sidebar", "Hide Sidebar"])
        )
        let sidebarToggle = sidebarToggles.firstMatch
        XCTAssertTrue(
            sidebarToggle.waitForExistence(timeout: 5),
            "The terminal should expose Apple's native sidebar action."
        )
        XCTAssertEqual(
            sidebarToggles.count,
            1,
            "The adaptive tab content must publish exactly one native sidebar disclosure."
        )
        XCTAssertFalse(
            terminalWindow
                .descendants(matching: .any)["mac-workspace-identity"]
                .exists,
            "The native window title should be the only title-bar identity."
        )
        let nativeWindowTitle = terminalWindow.staticTexts
            .matching(identifier: "Local")
            .allElementsBoundByIndex
            .first {
                $0.frame.midY < terminalWindow.frame.minY + 60
                    && $0.frame.minX >= newTabAction.frame.maxX - 1
            }
        XCTAssertNotNil(
            nativeWindowTitle,
            "The native server identity should follow the leading New Tab action."
        )
        XCTAssertFalse(
            terminalWindow.menuButtons["Tab Actions"].exists,
            "A single-tab terminal should not reserve title-bar space for tab actions."
        )

        let secureKeyboardAction = terminalWindow
            .buttons["mac-workspace-secure-keyboard-entry"]
            .firstMatch
        let focusModeAction = terminalWindow.buttons["Focus Mode"].firstMatch
        let terminalToolsMenu = terminalWindow
            .menuButtons["Local terminal tools menu"]
            .firstMatch
        XCTAssertTrue(secureKeyboardAction.waitForExistence(timeout: 3))
        XCTAssertTrue(focusModeAction.waitForExistence(timeout: 3))
        XCTAssertTrue(terminalToolsMenu.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            secureKeyboardAction.frame.maxX,
            connectionsAction.frame.minX,
            "Window-level controls should remain separated from terminal-level tools."
        )
        let windowToTerminalGap =
            connectionsAction.frame.minX - secureKeyboardAction.frame.maxX
        let terminalToolGap =
            terminalToolsMenu.frame.minX - focusModeAction.frame.maxX
        XCTAssertLessThan(
            terminalToolGap,
            windowToTerminalGap,
            "Settings should remain grouped with terminal tools after the window-level separator."
        )
        let workspaceIdentifier = terminalWindow.identifier
        XCTAssertFalse(
            workspaceIdentifier.isEmpty,
            "The terminal workspace must expose a stable scene identifier."
        )
        let focusedTerminalWindow = terminalWorkspaceWindow(
            identifier: workspaceIdentifier
        )
        focusedTerminalWindow.click()
        focusedTerminalWindow.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(
            focusedTerminalWindow.staticTexts["New Terminal"].waitForExistence(timeout: 10),
            "Command-T should add and select a second adaptive workspace tab."
        )
        let groupedTerminalWindow = terminalWorkspaceWindow(
            identifier: workspaceIdentifier
        )
        let tabActions = groupedTerminalWindow.menuButtons["Tab Actions"].firstMatch
        XCTAssertTrue(
            tabActions.waitForExistence(timeout: 3),
            "Move Tab should become available when the window contains multiple tabs."
        )
        activate(tabActions)
        XCTAssertTrue(
            app.menuItems["Move Tab to New Window"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.menuItems["Close Tab"].exists,
            "Native window and keyboard controls already provide tab closure."
        )
        groupedTerminalWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
        ).click()

        let groupedSidebarToggles = groupedTerminalWindow.buttons.matching(
            NSPredicate(format: "label IN %@", ["Show Sidebar", "Hide Sidebar"])
        )
        let groupedSidebarToggle = groupedSidebarToggles.firstMatch
        XCTAssertTrue(groupedSidebarToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(
            groupedSidebarToggles.count,
            1,
            "A grouped terminal window must expose one native sidebar toggle."
        )
        let sidebar = groupedTerminalWindow.outlines.firstMatch
        let sidebarWasVisible = sidebar.exists
        activate(groupedSidebarToggle)
        if sidebarWasVisible {
            XCTAssertTrue(
                sidebar.waitForNonExistence(timeout: 5),
                "The standard AppKit action should close the terminal sidebar."
            )
        } else {
            XCTAssertTrue(
                sidebar.waitForExistence(timeout: 5),
                "The standard AppKit action should open the terminal sidebar."
            )
        }
        activate(groupedSidebarToggle)
        if sidebarWasVisible {
            XCTAssertTrue(
                sidebar.waitForExistence(timeout: 5),
                "The standard AppKit action should restore the terminal sidebar."
            )
        } else {
            XCTAssertTrue(
                sidebar.waitForNonExistence(timeout: 5),
                "The standard AppKit action should restore the hidden sidebar state."
            )
        }

        XCTAssertTrue(
            connectionsWindow.exists && library.exists,
            "Opening the native terminal sidebar must leave the Connections Library open."
        )
        closeAllTerminalWorkspaces()
    }
    #else
    @MainActor
    func testConnectionLifecycleSearchCollectionsAndFavorite() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The mutating UI fixture runs only on an isolated simulator.")
        }
        #if os(visionOS)
        throw XCTSkip(
            "visionOS Simulator XCTest cannot synthesize scrolling in the Add Server sheet; "
                + "Xcode 27 reports a nil Accessibility scene ID."
        )
        #else
        prepareApp()
        openAllConnections()
        createTestServer()
        verifyConnectionDrillDown()
        returnToConnectionResultsIfNeeded()
        verifySearchFindsTestServer()
        verifyEditCanFavoriteTestServer()

        navigate(to: "Favorites", scopeIdentifier: "connection-library-scope-favorites")
        exposeTestServerThroughSearchIfNeeded(force: true)
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "Favoriting a connection should immediately project it into Favorites."
        )

        let collectionID = "connection-library-scope-collection-\(testServerTag.lowercased())"
        navigate(to: "Collections", scopeIdentifier: collectionID)
        exposeTestServerThroughSearchIfNeeded(force: true)
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "The saved connection should appear in its normalized tag collection."
        )

        deleteTestServer(assertRemoval: true)
        #endif
    }

    #endif

    @MainActor
    private var library: XCUIElement {
        #if os(macOS)
        // AppKit's NavigationSplitView may replace the SwiftUI root identifier
        // with its native container name. Its navigation child remains stable.
        return firstExistingElement(withIdentifiers: [
            "connection-library",
            "connection-library-navigation",
            "connection-library-results-connections"
        ])
        #else
        element(identifier: "connection-library")
        #endif
    }

    @MainActor
    private var resultsConnections: XCUIElement {
        element(identifier: "connection-library-results-connections")
    }

    @MainActor
    private var resultsWorkgroups: XCUIElement {
        element(identifier: "connection-library-results-workgroups")
    }

    @MainActor
    private var credentialCleanupMarker: XCUIElement {
        element(identifier: Self.credentialCleanupIdentifier)
    }

    @MainActor
    private func launchCredentialCleanupApp() {
        let cleanupApp = XCUIApplication()
        cleanupApp.launchEnvironment[Self.credentialCleanupEnvironmentKey] = "1"
        #if os(macOS)
        cleanupApp.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        cleanupApp.launch()
        XCTAssertTrue(
            cleanupApp.descendants(matching: .any)[
                Self.credentialCleanupIdentifier
            ].waitForExistence(timeout: 15),
            "UI-test teardown must remove the shared GlassSecretStore credential."
        )
        terminateAndWait(cleanupApp)
    }

    @MainActor
    private func terminateAndWait(_ application: XCUIApplication?) {
        guard let application, application.state != .notRunning else { return }
        application.terminate()
        XCTAssertTrue(
            application.wait(for: .notRunning, timeout: 10),
            "The UI-test app must fully terminate before the next isolated launch."
        )
    }

    @MainActor
    private var addServerAction: XCUIElement {
        firstExistingElement(withIdentifiers: [
            "connection-library-add-server-toolbar",
            "connection-library-add-server-results",
            "connection-library-add-server-empty-detail",
            "connection-library-detail-empty-server"
        ])
    }

    @MainActor
    private var testServerRow: XCUIElement {
        testServerContainer
    }

    @MainActor
    private var testServerContainer: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
                "connection-library-server-",
                "connection-library-server-name-"
            )
        ).matching(
            NSPredicate(format: "label CONTAINS %@", testServerName)
        ).firstMatch
    }

    @MainActor
    private var testServerNameLabel: XCUIElement {
        testServerContainer.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "connection-library-server-name-"
            )
        ).firstMatch
    }

    @MainActor
    private var selectedServerDetail: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "connection-library-detail-server-"
            )
        ).firstMatch
    }

    @MainActor
    private var selectedServerConnectAction: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "connection-library-connect-server-"
            )
        ).firstMatch
    }

    #if os(macOS)
    @MainActor
    private func verifyConnectionLibraryToolbar() {
        let window = firstExistingConnectionLibraryWindow()
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let addConnection = window.buttons[
            "connection-library-add-server-toolbar"
        ].firstMatch
        let localTerminal = window.buttons[
            "connection-library-local-terminal-toolbar"
        ].firstMatch
        let sidebarToggles = window.buttons.matching(
            NSPredicate(format: "label IN %@", ["Show Sidebar", "Hide Sidebar"])
        )
        let sidebarToggle = sidebarToggles.firstMatch
        XCTAssertTrue(addConnection.waitForExistence(timeout: 5))
        XCTAssertTrue(localTerminal.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))

        let sidebar = window.descendants(matching: .any)[
            "connection-library-navigation"
        ].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            addConnection.frame.midY,
            window.frame.minY + 80,
            "Add Connection should remain in the native title-bar toolbar."
        )
        XCTAssertLessThan(
            localTerminal.frame.midY,
            window.frame.minY + 80,
            "Local Terminal should remain in the native title-bar toolbar."
        )

        XCTAssertTrue(
            app.windows["All Connections"].exists,
            "The native window title should identify the active Library scope."
        )
        XCTAssertFalse(
            window.buttons["connection-library-add-server-sidebar"].exists,
            "The sidebar footer should not duplicate Add Connection."
        )
        XCTAssertFalse(
            window.buttons["connection-library-add-server-empty-results"].exists,
            "The results empty state should not duplicate Add Connection."
        )
        XCTAssertEqual(
            sidebarToggles.count,
            1,
            "Connections must expose exactly one native sidebar toggle."
        )

        let allConnections = window.descendants(matching: .any)[
            "connection-library-scope-all-connections"
        ].firstMatch
        XCTAssertTrue(
            allConnections.waitForExistence(timeout: 3)
                && allConnections.isHittable,
            "The connection sidebar should begin visible."
        )
        activate(sidebarToggle)
        let sidebarHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !allConnections.isHittable },
            object: allConnections
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebarHidden], timeout: 5),
            .completed,
            "The native sidebar control should hide this window's sidebar."
        )
        activate(sidebarToggle)
        let sidebarRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in allConnections.isHittable },
            object: allConnections
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebarRestored], timeout: 5),
            .completed,
            "The native sidebar control should restore this window's sidebar."
        )
    }

    @MainActor
    private func verifyAddServerPresentationAndDismissal() {
        XCTAssertTrue(
            addServerAction.waitForExistence(timeout: 5),
            "The macOS connection library should always offer an Add Server action."
        )
        activate(addServerAction)

        XCTAssertTrue(
            app.staticTexts["Add Server"].waitForExistence(timeout: 5),
            "The macOS Add Server form should open without modifying saved profiles."
        )
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        activate(cancel)
        XCTAssertTrue(library.waitForExistence(timeout: 5))
    }

    @MainActor
    private func verifyLocalTerminalRouteKeepsLibraryOpen() {
        let connectionsWindow = firstExistingConnectionLibraryWindow()
        XCTAssertTrue(connectionsWindow.waitForExistence(timeout: 5))

        let terminalWindow = openLocalTerminalWorkspace()
        XCTAssertTrue(
            connectionsWindow.exists && library.exists,
            "Opening a terminal workspace must leave the Connections Library open."
        )

        closeTerminalWorkspace(terminalWindow)
    }

    @MainActor
    private func openLocalTerminalWorkspace() -> XCUIElement {
        let existingWorkspaceIDs = Set(
            terminalWorkspaceWindows.map(\.identifier)
        )
        let localTerminal = app.buttons[
            "connection-library-local-terminal-toolbar"
        ].firstMatch
        XCTAssertTrue(
            localTerminal.waitForExistence(timeout: 5),
            "The macOS Library should expose the non-persisted Local Terminal route."
        )
        activate(localTerminal)

        let workspaceOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.terminalWorkspaceWindows.contains {
                    !existingWorkspaceIDs.contains($0.identifier)
                        && $0.staticTexts["Local"].exists
                }
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [workspaceOpened], timeout: 10),
            .completed,
            "Local Terminal should open a separate terminal workspace."
        )
        let terminalWindow = terminalWorkspaceWindows.first {
            !existingWorkspaceIDs.contains($0.identifier)
                && $0.staticTexts["Local"].exists
        }
        XCTAssertNotNil(
            terminalWindow,
            "The workspace should be discoverable by its stable native toolbar actions."
        )
        guard let terminalWindow else { return app.windows.firstMatch }
        let workspaceIdentifier = terminalWindow.identifier
        XCTAssertFalse(
            workspaceIdentifier.isEmpty,
            "The terminal workspace must expose a stable scene identifier."
        )
        return terminalWorkspaceWindow(identifier: workspaceIdentifier)
    }

    @MainActor
    private func terminalWorkspaceWindow(identifier: String) -> XCUIElement {
        app.windows.matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func closeTerminalWorkspace(_ terminalWindow: XCUIElement) {
        let workspaceIdentifier = terminalWindow.identifier
        XCTAssertFalse(
            workspaceIdentifier.isEmpty,
            "A terminal workspace must expose a stable scene identifier."
        )
        let closeButton = terminalWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.click()
        // SwiftUI's window-close confirmation is exposed as an app-level
        // alert-labelled sheet rather than a descendant of the cached window.
        let confirmation = app.sheets.firstMatch
        if confirmation.waitForExistence(timeout: 2) {
            XCTAssertTrue(confirmation.staticTexts["Close Terminal?"].waitForExistence(timeout: 2))
            let confirmClose = confirmation.buttons["Close"].firstMatch
            XCTAssertTrue(confirmClose.waitForExistence(timeout: 2))
            confirmClose.click()
        }
        let workspaceClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return !self.terminalWorkspaceWindows.contains {
                    $0.identifier == workspaceIdentifier
                }
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [workspaceClosed], timeout: 3),
            .completed,
            "Closing the local terminal should remove its workspace window."
        )
    }

    @MainActor
    private func closeAllTerminalWorkspaces() {
        var attemptsRemaining = 10
        while let terminalWindow = terminalWorkspaceWindows.first,
              attemptsRemaining > 0 {
            closeTerminalWorkspace(terminalWindow)
            attemptsRemaining -= 1
        }
        XCTAssertTrue(
            terminalWorkspaceWindows.isEmpty,
            "The toolbar smoke test must close every native terminal tab it creates."
        )
    }

    @MainActor
    private var terminalWorkspaceWindows: [XCUIElement] {
        app.windows.allElementsBoundByIndex.filter {
            $0.buttons["New Local Pane"].exists
        }
    }

    @MainActor
    private func firstExistingButton(
        in container: XCUIElement,
        withLabels labels: [String]
    ) -> XCUIElement {
        for label in labels {
            let button = container.buttons[label].firstMatch
            if button.waitForExistence(timeout: 1) {
                return button
            }
        }
        return container.buttons[labels[0]].firstMatch
    }

    #endif

    @MainActor
    private func createTestServer() {
        XCTAssertTrue(
            addServerAction.waitForExistence(timeout: 5),
            "The connection library should always offer an Add Server action."
        )
        activate(addServerAction)

        XCTAssertTrue(
            app.navigationBars["Add Server"].waitForExistence(timeout: 5)
                || app.staticTexts["Add Server"].waitForExistence(timeout: 2),
            "The Add Server flow should open from the connection library."
        )

        replaceText(in: app.textFields["add-server-display-name"], with: testServerName)
        replaceText(in: app.textFields["add-server-host"], with: "192.0.2.1")
        replaceText(in: app.textFields["add-server-username"], with: "ui-test")
        replaceText(
            in: app.secureTextFields["add-server-password"],
            with: "UI-Test-\(UUID().uuidString)"
        )
        replaceText(in: app.textFields["add-server-tag"], with: testServerTag)

        let save = app.buttons["Add Server"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        activate(save)
        dismissSavePasswordPromptIfPresent()

        openAllConnections()
        exposeTestServerThroughSearchIfNeeded()
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 8))
    }

    @MainActor
    private func verifyConnectionDrillDown() {
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            testServerNameLabel.waitForExistence(timeout: 5),
            "A saved connection's name should remain visible as an independent row label."
        )
        if resultsConnections.exists {
            let resultsFrame = resultsConnections.frame
            let nameFrame = testServerNameLabel.frame
            XCTAssertGreaterThan(nameFrame.width, 0)
            XCTAssertGreaterThanOrEqual(
                nameFrame.minX,
                resultsFrame.minX - 1,
                "The connection name must not clip past the regular-width results column's leading edge."
            )
            XCTAssertLessThanOrEqual(
                nameFrame.maxX,
                resultsFrame.maxX + 1,
                "The connection name must remain inside the regular-width results column."
            )
        }
        activate(testServerRow)

        XCTAssertTrue(
            selectedServerDetail.waitForExistence(timeout: 10),
            "Selecting a connection should expose its identified detail surface without connecting."
        )
        XCTAssertTrue(
            selectedServerConnectAction.waitForExistence(timeout: 5),
            "The selected connection detail should expose its explicit Connect action."
        )

        if resultsConnections.exists && testServerRow.exists {
            XCTAssertTrue(
                resultsConnections.exists,
                "Regular-width layouts should retain results while showing detail."
            )
            XCTAssertTrue(testServerRow.exists)
        } else {
            let backToResults = app.navigationBars.buttons["All Connections"].firstMatch
            XCTAssertTrue(
                backToResults.waitForExistence(timeout: 3),
                "Compact layouts should drill into detail with native stack navigation."
            )
        }
    }

    @MainActor
    private func assertTestServerDetailIsVisible(_ message: String) {
        XCTAssertTrue(
            selectedServerDetail.waitForExistence(timeout: 10),
            message
        )
        XCTAssertTrue(
            selectedServerConnectAction.waitForExistence(timeout: 5),
            "Selecting the connection should expose its explicit Connect action."
        )
    }

    @MainActor
    private func verifySearchFindsTestServer() {
        clearSearchIfPresent()
        exposeTestServerThroughSearchIfNeeded(force: true)
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "Search should find a saved connection by its display name."
        )
        clearFocusedTextInput()
        XCTAssertTrue(resultsConnections.waitForExistence(timeout: 5))
        exposeTestServerThroughSearchIfNeeded(force: true)
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 5))
    }

    @MainActor
    private func exposeTestServerThroughSearchIfNeeded(force: Bool = false) {
        guard force || !testServerRow.exists else { return }
        var search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 1) {
            let searchAction = app.buttons["connection-library-search"].firstMatch
            XCTAssertTrue(
                searchAction.waitForExistence(timeout: 3),
                "The connection results should expose the native Search action."
            )
            activate(searchAction)
            search = app.searchFields.firstMatch
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        activate(search)
        if let value = search.value as? String,
           !value.isEmpty,
           value != search.placeholderValue {
            clearFocusedTextInput()
        }
        search.typeText(testServerName)
    }

    @MainActor
    private func verifyEditCanFavoriteTestServer() {
        activate(testServerRow)
        XCTAssertTrue(selectedServerDetail.waitForExistence(timeout: 10))

        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        activate(edit)
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))

        let favorite = app.switches["Favorite"].firstMatch
        makeHittable(favorite)
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        if !switchIsOn(favorite) {
            favorite.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
        }
        XCTAssertTrue(
            switchIsOn(favorite),
            "The native Favorite switch should be on before saving the edited connection."
        )

        let save = app.navigationBars["Edit Connection"].buttons["Save Changes"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        activate(save)
        dismissSavePasswordPromptIfPresent()
        returnToConnectionResultsIfNeeded()
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 8))
    }

    @MainActor
    private func verifySettingsRoundTrip() {
        dismissSavePasswordPromptIfPresent()
        returnToRootIfNeeded()
        let settings = app.buttons["connection-library-settings"].firstMatch
        makeHittable(settings)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        #if os(macOS)
        let connectionsWindow = firstExistingConnectionLibraryWindow()
        XCTAssertTrue(connectionsWindow.waitForExistence(timeout: 5))
        let searchField = connectionsWindow.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            settings.frame.midY,
            connectionsWindow.frame.minY + 80,
            "Settings should remain in the native title-bar toolbar."
        )
        XCTAssertLessThan(
            abs(settings.frame.midY - searchField.frame.midY),
            12,
            "Settings should align with the native Connections search field."
        )
        XCTAssertGreaterThan(
            settings.frame.midX,
            searchField.frame.midX,
            "Settings should appear after the native Connections search field."
        )
        activate(settings)

        XCTAssertTrue(
            app.buttons["General"].waitForExistence(timeout: 5)
                || app.staticTexts["General"].waitForExistence(timeout: 2),
            "Settings should open on the General settings surface."
        )
        app.typeKey("w", modifierFlags: .command)
        connectionsWindow.click()
        #elseif os(visionOS)
        let connectionsWindow = firstExistingConnectionLibraryWindow()
        XCTAssertTrue(connectionsWindow.waitForExistence(timeout: 5))
        activate(settings)

        XCTAssertTrue(
            app.buttons["General"].waitForExistence(timeout: 5)
                || app.staticTexts["Connection"].waitForExistence(timeout: 2),
            "Settings should open in its native visionOS window."
        )
        app.typeKey(XCUIKeyboardKey(rawValue: "w"), modifierFlags: .command)
        if connectionsWindow.exists {
            connectionsWindow.tap()
        }
        #else
        activate(settings)

        XCTAssertTrue(
            app.buttons["General"].waitForExistence(timeout: 5)
                || app.staticTexts["Connection"].waitForExistence(timeout: 2),
            "Settings should open on the General settings surface."
        )
        let done = app.buttons["Done"].firstMatch
        if done.exists {
            activate(done)
        } else {
            app.swipeDown()
        }
        #endif
        XCTAssertTrue(library.waitForExistence(timeout: 5))
    }

    @MainActor
    private func firstExistingConnectionLibraryWindow() -> XCUIElement {
        let titledWindow = app.windows["All Connections"].firstMatch
        if titledWindow.exists { return titledWindow }
        let connectionsWindow = app.windows["Connections"].firstMatch
        return connectionsWindow.exists ? connectionsWindow : app.windows.firstMatch
    }

    #if os(macOS)
    @MainActor
    private func focusConnectionLibraryWindow() {
        let connectionsWindow = app.windows.matching(identifier: "main").firstMatch
        XCTAssertTrue(
            connectionsWindow.waitForExistence(timeout: 5),
            "The native Connections window should exist before Library navigation."
        )
        if connectionsWindow.isHittable {
            connectionsWindow.click()
            return
        }

        // macOS may restore a terminal workspace in front of Connections.
        // Raise the existing window through AppKit's Window menu rather than
        // clicking through the overlapping terminal surface.
        let windowMenu = app.menuBars.menuBarItems["Window"].firstMatch
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 3))
        windowMenu.click()
        let connectionsMenuItem = app.menuItems["Connections"].firstMatch
        XCTAssertTrue(connectionsMenuItem.waitForExistence(timeout: 3))
        connectionsMenuItem.click()
        XCTAssertTrue(
            connectionsWindow.isHittable,
            "The Window menu should bring Connections in front of restored terminal workspaces."
        )
    }
    #endif

    @MainActor
    private func openAllConnections() {
        navigate(to: "Library", scopeIdentifier: "connection-library-scope-all-connections")
        XCTAssertTrue(resultsConnections.waitForExistence(timeout: 5))
    }

    @MainActor
    private func navigate(to mode: String, scopeIdentifier: String) {
        dismissSavePasswordPromptIfPresent()
        clearSearchIfPresent()
        returnToRootIfNeeded()
        #if os(macOS)
        focusConnectionLibraryWindow()
        #endif

        var scope = buttonOrElement(identifier: scopeIdentifier)
        if scope.waitForExistence(timeout: 1) {
            activate(scope)
            assertResultsSurface(for: mode)
            return
        }

        let ornamentMode = buttonOrElement(
            identifier: "connection-library-mode-\(mode.lowercased())"
        )
        XCTAssertTrue(
            ornamentMode.waitForExistence(timeout: 3),
            "The \(mode) route should be reachable from this platform's Library navigation."
        )
        activate(ornamentMode)

        if mode == "Collections" {
            scope = buttonOrElement(identifier: scopeIdentifier)
            XCTAssertTrue(
                scope.waitForExistence(timeout: 5),
                "The selected collection should appear in the visionOS collection column."
            )
            activate(scope)
        }
        assertResultsSurface(for: mode)
    }

    @MainActor
    private func assertResultsSurface(for mode: String) {
        let expected = mode == "Workgroups"
            ? resultsWorkgroups
            : resultsConnections
        XCTAssertTrue(
            expected.waitForExistence(timeout: 5),
            "Selecting \(mode) should update the shared results surface."
        )
    }

    @MainActor
    private func returnToConnectionResultsIfNeeded() {
        guard !resultsConnections.exists else { return }
        let backToResults = app.navigationBars.buttons["All Connections"].firstMatch
        if backToResults.waitForExistence(timeout: 2) {
            activate(backToResults)
        }
        XCTAssertTrue(resultsConnections.waitForExistence(timeout: 5))
    }

    @MainActor
    private func returnToRootIfNeeded() {
        #if os(visionOS)
        // The native visionOS mode ornaments are the Library root. There is no
        // compact-stack navigation column to unwind.
        return
        #else
        let rootScope = buttonOrElement(
            identifier: "connection-library-scope-all-connections"
        )
        if rootScope.isHittable { return }

        #if os(macOS)
        let showSidebar = app.buttons["Show Sidebar"].firstMatch
        if showSidebar.waitForExistence(timeout: 2), showSidebar.isHittable {
            activate(showSidebar)
            if rootScope.waitForExistence(timeout: 5), rootScope.isHittable {
                return
            }
        }
        #endif

        for _ in 0..<3 where !rootScope.isHittable {
            let backToRoot = app.navigationBars.buttons["Connections"].firstMatch
            if backToRoot.waitForExistence(timeout: 1), backToRoot.isHittable {
                activate(backToRoot)
                continue
            }
            let backToResults = app.navigationBars.buttons["All Connections"].firstMatch
            if backToResults.waitForExistence(timeout: 1), backToResults.isHittable {
                activate(backToResults)
                continue
            }
            break
        }
        XCTAssertTrue(
            rootScope.waitForExistence(timeout: 5) && rootScope.isHittable,
            "Compact navigation must return to the visible Connections root."
        )
        #endif
    }

    @MainActor
    private func switchIsOn(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        guard let value = element.value as? String else { return false }
        return ["1", "true", "on", "yes"].contains(value.lowercased())
    }

    @MainActor
    private func deleteTestServer(assertRemoval: Bool) {
        dismissSavePasswordPromptIfPresent()
        dismissPresentedEditorIfNeeded()
        clearSearchIfPresent()
        openAllConnections()

        let row = testServerRow
        if !row.waitForExistence(timeout: 2) {
            exposeTestServerThroughSearchIfNeeded()
        }
        guard row.waitForExistence(timeout: 3) else {
            if assertRemoval {
                XCTFail("The persisted UI fixture must remain discoverable by exact-name search for teardown.")
            }
            return
        }

        #if os(macOS)
        testServerNameLabel.rightClick()
        #else
        testServerNameLabel.press(forDuration: 1)
        #endif

        let deleteButton = app.buttons["Delete"].firstMatch
        let deleteMenuItem = app.menuItems["Delete"].firstMatch
        let delete = deleteButton.exists ? deleteButton : deleteMenuItem
        if assertRemoval {
            XCTAssertTrue(delete.waitForExistence(timeout: 2))
        }
        guard delete.exists else { return }
        activate(delete)

        let confirm = app.descendants(matching: .any)[
            "connection-library-confirm-delete-server"
        ].firstMatch
        if assertRemoval {
            XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        }
        guard confirm.exists else { return }
        activate(confirm)

        if assertRemoval {
            XCTAssertFalse(
                row.waitForExistence(timeout: 5),
                "Deleting the UI fixture should remove its projected row."
            )
        }
    }

    @MainActor
    private func dismissPresentedEditorIfNeeded() {
        let cancel = app.buttons["Cancel"].firstMatch
        if (app.navigationBars["Add Server"].exists || app.navigationBars["Edit Connection"].exists),
           cancel.exists {
            activate(cancel)
        }
    }

    @MainActor
    private func dismissSavePasswordPromptIfPresent() {
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 1) {
            activate(notNow)
            XCTAssertFalse(
                app.alerts["Save Password?"].waitForExistence(timeout: 2),
                "The system password-save interruption should dismiss before Library navigation continues."
            )
        }
    }

    @MainActor
    private func clearSearchIfPresent() {
        let search = app.searchFields.firstMatch
        if search.exists,
           let value = search.value as? String,
           !value.isEmpty,
           value != search.placeholderValue {
            activate(search)
            clearFocusedTextInput()
        }

        #if os(iOS)
        let closeSearch = app.buttons["close"].firstMatch
        if closeSearch.waitForExistence(timeout: 1) {
            closeSearch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
            XCTAssertFalse(
                app.keyboards.firstMatch.waitForExistence(timeout: 2),
                "Dismissing native search should also dismiss the software keyboard."
            )
        }
        #endif
    }

    @MainActor
    private func clearFocusedTextInput() {
        app.typeKey(XCUIKeyboardKey(rawValue: "a"), modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        makeHittable(field)
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        activate(field)
        if let currentValue = field.value as? String,
           !currentValue.isEmpty,
           currentValue != field.placeholderValue {
            clearFocusedTextInput()
        }
        field.typeText(value)
        if field.elementType != .secureTextField {
            let committedValue = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    (object as? XCUIElement)?.value as? String == value
                },
                object: field
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [committedValue], timeout: 2),
                .completed,
                "\(field.placeholderValue ?? "Text field") should commit its complete value before focus moves."
            )
        }
        if field.placeholderValue == "Add tag" {
            let returnKey = app.keyboards.buttons["return"].firstMatch
            if returnKey.exists {
                activate(returnKey)
            }
        }
    }

    @MainActor
    private func makeHittable(_ element: XCUIElement) {
        #if os(macOS)
        // Every field in the macOS form is already visible in its native sheet.
        // Swiping a sheet to expose a transiently re-rendering field can dismiss
        // the sheet before XCTest resolves the field's replacement AX node.
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        return
        #else
        for _ in 0..<5 where !element.isHittable {
            let sheet = app.sheets.firstMatch
            if sheet.exists {
                sheet.swipeUp()
            } else if app.keyboards.firstMatch.exists {
                let start = app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)
                )
                let end = app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16)
                )
                start.press(forDuration: 0.1, thenDragTo: end)
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
        #endif
    }

    @MainActor
    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func buttonOrElement(identifier: String) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        return button.exists ? button : element(identifier: identifier).firstMatch
    }

    @MainActor
    private func firstExistingElement(withIdentifiers identifiers: [String]) -> XCUIElement {
        for identifier in identifiers {
            let candidate = buttonOrElement(identifier: identifier)
            if candidate.waitForExistence(timeout: 1) {
                return candidate
            }
        }
        return buttonOrElement(identifier: identifiers[0])
    }

    @MainActor
    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
}
