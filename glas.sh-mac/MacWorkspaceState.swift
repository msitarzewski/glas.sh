import Foundation

enum MacWorkspaceSplitAxis: String, Codable, CaseIterable, Hashable, Sendable {
    case horizontal
    case vertical
}

/// A restorable request to create a fresh pane. It deliberately contains only
/// endpoint identity. Credentials, prepared authentication, PTY handles, and
/// live connection state never enter workspace restoration data.
struct MacWorkspacePaneIntent: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    enum Kind: String, Codable, Hashable, Sendable {
        case local
        case ssh
    }

    let schemaVersion: Int
    let kind: Kind
    let serverID: UUID?

    static let local = MacWorkspacePaneIntent(kind: .local, serverID: nil)

    static func ssh(serverID: UUID) -> MacWorkspacePaneIntent {
        MacWorkspacePaneIntent(kind: .ssh, serverID: serverID)
    }

    private init(kind: Kind, serverID: UUID?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.serverID = serverID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MacWorkspaceStateError.unsupportedPaneIntentVersion(schemaVersion)
        }
        let kind = try container.decode(Kind.self, forKey: .kind)
        let serverID = try container.decodeIfPresent(UUID.self, forKey: .serverID)
        guard (kind == .local && serverID == nil) || (kind == .ssh && serverID != nil) else {
            throw MacWorkspaceStateError.invalidPaneIntent
        }
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.serverID = serverID
    }
}

struct MacWorkspacePane: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var intent: MacWorkspacePaneIntent

    init(id: UUID = UUID(), intent: MacWorkspacePaneIntent) {
        self.id = id
        self.intent = intent
    }
}

struct MacWorkspaceSplit: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var axis: MacWorkspaceSplitAxis
    var fraction: Double
    var first: MacWorkspaceNode
    var second: MacWorkspaceNode

    init(
        id: UUID = UUID(),
        axis: MacWorkspaceSplitAxis,
        fraction: Double = 0.5,
        first: MacWorkspaceNode,
        second: MacWorkspaceNode
    ) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

indirect enum MacWorkspaceNode: Codable, Hashable, Sendable {
    case pane(MacWorkspacePane)
    case split(MacWorkspaceSplit)

    var id: UUID {
        switch self {
        case .pane(let pane): pane.id
        case .split(let split): split.id
        }
    }

    var paneIDs: [UUID] {
        switch self {
        case .pane(let pane):
            [pane.id]
        case .split(let split):
            split.first.paneIDs + split.second.paneIDs
        }
    }

    var panes: [MacWorkspacePane] {
        switch self {
        case .pane(let pane):
            [pane]
        case .split(let split):
            split.first.panes + split.second.panes
        }
    }

    func pane(id: UUID) -> MacWorkspacePane? {
        switch self {
        case .pane(let pane):
            pane.id == id ? pane : nil
        case .split(let split):
            split.first.pane(id: id) ?? split.second.pane(id: id)
        }
    }

    func splittingPane(
        id paneID: UUID,
        axis: MacWorkspaceSplitAxis,
        newPane: MacWorkspacePane
    ) -> MacWorkspaceNode {
        switch self {
        case .pane(let pane) where pane.id == paneID:
            return .split(MacWorkspaceSplit(
                axis: axis,
                first: .pane(pane),
                second: .pane(newPane)
            ))
        case .pane:
            return self
        case .split(var split):
            split.first = split.first.splittingPane(id: paneID, axis: axis, newPane: newPane)
            if !split.first.paneIDs.contains(newPane.id) {
                split.second = split.second.splittingPane(id: paneID, axis: axis, newPane: newPane)
            }
            return .split(split)
        }
    }

    func removingPane(id paneID: UUID) -> MacWorkspaceNode? {
        switch self {
        case .pane(let pane):
            return pane.id == paneID ? nil : self
        case .split(let split):
            let first = split.first.removingPane(id: paneID)
            let second = split.second.removingPane(id: paneID)
            switch (first, second) {
            case (.none, .none): return nil
            case (.some(let survivor), .none), (.none, .some(let survivor)): return survivor
            case (.some(let first), .some(let second)):
                return .split(MacWorkspaceSplit(
                    id: split.id,
                    axis: split.axis,
                    fraction: split.fraction,
                    first: first,
                    second: second
                ))
            }
        }
    }

    func updatingSplitFraction(id splitID: UUID, fraction: Double) -> MacWorkspaceNode {
        switch self {
        case .pane:
            return self
        case .split(var split):
            if split.id == splitID {
                split.fraction = min(0.9, max(0.1, fraction))
            } else {
                split.first = split.first.updatingSplitFraction(id: splitID, fraction: fraction)
                split.second = split.second.updatingSplitFraction(id: splitID, fraction: fraction)
            }
            return .split(split)
        }
    }
}

struct MacWorkspaceRestorationState: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumPaneCount = 32
    static let maximumDepth = 12

    let schemaVersion: Int
    let id: UUID
    var root: MacWorkspaceNode?
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), initialIntent: MacWorkspacePaneIntent = .local) {
        let pane = MacWorkspacePane(intent: initialIntent)
        self.init(id: id, root: .pane(pane), focusedPaneID: pane.id)
    }

    static func empty(id: UUID = UUID()) -> MacWorkspaceRestorationState {
        MacWorkspaceRestorationState(id: id, root: nil, focusedPaneID: nil)
    }

    private init(id: UUID, root: MacWorkspaceNode?, focusedPaneID: UUID?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.root = root
        self.focusedPaneID = focusedPaneID
    }

    func validated(for expectedID: UUID? = nil) throws -> MacWorkspaceRestorationState {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MacWorkspaceStateError.unsupportedWorkspaceVersion(schemaVersion)
        }
        guard expectedID == nil || expectedID == id else {
            throw MacWorkspaceStateError.workspaceIdentityMismatch
        }
        guard let root else {
            guard focusedPaneID == nil else { throw MacWorkspaceStateError.invalidFocus }
            return self
        }

        var nodeIDs = Set<UUID>()
        var paneIDs = Set<UUID>()
        try Self.validate(
            root,
            depth: 1,
            nodeIDs: &nodeIDs,
            paneIDs: &paneIDs
        )
        guard paneIDs.count <= Self.maximumPaneCount else {
            throw MacWorkspaceStateError.tooManyPanes
        }
        guard focusedPaneID == nil || paneIDs.contains(focusedPaneID!) else {
            throw MacWorkspaceStateError.invalidFocus
        }
        return self
    }

    private static func validate(
        _ node: MacWorkspaceNode,
        depth: Int,
        nodeIDs: inout Set<UUID>,
        paneIDs: inout Set<UUID>
    ) throws {
        guard depth <= maximumDepth else { throw MacWorkspaceStateError.tooDeep }
        guard nodeIDs.insert(node.id).inserted else {
            throw MacWorkspaceStateError.duplicateNodeIdentity
        }
        switch node {
        case .pane(let pane):
            guard paneIDs.insert(pane.id).inserted else {
                throw MacWorkspaceStateError.duplicatePaneIdentity
            }
            _ = try JSONDecoder().decode(
                MacWorkspacePaneIntent.self,
                from: JSONEncoder().encode(pane.intent)
            )
        case .split(let split):
            guard split.fraction.isFinite, (0.1...0.9).contains(split.fraction) else {
                throw MacWorkspaceStateError.invalidSplitFraction
            }
            try validate(split.first, depth: depth + 1, nodeIDs: &nodeIDs, paneIDs: &paneIDs)
            try validate(split.second, depth: depth + 1, nodeIDs: &nodeIDs, paneIDs: &paneIDs)
        }
    }
}

struct MacWorkspaceLaunchRequest: Codable, Hashable, Sendable {
    let workspaceID: UUID
    let startsEmpty: Bool

    init(workspaceID: UUID = UUID(), startsEmpty: Bool = false) {
        self.workspaceID = workspaceID
        self.startsEmpty = startsEmpty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        // Requests restored from builds predating the launcher retain their
        // original initial-local-terminal behavior.
        startsEmpty = try container.decodeIfPresent(Bool.self, forKey: .startsEmpty) ?? false
    }
}

enum MacWorkspaceStateError: LocalizedError, Equatable {
    case unsupportedWorkspaceVersion(Int)
    case unsupportedPaneIntentVersion(Int)
    case workspaceIdentityMismatch
    case invalidPaneIntent
    case invalidSplitFraction
    case duplicateNodeIdentity
    case duplicatePaneIdentity
    case invalidFocus
    case tooManyPanes
    case tooDeep
    case encodedStateTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedWorkspaceVersion:
            "This workspace was saved by an unsupported version of glas.sh."
        case .unsupportedPaneIntentVersion:
            "A terminal pane was saved by an unsupported version of glas.sh."
        case .workspaceIdentityMismatch:
            "The saved workspace identity does not match this window."
        case .invalidPaneIntent:
            "A saved terminal pane contains an invalid launch request."
        case .invalidSplitFraction:
            "A saved workspace has an invalid split position."
        case .duplicateNodeIdentity, .duplicatePaneIdentity:
            "A saved workspace contains duplicate pane identifiers."
        case .invalidFocus:
            "A saved workspace refers to a pane that no longer exists."
        case .tooManyPanes:
            "The saved workspace contains too many panes."
        case .tooDeep:
            "The saved workspace split layout is too deeply nested."
        case .encodedStateTooLarge:
            "The saved workspace exceeds the supported size."
        }
    }
}
