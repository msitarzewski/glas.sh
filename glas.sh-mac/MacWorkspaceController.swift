import Foundation
import Observation
import os

@MainActor
@Observable
final class MacWorkspaceController {
    private static let maximumEncodedBytes = 128 * 1024

    private(set) var state: MacWorkspaceRestorationState
    private(set) var sessionsByPaneID: [UUID: TerminalSession] = [:]
    private(set) var loadingPaneIDs: Set<UUID> = []
    private(set) var errorsByPaneID: [UUID: String] = [:]
    private(set) var findTargetPaneID: UUID?
    private(set) var findRequestNonce: UInt64 = 0
    private(set) var isClosed = false
    var pendingSSHAxis: MacWorkspaceSplitAxis?

    private let defaults: UserDefaults
    private var lifecycleGeneration: UInt64 = 0

    init(
        workspaceID: UUID,
        startsEmptyIfUnrestored: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.state = Self.load(
            workspaceID: workspaceID,
            startsEmptyIfUnrestored: startsEmptyIfUnrestored,
            defaults: defaults
        )
    }

    var workspaceID: UUID { state.id }
    var focusedPaneID: UUID? { state.focusedPaneID }
    var focusedPane: MacWorkspacePane? {
        guard let focusedPaneID else { return nil }
        return state.root?.pane(id: focusedPaneID)
    }

    var isEmpty: Bool { state.root == nil }
    var canAddPane: Bool {
        (state.root?.paneIDs.count ?? 0) < MacWorkspaceRestorationState.maximumPaneCount
    }

    func session(for paneID: UUID) -> TerminalSession? {
        sessionsByPaneID[paneID]
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

        do {
            let launch = try await sessionManager.createAuthorizedSessionByServerID(
                serverID,
                settingsManager: settingsManager
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
        loadingPaneIDs.removeAll()
        for session in sessions {
            sessionManager.closeSession(session)
        }
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

    private static func load(
        workspaceID: UUID,
        startsEmptyIfUnrestored: Bool,
        defaults: UserDefaults
    ) -> MacWorkspaceRestorationState {
        let key = defaultsKey(for: workspaceID)
        guard let data = defaults.data(forKey: key) else {
            return startsEmptyIfUnrestored
                ? MacWorkspaceRestorationState.empty(id: workspaceID)
                : MacWorkspaceRestorationState(id: workspaceID)
        }
        guard data.count <= maximumEncodedBytes else {
            return MacWorkspaceRestorationState(id: workspaceID)
        }
        do {
            return try JSONDecoder()
                .decode(MacWorkspaceRestorationState.self, from: data)
                .validated(for: workspaceID)
        } catch {
            // Keep malformed or future-version data untouched for diagnosis,
            // but never execute a launch request that failed validation.
            return MacWorkspaceRestorationState(id: workspaceID)
        }
    }

    private static func defaultsKey(for workspaceID: UUID) -> String {
        "\(UserDefaultsKeys.macWorkspaceRestoration).\(workspaceID.uuidString.lowercased())"
    }
}
