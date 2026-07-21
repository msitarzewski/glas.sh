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
        if let focusedPaneID, !paneIDs.contains(focusedPaneID) {
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
    static let maximumDisplayTextLength = 80

    let workspaceID: UUID
    let startsEmpty: Bool
    let initialPaneIntent: MacWorkspacePaneIntent?
    let workgroupID: UUID?
    let workgroupName: String?
    let workgroupColor: ServerColorTag?
    let tabLabel: String?
    /// An opaque lookup key for runtime-only command data. The command itself
    /// is deliberately absent from this Codable launch request.
    let startupTicketID: UUID?
    /// An opaque lookup key for a runtime-only session that was authenticated
    /// before its workspace opened. Live session state is never Codable.
    let liveSessionTicketID: UUID?

    init(
        workspaceID: UUID = UUID(),
        startsEmpty: Bool = false,
        initialPaneIntent: MacWorkspacePaneIntent? = nil,
        workgroupID: UUID? = nil,
        workgroupName: String? = nil,
        workgroupColor: ServerColorTag? = nil,
        tabLabel: String? = nil,
        startupTicketID: UUID? = nil,
        liveSessionTicketID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.startsEmpty = startsEmpty
        self.initialPaneIntent = initialPaneIntent
        self.workgroupID = workgroupID
        self.workgroupName = Self.normalizedDisplayText(workgroupName)
        self.workgroupColor = workgroupColor
        self.tabLabel = Self.normalizedDisplayText(tabLabel)
        self.startupTicketID = startupTicketID
        self.liveSessionTicketID = liveSessionTicketID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        // Requests restored from builds predating the launcher retain their
        // original initial-local-terminal behavior.
        startsEmpty = try container.decodeIfPresent(Bool.self, forKey: .startsEmpty) ?? false
        initialPaneIntent = try container.decodeIfPresent(
            MacWorkspacePaneIntent.self,
            forKey: .initialPaneIntent
        )
        workgroupID = try container.decodeIfPresent(UUID.self, forKey: .workgroupID)
        workgroupName = Self.normalizedDisplayText(
            try container.decodeIfPresent(String.self, forKey: .workgroupName)
        )
        workgroupColor = try container.decodeIfPresent(ServerColorTag.self, forKey: .workgroupColor)
        tabLabel = Self.normalizedDisplayText(
            try container.decodeIfPresent(String.self, forKey: .tabLabel)
        )
        startupTicketID = try container.decodeIfPresent(UUID.self, forKey: .startupTicketID)
        liveSessionTicketID = try container.decodeIfPresent(UUID.self, forKey: .liveSessionTicketID)
    }

    private static func normalizedDisplayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.utf8.contains(0) else { return nil }
        return String(normalized.prefix(maximumDisplayTextLength))
    }
}

struct MacWorkgroupLaunchItem: Hashable, Sendable {
    let intent: MacWorkspacePaneIntent
    let label: String
    let startupCommand: String?

    init(intent: MacWorkspacePaneIntent, label: String, startupCommand: String? = nil) {
        self.intent = intent
        self.label = label
        self.startupCommand = TerminalStartupCommandTicket(command: startupCommand)?.command
    }
}

/// Runtime-only command rendezvous for macOS window launches. Main-actor
/// isolation makes issuing and claiming atomic, and the bounded FIFO prevents
/// abandoned WindowGroup requests from accumulating indefinitely.
@MainActor
final class MacStartupCommandBroker {
    static let shared = MacStartupCommandBroker()
    static let defaultCapacity = 64
    static let defaultExpiration: Duration = .seconds(60)

    private struct Entry {
        let ticket: TerminalStartupCommandTicket
        let expirationTask: Task<Void, Never>
    }

    private let capacity: Int
    private let expiration: Duration
    private var entriesByID: [UUID: Entry] = [:]
    private var insertionOrder: [UUID] = []

    init(
        capacity: Int = defaultCapacity,
        expiration: Duration = defaultExpiration
    ) {
        self.capacity = max(1, capacity)
        self.expiration = max(.milliseconds(1), expiration)
    }

    var pendingCount: Int { entriesByID.count }

    func issue(command: String?) -> UUID? {
        guard let ticket = TerminalStartupCommandTicket(command: command) else { return nil }
        while entriesByID.count >= capacity, let oldest = insertionOrder.first {
            discard(oldest)
        }
        let id = ticket.id
        let expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.expiration ?? .zero)
            } catch {
                return
            }
            self?.discard(id)
        }
        entriesByID[id] = Entry(ticket: ticket, expirationTask: expirationTask)
        insertionOrder.append(ticket.id)
        return ticket.id
    }

    func claim(_ id: UUID) -> TerminalStartupCommandTicket? {
        insertionOrder.removeAll { $0 == id }
        guard let entry = entriesByID.removeValue(forKey: id) else { return nil }
        entry.expirationTask.cancel()
        return entry.ticket
    }

    func discard(_ id: UUID) {
        _ = claim(id)
    }
}

/// A single-use, runtime-only rendezvous for sessions authenticated before a
/// macOS workspace opens. The request carries only the opaque ticket UUID.
/// Abandoned tickets are bounded and close their sessions when evicted.
@MainActor
final class MacLiveSessionBroker {
    struct Ticket {
        let session: TerminalSession
        private let discardHandler: @MainActor () -> Void

        init(
            session: TerminalSession,
            discardHandler: @escaping @MainActor () -> Void
        ) {
            self.session = session
            self.discardHandler = discardHandler
        }

        func discard() {
            discardHandler()
        }
    }

    static let shared = MacLiveSessionBroker()
    static let defaultCapacity = 32
    static let defaultExpiration: Duration = .seconds(60)

    private struct Entry {
        let ticket: Ticket
        let expirationTask: Task<Void, Never>
    }

    private let capacity: Int
    private let expiration: Duration
    private var entriesByID: [UUID: Entry] = [:]
    private var insertionOrder: [UUID] = []

    init(
        capacity: Int = defaultCapacity,
        expiration: Duration = defaultExpiration
    ) {
        self.capacity = max(1, capacity)
        self.expiration = max(.milliseconds(1), expiration)
    }

    var pendingCount: Int { entriesByID.count }

    func issue(
        session: TerminalSession,
        discardHandler: @escaping @MainActor () -> Void
    ) -> UUID {
        while entriesByID.count >= capacity, let oldest = insertionOrder.first {
            discard(oldest)
        }
        let id = UUID()
        let expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.expiration ?? .zero)
            } catch {
                return
            }
            self?.discard(id)
        }
        entriesByID[id] = Entry(
            ticket: Ticket(session: session, discardHandler: discardHandler),
            expirationTask: expirationTask
        )
        insertionOrder.append(id)
        return id
    }

    func claim(_ id: UUID) -> Ticket? {
        insertionOrder.removeAll { $0 == id }
        guard let entry = entriesByID.removeValue(forKey: id) else { return nil }
        entry.expirationTask.cancel()
        return entry.ticket
    }

    func discard(_ id: UUID) {
        claim(id)?.discard()
    }
}

@MainActor
enum MacLiveSessionWorkspaceRouter {
    static func launchRequest(
        for session: TerminalSession,
        sessionManager: SessionManager,
        broker: MacLiveSessionBroker = .shared
    ) -> MacWorkspaceLaunchRequest {
        let ticketID = broker.issue(session: session) { [weak sessionManager, weak session] in
            guard let sessionManager, let session else { return }
            sessionManager.closeSession(session)
        }
        return MacWorkspaceLaunchRequest(
            initialPaneIntent: .ssh(serverID: session.server.id),
            liveSessionTicketID: ticketID
        )
    }
}

/// Builds one native-tab macOS terminal window from an ordered workgroup.
/// Callers remain responsible for filtering unavailable servers before launch.
@MainActor
enum MacWorkgroupLauncher {
    @discardableResult
    static func launch(
        workgroupID: UUID,
        name: String,
        color: ServerColorTag,
        items: [MacWorkgroupLaunchItem],
        broker: MacStartupCommandBroker = .shared,
        openWindow: (MacWorkspaceLaunchRequest) -> Void
    ) -> [MacWorkspaceLaunchRequest] {
        let boundedItems = Array(items.prefix(MacWorkspaceRestorationState.maximumPaneCount))
        let requests = boundedItems.map { item in
            MacWorkspaceLaunchRequest(
                initialPaneIntent: item.intent,
                workgroupID: workgroupID,
                workgroupName: name,
                workgroupColor: color,
                tabLabel: item.label,
                startupTicketID: broker.issue(command: item.startupCommand)
            )
        }
        MacWorkspaceWindowRegistry.shared.prepareTabBatch(
            workspaceIDs: requests.map(\.workspaceID)
        )
        requests.forEach(openWindow)
        return requests
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
