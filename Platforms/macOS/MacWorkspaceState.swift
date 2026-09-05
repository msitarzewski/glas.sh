#if os(macOS)
import Foundation

enum MacWorkspaceChromeText {
    static func sanitize(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let safeScalars = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || isBidirectionalControl(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        let singleLine = safeScalars
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(maximumLength))
    }

    private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            false
        }
    }
}

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
    var localShell: String? = nil
    var localDirectory: String? = nil
    var label: String? = nil
    var sourceSessionIndex: Int? = nil

    static let local = MacWorkspacePaneIntent(kind: .local, serverID: nil)
    static func local(shell: String?, directory: String?) -> Self {
        var intent = Self.local
        intent.localShell = shell
        intent.localDirectory = directory
        return intent
    }

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
        self.localShell = try container.decodeIfPresent(String.self, forKey: .localShell)
        self.localDirectory = try container.decodeIfPresent(String.self, forKey: .localDirectory)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.sourceSessionIndex = try container.decodeIfPresent(Int.self, forKey: .sourceSessionIndex)
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

struct MacWorkspaceTabRequest: Codable, Hashable, Sendable, Identifiable {
    static let maximumDisplayTextLength = 80

    var id: UUID { workspaceID }
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
    var initialState: MacWorkspaceRestorationState? = nil
    var paneStartupTicketIDs: [UUID: UUID]? = nil

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
        initialState = try container.decodeIfPresent(MacWorkspaceRestorationState.self, forKey: .initialState)?.validated(for: workspaceID)
        paneStartupTicketIDs = try container.decodeIfPresent([UUID: UUID].self, forKey: .paneStartupTicketIDs)
    }

    private static func normalizedDisplayText(_ value: String?) -> String? {
        MacWorkspaceChromeText.sanitize(
            value,
            maximumLength: maximumDisplayTextLength
        )
    }
}

struct MacWorkspaceLaunchRequest: Codable, Hashable, Sendable {
    let windowID: UUID
    let tabs: [MacWorkspaceTabRequest]
    /// Opaque runtime handoff for “Move Tab to New Window.” The controller and
    /// its live sessions never enter the Codable scene value.
    let transferredTabTicketID: UUID?
    var initialSelectedTabID: UUID? = nil

    var workspaceID: UUID { tabs[0].workspaceID }
    var startsEmpty: Bool { tabs[0].startsEmpty }
    var initialPaneIntent: MacWorkspacePaneIntent? { tabs[0].initialPaneIntent }
    var workgroupID: UUID? { tabs[0].workgroupID }
    var workgroupName: String? { tabs[0].workgroupName }
    var workgroupColor: ServerColorTag? { tabs[0].workgroupColor }
    var tabLabel: String? { tabs[0].tabLabel }
    var startupTicketID: UUID? { tabs[0].startupTicketID }
    var liveSessionTicketID: UUID? { tabs[0].liveSessionTicketID }

    init(
        windowID: UUID = UUID(),
        tabs: [MacWorkspaceTabRequest],
        transferredTabTicketID: UUID? = nil
    ) {
        let bounded = Array(
            tabs.prefix(MacWorkspaceWindowRestorationState.maximumTabCount)
        )
        self.windowID = windowID
        self.tabs = bounded.isEmpty ? [MacWorkspaceTabRequest(startsEmpty: true)] : bounded
        self.transferredTabTicketID = transferredTabTicketID
    }

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
        self.init(
            windowID: workspaceID,
            tabs: [
                MacWorkspaceTabRequest(
                    workspaceID: workspaceID,
                    startsEmpty: startsEmpty,
                    initialPaneIntent: initialPaneIntent,
                    workgroupID: workgroupID,
                    workgroupName: workgroupName,
                    workgroupColor: workgroupColor,
                    tabLabel: tabLabel,
                    startupTicketID: startupTicketID,
                    liveSessionTicketID: liveSessionTicketID
                )
            ]
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.tabs), try !container.decodeNil(forKey: .tabs) {
            var tabContainer = try container.nestedUnkeyedContainer(forKey: .tabs)
            if let count = tabContainer.count,
               count > MacWorkspaceWindowRestorationState.maximumTabCount {
                throw DecodingError.dataCorruptedError(
                    forKey: .tabs,
                    in: container,
                    debugDescription: "A workspace window may contain at most \(MacWorkspaceWindowRestorationState.maximumTabCount) tabs."
                )
            }
            var decodedTabs: [MacWorkspaceTabRequest] = []
            decodedTabs.reserveCapacity(
                min(
                    tabContainer.count ?? MacWorkspaceWindowRestorationState.maximumTabCount,
                    MacWorkspaceWindowRestorationState.maximumTabCount
                )
            )
            while !tabContainer.isAtEnd {
                guard decodedTabs.count < MacWorkspaceWindowRestorationState.maximumTabCount else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .tabs,
                        in: container,
                        debugDescription: "A workspace window may contain at most \(MacWorkspaceWindowRestorationState.maximumTabCount) tabs."
                    )
                }
                decodedTabs.append(try tabContainer.decode(MacWorkspaceTabRequest.self))
            }
            guard !decodedTabs.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tabs,
                    in: container,
                    debugDescription: "A workspace window requires at least one tab."
                )
            }
            windowID = try container.decodeIfPresent(UUID.self, forKey: .windowID)
                ?? decodedTabs[0].workspaceID
            tabs = decodedTabs
            initialSelectedTabID = try container.decodeIfPresent(UUID.self, forKey: .initialSelectedTabID)
            transferredTabTicketID = try container.decodeIfPresent(
                UUID.self,
                forKey: .transferredTabTicketID
            )
            return
        }

        // Decode scene values created before one-window model-owned tabs.
        let legacyTab = try MacWorkspaceTabRequest(from: decoder)
        windowID = legacyTab.workspaceID
        tabs = [legacyTab]
        transferredTabTicketID = nil
    }
}

struct MacWorkspaceTabDescriptor: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let workgroupID: UUID?
    let workgroupName: String?
    let workgroupColor: ServerColorTag?
    let tabLabel: String?

    init(_ request: MacWorkspaceTabRequest) {
        id = request.workspaceID
        workgroupID = request.workgroupID
        workgroupName = request.workgroupName
        workgroupColor = request.workgroupColor
        tabLabel = request.tabLabel
    }

    var request: MacWorkspaceTabRequest {
        MacWorkspaceTabRequest(
            workspaceID: id,
            workgroupID: workgroupID,
            workgroupName: workgroupName,
            workgroupColor: workgroupColor,
            tabLabel: tabLabel
        )
    }
}

struct MacWorkspaceWindowRestorationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumTabCount = 32

    let schemaVersion: Int
    let tabs: [MacWorkspaceTabDescriptor]
    let selectedTabID: UUID

    init(tabs: [MacWorkspaceTabDescriptor], selectedTabID: UUID) {
        schemaVersion = Self.currentSchemaVersion
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    func validated() -> MacWorkspaceWindowRestorationState? {
        guard schemaVersion == Self.currentSchemaVersion,
              !tabs.isEmpty,
              tabs.count <= Self.maximumTabCount,
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.contains(where: { $0.id == selectedTabID }) else {
            return nil
        }
        return self
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

/// Builds one model-owned tabbed macOS terminal window from an ordered workgroup.
/// Callers remain responsible for filtering unavailable servers before launch.
@MainActor
enum MacWorkgroupLauncher {
    @discardableResult
    static func launch(
        preset: LayoutPreset,
        broker: MacStartupCommandBroker = .shared,
        openWindow: (MacWorkspaceLaunchRequest) -> Void
    ) throws -> [MacWorkspaceLaunchRequest] {
        let preset = preset.migratedToCurrentSchema()
        guard preset.isValidForPersistence else { throw MacWorkspaceStateError.invalidPaneIntent }
        let layout = preset.workspaceLayout ?? LayoutPreset.WorkspaceLayout(
            tabs: preset.sessionIntents.indices.map {
                .init(label: preset.sessionIntents[$0].label, root: .session($0), focusedSessionIndex: $0)
            }, selectedTabIndex: 0
        )
        var requests: [MacWorkspaceTabRequest] = []
        for tab in layout.tabs {
            var paneIDs: [Int: UUID] = [:]
            var tickets: [UUID: UUID] = [:]
            func convert(_ node: LayoutPreset.WorkspaceLayout.Node) -> MacWorkspaceNode {
                switch node {
                case .session(let index):
                    let item = preset.sessionIntents[index]
                    var intent: MacWorkspacePaneIntent = item.kind == .local
                        ? .local(shell: item.localShell, directory: item.localDirectory)
                        : .ssh(serverID: item.serverID!)
                    intent.label = item.label
                    intent.sourceSessionIndex = index
                    let pane = MacWorkspacePane(intent: intent)
                    paneIDs[index] = pane.id
                    tickets[pane.id] = broker.issue(command: item.startupCommand)
                    return .pane(pane)
                case let .split(axis, fraction, first, second):
                    return .split(.init(axis: axis == .horizontal ? .horizontal : .vertical,
                                        fraction: fraction, first: convert(first), second: convert(second)))
                }
            }
            var state = MacWorkspaceRestorationState.empty()
            state.root = convert(tab.root)
            state.focusedPaneID = paneIDs[tab.focusedSessionIndex]
            var request = MacWorkspaceTabRequest(workspaceID: state.id, workgroupID: preset.id,
                                                workgroupName: preset.name, workgroupColor: preset.colorTag,
                                                tabLabel: tab.label)
            request.initialState = state
            request.paneStartupTicketIDs = tickets
            requests.append(request)
        }
        var request = MacWorkspaceLaunchRequest(tabs: requests)
        request.initialSelectedTabID = requests[layout.selectedTabIndex].workspaceID
        openWindow(request)
        return [request]
    }

    @discardableResult
    static func launch(
        workgroupID: UUID,
        name: String,
        color: ServerColorTag,
        items: [MacWorkgroupLaunchItem],
        broker: MacStartupCommandBroker = .shared,
        openWindow: (MacWorkspaceLaunchRequest) -> Void
    ) -> [MacWorkspaceLaunchRequest] {
        let boundedItems = Array(
            items.prefix(MacWorkspaceWindowRestorationState.maximumTabCount)
        )
        let tabRequests = boundedItems.map { item in
            MacWorkspaceTabRequest(
                initialPaneIntent: item.intent,
                workgroupID: workgroupID,
                workgroupName: name,
                workgroupColor: color,
                tabLabel: item.label,
                startupTicketID: broker.issue(command: item.startupCommand)
            )
        }
        guard !tabRequests.isEmpty else { return [] }
        let request = MacWorkspaceLaunchRequest(tabs: tabRequests)
        openWindow(request)
        return tabRequests.map {
            MacWorkspaceLaunchRequest(windowID: request.windowID, tabs: [$0])
        }
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
#endif
