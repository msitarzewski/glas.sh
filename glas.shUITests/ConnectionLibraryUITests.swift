import XCTest

final class ConnectionLibraryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testServerName = ""
    private var testServerTag = ""
    private var createdTestServer = false

    @MainActor
    private func prepareApp() {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        testServerName = "Connection Library UI Test \(suffix)"
        testServerTag = "UI Test \(suffix)"
        app = XCUIApplication()
        app.launch()

        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            self.dismissSavePasswordPromptIfPresent()
            if self.createdTestServer {
                self.deleteTestServer(assertRemoval: true)
            }
            self.app?.terminate()
            self.app = nil
        }

        XCTAssertTrue(
            library.waitForExistence(timeout: 15),
            "The connection library should be the app's initial surface."
        )
    }

    @MainActor
    func testLibraryModesSettingsAndUnconfiguredNetwork() {
        prepareApp()
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
        verifyAddServerPresentationAndDismissal()
        verifyLocalTerminalRouteKeepsLibraryOpen()
    }
    #else
    @MainActor
    func testConnectionLifecycleSearchCollectionsAndFavorite() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil else {
            throw XCTSkip("The mutating UI fixture runs only on an isolated simulator.")
        }

        prepareApp()
        openAllConnections()
        createTestServer()
        verifyConnectionDrillDown()
        returnToConnectionResultsIfNeeded()
        verifySearchFindsTestServer()
        verifyEditCanFavoriteTestServer()

        navigate(to: "Favorites", scopeIdentifier: "connection-library-scope-favorites")
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "Favoriting a connection should immediately project it into Favorites."
        )

        let collectionID = "connection-library-scope-collection-\(testServerTag.lowercased())"
        navigate(to: "Collections", scopeIdentifier: collectionID)
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "The saved connection should appear in its normalized tag collection."
        )

        deleteTestServer(assertRemoval: true)
    }
    #endif

    @MainActor
    private var library: XCUIElement {
        element(identifier: "connection-library")
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
    private var addServerAction: XCUIElement {
        firstExistingElement(withIdentifiers: [
            "connection-library-add-server-results",
            "connection-library-add-server-sidebar",
            "connection-library-add-server-empty-results",
            "connection-library-add-server-empty-detail"
        ])
    }

    @MainActor
    private var testServerRow: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "connection-library-server-",
                testServerName
            )
        ).firstMatch
    }

    @MainActor
    private var testServerNameLabel: XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "connection-library-server-name-"
            )
        ).matching(
            NSPredicate(format: "label == %@", testServerName)
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
        let connectionsWindow = app.windows["Connections"].firstMatch
        XCTAssertTrue(connectionsWindow.waitForExistence(timeout: 5))

        let localTerminal = app.buttons["Local Terminal"].firstMatch
        XCTAssertTrue(
            localTerminal.waitForExistence(timeout: 5),
            "The macOS Library should expose the non-persisted Local Terminal route."
        )
        activate(localTerminal)

        let terminalWindow = app.windows["Terminal"].firstMatch
        XCTAssertTrue(
            terminalWindow.waitForExistence(timeout: 10),
            "Local Terminal should open a separate terminal workspace."
        )
        XCTAssertTrue(
            connectionsWindow.exists && library.exists,
            "Opening a terminal workspace must leave the Connections Library open."
        )

        let closeButton = terminalWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.click()
        let confirmation = app.sheets["Close Terminal?"].firstMatch
        if confirmation.waitForExistence(timeout: 2) {
            app.buttons["Close"].firstMatch.click()
        }
        XCTAssertFalse(terminalWindow.waitForExistence(timeout: 3))
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

        replaceText(in: app.textFields["Display Name"], with: testServerName)
        replaceText(in: app.textFields["Host"], with: "192.0.2.1")
        replaceText(in: app.textFields["Username"], with: "ui-test")
        replaceText(
            in: app.secureTextFields["Password"],
            with: "UI-Test-\(UUID().uuidString)"
        )
        replaceText(in: app.textFields["Add tag"], with: testServerTag)

        let save = app.navigationBars["Add Server"].buttons["Add Server"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        activate(save)
        createdTestServer = true
        dismissSavePasswordPromptIfPresent()

        XCTAssertTrue(testServerRow.waitForExistence(timeout: 8))
    }

    @MainActor
    private func verifyConnectionDrillDown() {
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            testServerNameLabel.waitForExistence(timeout: 5),
            "A saved connection's name should remain visible as an independent row label."
        )
        if app.windows.firstMatch.frame.width >= 700 {
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

        if app.windows.firstMatch.frame.width >= 700 {
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
    private func verifySearchFindsTestServer() {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        activate(search)
        search.typeText(testServerName)
        XCTAssertTrue(
            testServerRow.waitForExistence(timeout: 5),
            "Search should find a saved connection by its display name."
        )
        clearFocusedTextInput()
        XCTAssertTrue(testServerRow.waitForExistence(timeout: 5))
    }

    @MainActor
    private func verifyEditCanFavoriteTestServer() {
        activate(testServerRow)
        XCTAssertTrue(selectedServerDetail.waitForExistence(timeout: 10))

        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        activate(edit)
        XCTAssertTrue(app.navigationBars["Edit Server"].waitForExistence(timeout: 5))

        let favorite = app.switches["Favorite"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        if (favorite.value as? String) != "1" {
            activate(favorite)
        }

        let save = app.navigationBars["Edit Server"].buttons["Save"].firstMatch
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
        let settings = buttonOrElement(identifier: "connection-library-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        #if os(macOS)
        let connectionsWindow = app.windows["Connections"].firstMatch
        activate(settings)

        XCTAssertTrue(
            app.buttons["General"].waitForExistence(timeout: 5)
                || app.staticTexts["General"].waitForExistence(timeout: 2),
            "Settings should open on the General settings surface."
        )
        app.typeKey("w", modifierFlags: .command)
        connectionsWindow.click()
        #else
        activate(settings)

        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 5),
            "Settings should open as a dismissible app route."
        )
        XCTAssertTrue(
            app.buttons["General"].exists || app.staticTexts["Connection"].exists,
            "Settings should open on the General settings surface."
        )
        activate(app.buttons["Done"])
        #endif
        XCTAssertTrue(library.waitForExistence(timeout: 5))
    }

    @MainActor
    private func openAllConnections() {
        navigate(to: "Library", scopeIdentifier: "connection-library-scope-all-connections")
        XCTAssertTrue(resultsConnections.waitForExistence(timeout: 5))
    }

    @MainActor
    private func navigate(to mode: String, scopeIdentifier: String) {
        dismissSavePasswordPromptIfPresent()
        returnToRootIfNeeded()

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
        let navigation = element(identifier: "connection-library-navigation")
        if navigation.exists { return }

        for _ in 0..<3 where !navigation.exists {
            let backToRoot = app.navigationBars.buttons["Connections"].firstMatch
            if backToRoot.waitForExistence(timeout: 1) {
                activate(backToRoot)
                continue
            }
            let backToResults = app.navigationBars.buttons["All Connections"].firstMatch
            if backToResults.waitForExistence(timeout: 1) {
                activate(backToResults)
                continue
            }
            break
        }
    }

    @MainActor
    private func deleteTestServer(assertRemoval: Bool) {
        dismissSavePasswordPromptIfPresent()
        dismissPresentedEditorIfNeeded()
        clearSearchIfPresent()
        openAllConnections()

        let row = testServerRow
        guard row.waitForExistence(timeout: 3) else {
            createdTestServer = false
            return
        }

        let actions = app.buttons["Actions for \(testServerName)"].firstMatch
        if assertRemoval {
            XCTAssertTrue(actions.waitForExistence(timeout: 3))
        }
        guard actions.exists else { return }
        activate(actions)

        let delete = app.buttons["Delete"].firstMatch
        if assertRemoval {
            XCTAssertTrue(delete.waitForExistence(timeout: 2))
        }
        guard delete.exists else { return }
        activate(delete)

        let confirm = app.buttons["Delete \(testServerName)"].firstMatch
        if assertRemoval {
            XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        }
        guard confirm.exists else { return }
        activate(confirm)

        if assertRemoval {
            XCTAssertFalse(
                row.waitForExistence(timeout: 5),
                "Deleting the UI fixture should remove its projected row and saved credential."
            )
        }
        createdTestServer = false
    }

    @MainActor
    private func dismissPresentedEditorIfNeeded() {
        let cancel = app.buttons["Cancel"].firstMatch
        if (app.navigationBars["Add Server"].exists || app.navigationBars["Edit Server"].exists),
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
        guard search.exists,
              let value = search.value as? String,
              !value.isEmpty,
              value != search.placeholderValue else {
            return
        }
        activate(search)
        clearFocusedTextInput()
    }

    @MainActor
    private func clearFocusedTextInput() {
        app.typeKey(XCUIKeyboardKey(rawValue: "a"), modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        makeHittable(field)
        activate(field)
        if let currentValue = field.value as? String,
           !currentValue.isEmpty,
           currentValue != field.placeholderValue {
            clearFocusedTextInput()
        }
        field.typeText(value)
        let returnKey = app.keyboards.buttons["return"].firstMatch
        if returnKey.exists {
            activate(returnKey)
        }
    }

    @MainActor
    private func makeHittable(_ element: XCUIElement) {
        for _ in 0..<5 where !element.isHittable {
            let form = app.collectionViews.firstMatch
            if form.exists {
                form.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
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
