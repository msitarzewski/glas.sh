#if os(macOS)
import Foundation
import Observation
import RealityKitContent
import os

@MainActor
@Observable
final class MacWorkspaceController {
    private static let maximumEncodedBytes = 128 * 1024

    private(set) var state: MacWorkspaceRestorationState
    private(set) var sessionsByPaneID: [UUID: TerminalSession] = [:]
    private(set) var loadingPaneIDs: Set<UUID> = []
    private(set) var errorsByPaneID: [UUID: String] = [:]
    private(set) var localRuntimesByPaneID: [UUID: SwiftTermLocalProcessRuntime] = [:]
    private(set) var recordersByPaneID: [UUID: SessionRecorder] = [:]
    private(set) var findTargetPaneID: UUID?
    private(set) var findRequestNonce: UInt64 = 0
    private(set) var isClosed = false
    var pendingSSHAxis: MacWorkspaceSplitAxis?

    private let defaults: UserDefaults
    private let startupCommandBroker: MacStartupCommandBroker
    private let liveSessionBroker: MacLiveSessionBroker
    private var startupTicketIDsByPaneID: [UUID: UUID] = [:]
    private var lifecycleGeneration: UInt64 = 0

    let workgroupID: UUID?
    let workgroupName: String?
    let workgroupColor: ServerColorTag?
    let tabLabel: String?

    init(
        workspaceID: UUID,
        startsEmptyIfUnrestored: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.startupCommandBroker = .shared
        self.liveSessionBroker = .shared
        self.workgroupID = nil
        self.workgroupName = nil
        self.workgroupColor = nil
        self.tabLabel = nil
        self.state = Self.load(
            workspaceID: workspaceID,
            startsEmptyIfUnrestored: startsEmptyIfUnrestored,
            initialPaneIntent: nil,
            defaults: defaults
        ).state
    }

    convenience init(
        request: MacWorkspaceLaunchRequest,
        startupCommandBroker: MacStartupCommandBroker = .shared,
        liveSessionBroker: MacLiveSessionBroker = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            request: request.tabs[0],
            startupCommandBroker: startupCommandBroker,
            liveSessionBroker: liveSessionBroker,
            defaults: defaults
        )
    }

    init(
        request: MacWorkspaceTabRequest,
        startupCommandBroker: MacStartupCommandBroker = .shared,
        liveSessionBroker: MacLiveSessionBroker = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.startupCommandBroker = startupCommandBroker
        self.liveSessionBroker = liveSessionBroker
        self.workgroupID = request.workgroupID
        self.workgroupName = request.workgroupName
        self.workgroupColor = request.workgroupColor
        self.tabLabel = request.tabLabel
        let loaded = Self.load(
            workspaceID: request.workspaceID,
            startsEmptyIfUnrestored: request.startsEmpty,
            initialPaneIntent: request.initialPaneIntent,
            defaults: defaults
        )
        self.state = loaded.state
        if !loaded.hadRestorationData,
           let paneID = loaded.state.focusedPaneID,
           let ticketID = request.startupTicketID {
            startupTicketIDsByPaneID[paneID] = ticketID
        } else if let ticketID = request.startupTicketID {
            startupCommandBroker.discard(ticketID)
        }
        if !loaded.hadRestorationData,
           let paneID = loaded.state.focusedPaneID,
           let pane = loaded.state.root?.pane(id: paneID),
           let ticketID = request.liveSessionTicketID {
            if let ticket = liveSessionBroker.claim(ticketID) {
                if pane.intent.kind == .ssh,
                   pane.intent.serverID == ticket.session.server.id {
                    sessionsByPaneID[paneID] = ticket.session
                } else {
                    ticket.discard()
                    errorsByPaneID[paneID] = "The prepared terminal session did not match its launch request."
                }
            } else {
                errorsByPaneID[paneID] = "The prepared terminal session expired before its window opened."
            }
        } else if let ticketID = request.liveSessionTicketID {
            liveSessionBroker.discard(ticketID)
        }
    }

    var workspaceID: UUID { state.id }
    var restorationDescriptor: MacWorkspaceTabDescriptor {
        MacWorkspaceTabDescriptor(
            MacWorkspaceTabRequest(
                workspaceID: workspaceID,
                workgroupID: workgroupID,
                workgroupName: workgroupName,
                workgroupColor: workgroupColor,
                tabLabel: tabLabel
            )
        )
    }
    var focusedPaneID: UUID? { state.focusedPaneID }
    var focusedPane: MacWorkspacePane? {
        guard let focusedPaneID else { return nil }
        return state.root?.pane(id: focusedPaneID)
    }

    var isEmpty: Bool { state.root == nil }
    var windowTitle: String {
        switch (workgroupName, tabLabel) {
        case let (.some(workgroup), .some(tab)): "\(workgroup) · \(tab)"
        case let (.some(workgroup), .none): workgroup
        case let (.none, .some(tab)): tab
        case (.none, .none): "Terminal"
        }
    }
    var canAddPane: Bool {
        (state.root?.paneIDs.count ?? 0) < MacWorkspaceRestorationState.maximumPaneCount
    }

    func windowIdentity(
        servers: [ServerConfiguration],
        localUsername: String = NSUserName()
    ) -> MacWorkspaceWindowIdentity {
        guard let focusedPane else {
            return MacWorkspaceWindowIdentity(
                title: windowTitle == "Terminal" ? "New Terminal" : windowTitle,
                subtitle: nil
            )
        }

        switch focusedPane.intent.kind {
        case .local:
            return MacWorkspaceWindowIdentity(
                title: tabLabel ?? workgroupName ?? "Local",
                subtitle: "\(localUsername)@localhost"
            )
        case .ssh:
            let server = session(for: focusedPane.id)?.server
                ?? servers.first(where: { $0.id == focusedPane.intent.serverID })
            guard let server else {
                return MacWorkspaceWindowIdentity(
                    title: tabLabel ?? workgroupName ?? "SSH Terminal",
                    subtitle: nil
                )
            }
            return MacWorkspaceWindowIdentity(
                title: server.name,
                subtitle: "\(server.username)@\(server.host):\(server.port)"
            )
        }
    }

    func focusedSessionState() -> SessionState? {
        guard let focusedPaneID else { return nil }
        return session(for: focusedPaneID)?.state
    }

    func session(for paneID: UUID) -> TerminalSession? {
        sessionsByPaneID[paneID]
    }

    func localRuntime(for paneID: UUID) -> SwiftTermLocalProcessRuntime {
        if let runtime = localRuntimesByPaneID[paneID] {
            return runtime
        }
        precondition(
            state.root?.pane(id: paneID)?.intent.kind == .local,
            "Local terminal runtime requested for a non-local pane"
        )
        let runtime = SwiftTermLocalProcessRuntime()
        localRuntimesByPaneID[paneID] = runtime
        return runtime
    }

    func recorder(for paneID: UUID) -> SessionRecorder {
        if let recorder = recordersByPaneID[paneID] {
            return recorder
        }
        precondition(
            state.root?.pane(id: paneID) != nil,
            "Recorder requested for an unknown terminal pane"
        )
        let recorder = SessionRecorder()
        recordersByPaneID[paneID] = recorder
        return recorder
    }

    func error(for paneID: UUID) -> String? {
        errorsByPaneID[paneID]
    }

    func isLoading(_ paneID: UUID) -> Bool {
        loadingPaneIDs.contains(paneID)
    }

    func focus(_ paneID: UUID) {
        guard state.root?.pane(id: paneID) != nil else { return }
        state.focusedPaneID = paneID
        persist()
    }

    func focusNextPane() {
        let paneIDs = state.root?.paneIDs ?? []
        guard !paneIDs.isEmpty else { return }
        guard let focusedPaneID,
              let index = paneIDs.firstIndex(of: focusedPaneID) else {
            focus(paneIDs[0])
            return
        }
        focus(paneIDs[(index + 1) % paneIDs.count])
    }

    func addPane(
        intent: MacWorkspacePaneIntent,
        axis: MacWorkspaceSplitAxis
    ) {
        guard canAddPane else { return }
        let newPane = MacWorkspacePane(intent: intent)
        guard let root = state.root else {
            state.root = .pane(newPane)
            state.focusedPaneID = newPane.id
            persist()
            return
        }
        let targetID = state.focusedPaneID ?? root.paneIDs.first
        guard let targetID else { return }
        state.root = root.splittingPane(id: targetID, axis: axis, newPane: newPane)
        state.focusedPaneID = newPane.id
        persist()
    }

    func requestSSHPane(axis: MacWorkspaceSplitAxis) {
        pendingSSHAxis = axis
    }

    func addSSHPane(serverID: UUID) {
        let axis = pendingSSHAxis ?? .horizontal
        pendingSSHAxis = nil
        addPane(intent: .ssh(serverID: serverID), axis: axis)
    }

    func cancelSSHPaneRequest() {
        pendingSSHAxis = nil
    }

    func removeFocusedPane(sessionManager: SessionManager) {
        guard let paneID = state.focusedPaneID else { return }
        removePane(paneID, sessionManager: sessionManager)
    }

    func removePane(_ paneID: UUID, sessionManager: SessionManager) {
        guard let root = state.root, root.pane(id: paneID) != nil else { return }
        if let session = sessionsByPaneID.removeValue(forKey: paneID) {
            sessionManager.closeSession(session)
        }
        loadingPaneIDs.remove(paneID)
        errorsByPaneID.removeValue(forKey: paneID)
        localRuntimesByPaneID.removeValue(forKey: paneID)?.terminate()
        recordersByPaneID.removeValue(forKey: paneID)?.finalize()
        discardStartupCommand(for: paneID)
        state.root = root.removingPane(id: paneID)
        state.focusedPaneID = state.root?.paneIDs.first
        persist()
    }

    func updateSplitFraction(_ splitID: UUID, fraction: Double) {
        guard let root = state.root, fraction.isFinite else { return }
        state.root = root.updatingSplitFraction(id: splitID, fraction: fraction)
        persist()
    }

    func retryPane(_ paneID: UUID) {
        guard !isClosed else { return }
        errorsByPaneID.removeValue(forKey: paneID)
    }

    func disconnectSSHPane(_ paneID: UUID, sessionManager: SessionManager) {
        guard !isClosed,
              state.root?.pane(id: paneID)?.intent.kind == .ssh else { return }
        if let session = sessionsByPaneID.removeValue(forKey: paneID) {
            sessionManager.closeSession(session)
        }
        loadingPaneIDs.remove(paneID)
        errorsByPaneID[paneID] = "The SSH session ended. Retry to reconnect."
    }

    func requestFindInFocusedPane() {
        guard let focusedPaneID else { return }
        findTargetPaneID = focusedPaneID
        findRequestNonce &+= 1
    }

    func prepareSSHPaneIfNeeded(
        _ pane: MacWorkspacePane,
        sessionManager: SessionManager,
        settingsManager: SettingsManager
    ) async {
        guard !isClosed,
              pane.intent.kind == .ssh,
              let serverID = pane.intent.serverID,
              sessionsByPaneID[pane.id] == nil,
              !loadingPaneIDs.contains(pane.id),
              errorsByPaneID[pane.id] == nil else { return }

        let generation = lifecycleGeneration
        loadingPaneIDs.insert(pane.id)
        defer { loadingPaneIDs.remove(pane.id) }

        let startupCommand = claimStartupCommand(for: pane.id)?.command
        do {
            let launch = try await sessionManager.createAuthorizedSessionByServerID(
                serverID,
                settingsManager: settingsManager,
                startupCommand: startupCommand
            )
            guard !isClosed,
                  generation == lifecycleGeneration,
                  state.root?.pane(id: pane.id)?.intent == pane.intent else {
                sessionManager.closeSession(launch.session)
                return
            }
            if launch.session.state == .connected || launch.session.pendingHostKeyChallenge != nil {
                sessionsByPaneID[pane.id] = launch.session
            } else {
                if case .error(let message) = launch.session.state {
                    errorsByPaneID[pane.id] = message
                } else {
                    errorsByPaneID[pane.id] = "The SSH session ended before the pane opened."
                }
                sessionManager.closeSession(launch.session)
            }
        } catch {
            guard !isClosed,
                  generation == lifecycleGeneration,
                  state.root?.pane(id: pane.id)?.intent == pane.intent else { return }
            errorsByPaneID[pane.id] = error.localizedDescription
        }
    }

    func closeAllSessions(sessionManager: SessionManager) {
        isClosed = true
        lifecycleGeneration &+= 1
        let sessions = Array(sessionsByPaneID.values)
        sessionsByPaneID.removeAll()
        let localRuntimes = Array(localRuntimesByPaneID.values)
        localRuntimesByPaneID.removeAll()
        let recorders = Array(recordersByPaneID.values)
        recordersByPaneID.removeAll()
        loadingPaneIDs.removeAll()
        for ticketID in startupTicketIDsByPaneID.values {
            startupCommandBroker.discard(ticketID)
        }
        startupTicketIDsByPaneID.removeAll()
        for session in sessions {
            sessionManager.closeSession(session)
        }
        for runtime in localRuntimes {
            runtime.terminate()
        }
        for recorder in recorders {
            recorder.finalize()
        }
    }

    func claimStartupCommand(for paneID: UUID) -> TerminalStartupCommandTicket? {
        guard !isClosed,
              state.root?.pane(id: paneID) != nil,
              let ticketID = startupTicketIDsByPaneID.removeValue(forKey: paneID) else {
            return nil
        }
        return startupCommandBroker.claim(ticketID)
    }

    private func discardStartupCommand(for paneID: UUID) {
        guard let ticketID = startupTicketIDsByPaneID.removeValue(forKey: paneID) else { return }
        startupCommandBroker.discard(ticketID)
    }

    private func persist() {
        do {
            _ = try state.validated(for: state.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= Self.maximumEncodedBytes else {
                throw MacWorkspaceStateError.encodedStateTooLarge
            }
            defaults.set(data, forKey: Self.defaultsKey(for: state.id))
        } catch {
            Logger.settings.error(
                "Refusing to persist invalid workspace state: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Refusing to persist invalid workspace state: \(error)")
        }
    }

    private struct LoadResult {
        let state: MacWorkspaceRestorationState
        let hadRestorationData: Bool
    }

    private static func load(
        workspaceID: UUID,
        startsEmptyIfUnrestored: Bool,
        initialPaneIntent: MacWorkspacePaneIntent?,
        defaults: UserDefaults
    ) -> LoadResult {
        let key = defaultsKey(for: workspaceID)
        guard let data = defaults.data(forKey: key) else {
            let state: MacWorkspaceRestorationState
            if startsEmptyIfUnrestored {
                state = .empty(id: workspaceID)
            } else {
                state = MacWorkspaceRestorationState(
                    id: workspaceID,
                    initialIntent: initialPaneIntent ?? .local
                )
            }
            return LoadResult(state: state, hadRestorationData: false)
        }
        guard data.count <= maximumEncodedBytes else {
            return LoadResult(
                state: .empty(id: workspaceID),
                hadRestorationData: true
            )
        }
        do {
            let state = try JSONDecoder()
                .decode(MacWorkspaceRestorationState.self, from: data)
                .validated(for: workspaceID)
            return LoadResult(state: state, hadRestorationData: true)
        } catch {
            // Keep malformed or future-version data untouched for diagnosis,
            // but never execute a launch request that failed validation.
            return LoadResult(
                state: .empty(id: workspaceID),
                hadRestorationData: true
            )
        }
    }

    private static func defaultsKey(for workspaceID: UUID) -> String {
        "\(UserDefaultsKeys.macWorkspaceRestoration).\(workspaceID.uuidString.lowercased())"
    }
}

struct MacWorkspaceWindowIdentity: Equatable {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String?) {
        self.title = MacWorkspaceChromeText.sanitize(
            title,
            maximumLength: 160
        ) ?? "Terminal"
        self.subtitle = subtitle.flatMap {
            MacWorkspaceChromeText.sanitize($0, maximumLength: 240)
        }
    }
}

@MainActor
final class MacWorkspaceTransferBroker {
    static let shared = MacWorkspaceTransferBroker()
    static let defaultCapacity = 16
    static let defaultExpiration: Duration = .seconds(30)

    private struct Entry {
        let controller: MacWorkspaceController
        let expirationTask: Task<Void, Never>
        let commit: @MainActor (UUID) -> Bool
        let invalidate: @MainActor (UUID) -> Void
    }

    private let capacity: Int
    private let expiration: Duration
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    init(
        capacity: Int = defaultCapacity,
        expiration: Duration = defaultExpiration
    ) {
        self.capacity = max(1, capacity)
        self.expiration = expiration
    }

    var pendingCount: Int { entries.count }

    func issue(
        controller: MacWorkspaceController,
        commit: @escaping @MainActor (UUID) -> Bool,
        invalidate: @escaping @MainActor (UUID) -> Void
    ) -> UUID {
        while entries.count >= capacity, let oldest = order.first {
            self.invalidate(oldest)
        }
        let id = UUID()
        let expirationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.expiration)
            guard !Task.isCancelled else { return }
            self.invalidate(id)
        }
        entries[id] = Entry(
            controller: controller,
            expirationTask: expirationTask,
            commit: commit,
            invalidate: invalidate
        )
        order.append(id)
        return id
    }

    func claim(_ id: UUID) -> MacWorkspaceController? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        entry.expirationTask.cancel()
        guard !entry.controller.isClosed, entry.commit(id) else {
            entry.invalidate(id)
            return nil
        }
        return entry.controller
    }

    func discard(_ id: UUID) {
        invalidate(id)
    }

    private func invalidate(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        entry.expirationTask.cancel()
        entry.invalidate(id)
    }
}

@MainActor
@Observable
final class MacWorkspaceWindowController {
    private static let maximumEncodedBytes = 64 * 1024

    let windowID: UUID
    private(set) var tabs: [MacWorkspaceController]
    private(set) var selectedTabID: UUID

    private let defaults: UserDefaults
    private let startupCommandBroker: MacStartupCommandBroker
    private let liveSessionBroker: MacLiveSessionBroker
    private let transferBroker: MacWorkspaceTransferBroker
    private var pendingTransferTicketsByWorkspaceID: [UUID: UUID] = [:]

    init(
        request: MacWorkspaceLaunchRequest,
        startupCommandBroker: MacStartupCommandBroker = .shared,
        liveSessionBroker: MacLiveSessionBroker = .shared,
        transferBroker: MacWorkspaceTransferBroker = .shared,
        defaults: UserDefaults = .standard
    ) {
        windowID = request.windowID
        self.defaults = defaults
        self.startupCommandBroker = startupCommandBroker
        self.liveSessionBroker = liveSessionBroker
        self.transferBroker = transferBroker

        let resolvedTabs: [MacWorkspaceController]
        let resolvedSelectedTabID: UUID
        if let ticketID = request.transferredTabTicketID {
            if let transferred = transferBroker.claim(ticketID) {
                resolvedTabs = [transferred]
                resolvedSelectedTabID = transferred.workspaceID
            } else {
                let fallback = MacWorkspaceController(
                    request: MacWorkspaceTabRequest(
                        workspaceID: UUID(),
                        startsEmpty: true
                    ),
                    startupCommandBroker: startupCommandBroker,
                    liveSessionBroker: liveSessionBroker,
                    defaults: defaults
                )
                resolvedTabs = [fallback]
                resolvedSelectedTabID = fallback.workspaceID
            }
        } else if let restored = Self.load(windowID: request.windowID, defaults: defaults) {
            resolvedTabs = restored.tabs.map {
                MacWorkspaceController(
                    request: $0.request,
                    startupCommandBroker: startupCommandBroker,
                    liveSessionBroker: liveSessionBroker,
                    defaults: defaults
                )
            }
            resolvedSelectedTabID = restored.selectedTabID
        } else if defaults.object(
            forKey: Self.defaultsKey(for: request.windowID)
        ) != nil {
            let fallback = MacWorkspaceController(
                request: MacWorkspaceTabRequest(
                    workspaceID: UUID(),
                    startsEmpty: true
                ),
                startupCommandBroker: startupCommandBroker,
                liveSessionBroker: liveSessionBroker,
                defaults: defaults
            )
            resolvedTabs = [fallback]
            resolvedSelectedTabID = fallback.workspaceID
        } else {
            resolvedTabs = request.tabs.map {
                MacWorkspaceController(
                    request: $0,
                    startupCommandBroker: startupCommandBroker,
                    liveSessionBroker: liveSessionBroker,
                    defaults: defaults
                )
            }
            resolvedSelectedTabID = resolvedTabs[0].workspaceID
        }
        tabs = resolvedTabs
        selectedTabID = resolvedSelectedTabID
        persist()
    }

    var selectedTab: MacWorkspaceController {
        tabs.first(where: { $0.workspaceID == selectedTabID }) ?? tabs[0]
    }

    var isEmpty: Bool {
        tabs.allSatisfy(\.isEmpty)
    }
    var canAddTab: Bool {
        tabs.count < MacWorkspaceWindowRestorationState.maximumTabCount
    }
    var canTransferSelectedTab: Bool {
        tabs.count > 1
            && pendingTransferTicketsByWorkspaceID[selectedTabID] == nil
    }

    func select(_ workspaceID: UUID) {
        guard tabs.contains(where: { $0.workspaceID == workspaceID }) else { return }
        selectedTabID = workspaceID
        persist()
    }

    @discardableResult
    func addTab(_ request: MacWorkspaceTabRequest = MacWorkspaceTabRequest(startsEmpty: true))
        -> MacWorkspaceController?
    {
        guard canAddTab else { return nil }
        let controller = MacWorkspaceController(
            request: request,
            startupCommandBroker: startupCommandBroker,
            liveSessionBroker: liveSessionBroker,
            defaults: defaults
        )
        tabs.append(controller)
        selectedTabID = controller.workspaceID
        persist()
        return controller
    }

    @discardableResult
    func removeTab(
        _ workspaceID: UUID,
        sessionManager: SessionManager,
        closeSessions: Bool = true
    ) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.workspaceID == workspaceID }) else {
            return false
        }
        if tabs.count == 1 {
            cancelPendingTransfer(for: workspaceID)
            if closeSessions {
                tabs[0].closeAllSessions(sessionManager: sessionManager)
            }
            defaults.removeObject(forKey: Self.defaultsKey(for: windowID))
            return true
        }
        cancelPendingTransfer(for: workspaceID)
        let controller = tabs.remove(at: index)
        if closeSessions {
            controller.closeAllSessions(sessionManager: sessionManager)
        }
        guard !tabs.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey(for: windowID))
            return true
        }
        if selectedTabID == workspaceID {
            selectedTabID = tabs[min(index, tabs.count - 1)].workspaceID
        }
        persist()
        return false
    }

    func transferSelectedTab() -> MacWorkspaceLaunchRequest? {
        guard canTransferSelectedTab else { return nil }
        let controller = selectedTab
        let ticketID = transferBroker.issue(
            controller: controller,
            commit: { [weak self] ticketID in
                self?.commitTransfer(
                    controller.workspaceID,
                    ticketID: ticketID
                ) ?? false
            },
            invalidate: { [weak self] ticketID in
                self?.invalidateTransfer(
                    controller.workspaceID,
                    ticketID: ticketID
                )
            }
        )
        pendingTransferTicketsByWorkspaceID[controller.workspaceID] = ticketID
        return MacWorkspaceLaunchRequest(
            windowID: UUID(),
            tabs: [controller.restorationDescriptor.request],
            transferredTabTicketID: ticketID
        )
    }

    func closeAllSessions(sessionManager: SessionManager) {
        let pendingTickets = Array(pendingTransferTicketsByWorkspaceID.values)
        for ticketID in pendingTickets {
            transferBroker.discard(ticketID)
        }
        pendingTransferTicketsByWorkspaceID.removeAll()
        for tab in tabs {
            tab.closeAllSessions(sessionManager: sessionManager)
        }
    }

    private func commitTransfer(_ workspaceID: UUID, ticketID: UUID) -> Bool {
        guard pendingTransferTicketsByWorkspaceID[workspaceID] == ticketID else {
            return false
        }
        guard let index = tabs.firstIndex(where: { $0.workspaceID == workspaceID }),
              tabs.count > 1 else {
            pendingTransferTicketsByWorkspaceID.removeValue(forKey: workspaceID)
            return false
        }
        pendingTransferTicketsByWorkspaceID.removeValue(forKey: workspaceID)
        tabs.remove(at: index)
        if selectedTabID == workspaceID {
            selectedTabID = tabs[min(index, tabs.count - 1)].workspaceID
        }
        persist()
        return true
    }

    private func invalidateTransfer(_ workspaceID: UUID, ticketID: UUID) {
        guard pendingTransferTicketsByWorkspaceID[workspaceID] == ticketID else {
            return
        }
        pendingTransferTicketsByWorkspaceID.removeValue(forKey: workspaceID)
    }

    private func cancelPendingTransfer(for workspaceID: UUID) {
        guard let ticketID = pendingTransferTicketsByWorkspaceID[workspaceID] else {
            return
        }
        transferBroker.discard(ticketID)
    }

    private func persist() {
        let state = MacWorkspaceWindowRestorationState(
            tabs: tabs.map(\.restorationDescriptor),
            selectedTabID: selectedTabID
        )
        guard state.validated() != nil,
              let data = try? JSONEncoder().encode(state),
              data.count <= Self.maximumEncodedBytes else {
            assertionFailure("Refusing to persist invalid macOS window tabs")
            return
        }
        defaults.set(data, forKey: Self.defaultsKey(for: windowID))
    }

    private static func load(
        windowID: UUID,
        defaults: UserDefaults
    ) -> MacWorkspaceWindowRestorationState? {
        guard let data = defaults.data(forKey: defaultsKey(for: windowID)),
              data.count <= maximumEncodedBytes,
              let state = try? JSONDecoder().decode(
                MacWorkspaceWindowRestorationState.self,
                from: data
              ) else {
            return nil
        }
        return state.validated()
    }

    private static func defaultsKey(for windowID: UUID) -> String {
        "\(UserDefaultsKeys.macWorkspaceRestoration).window.\(windowID.uuidString.lowercased())"
    }
}
#endif
