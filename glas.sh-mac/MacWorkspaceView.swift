import AppKit
import SwiftUI

struct MacWorkspaceSceneRoot: View {
    private let request: MacWorkspaceLaunchRequest

    init(request: MacWorkspaceLaunchRequest?) {
        self.request = request ?? MacWorkspaceLaunchRequest(startsEmpty: true)
    }

    var body: some View {
        MacWorkspaceView(request: request)
    }
}

struct MacWorkspaceView: View {
    @State private var controller: MacWorkspaceController
    @State private var secureKeyboardEntry = MacSecureKeyboardEntry.shared
    @State private var persistentStateReady = false
    @State private var showingPaneCloseConfirmation = false

    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow

    init(request: MacWorkspaceLaunchRequest) {
        _controller = State(initialValue: MacWorkspaceController(request: request))
    }

    var body: some View {
        workspaceContent
            .frame(minWidth: 720, minHeight: 460)
            .background(.clear)
            .background {
                MacTerminalWindowReader(
                    tabbingIdentifier: "sh.glas.workspace",
                    onWindow: { window in
                        window.title = controller.windowTitle
                        MacWorkspaceWindowRegistry.shared.register(
                            window,
                            workspaceID: controller.workspaceID
                        )
                    },
                    onClose: {
                        controller.closeAllSessions(sessionManager: sessionManager)
                        secureKeyboardEntry.disable(for: controller.workspaceID)
                        MacWorkspaceWindowRegistry.shared.unregister(controller.workspaceID)
                    },
                    shouldConfirmClose: {
                        settingsManager.confirmBeforeClosing && !controller.isEmpty
                    }
                )
            }
            .navigationTitle(controller.windowTitle)
            .toolbar { workspaceToolbar }
            .focusedSceneValue(\.macWorkspaceActions, focusedActions)
            .focusedSceneValue(\.macNewWorkspaceTabAction, newWorkspaceTabAction)
            .sheet(isPresented: sshPickerPresented) { sshPicker }
            .alert(
                "Secure Keyboard Entry",
                isPresented: secureKeyboardErrorPresented
            ) {
                Button("OK", role: .cancel) { secureKeyboardEntry.clearError() }
            } message: {
                Text(secureKeyboardEntry.lastError ?? "Secure Keyboard Entry could not be changed.")
            }
            .confirmationDialog(
                "Close Terminal Pane?",
                isPresented: $showingPaneCloseConfirmation,
                titleVisibility: .visible
            ) {
                Button("Close Pane", role: .destructive) {
                    controller.removeFocusedPane(sessionManager: sessionManager)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The terminal process or SSH session in this pane will be disconnected.")
            }
            .onAppear {
                SharedDefaults.migrateIfNeeded()
                sessionManager.preloadPersistentStateIfNeeded()
                settingsManager.loadPersistentStateIfNeeded()
                persistentStateReady = true
            }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let root = controller.state.root {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let showsPaneChrome = root.panes.count > 1
                let layoutBounds = showsPaneChrome ? bounds.insetBy(dx: 8, dy: 8) : bounds
                let layout = MacWorkspaceLayout(root: root, in: layoutBounds)
                let globalOrigin = proxy.frame(in: .global).origin

                ZStack(alignment: .topLeading) {
                    ForEach(root.panes) { pane in
                        if let frame = layout.paneFrames[pane.id] {
                            paneView(pane, showsPaneChrome: showsPaneChrome)
                                .id(pane.id)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }

                    ForEach(layout.handles) { handle in
                        splitHandle(handle, globalOrigin: globalOrigin)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("New Terminal", systemImage: "apple.terminal")
            } description: {
                Text("Choose how to start this terminal tab.")
            } actions: {
                Button("Local Terminal", systemImage: "apple.terminal") {
                    controller.addPane(intent: .local, axis: .horizontal)
                }
                Button("SSH Connection", systemImage: "network") {
                    controller.requestSSHPane(axis: .horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TerminalCanvasBackground(
                    color: settingsManager.currentTheme.background,
                    tint: TerminalGlassTint.color(for: settingsManager.glassTint),
                    opacity: settingsManager.windowOpacity,
                    blur: settingsManager.blurBackground,
                    appearance: settingsManager.currentTheme.resolvedAppearance
                )
            }
        }
    }

    @ViewBuilder
    private func paneView(_ pane: MacWorkspacePane, showsPaneChrome: Bool) -> some View {
        let isFocused = controller.focusedPaneID == pane.id
        switch pane.intent.kind {
        case .local:
            MacLocalTerminalPaneView(
                workspaceID: controller.workspaceID,
                isFocused: isFocused,
                showsPaneChrome: showsPaneChrome,
                findRequestNonce: findNonce(for: pane.id),
                claimStartupCommand: { controller.claimStartupCommand(for: pane.id) },
                onFocus: { controller.focus(pane.id) },
                onNewTerminalTab: { newWorkspaceTabAction() },
                onDisconnect: {
                    let closesWorkspace = controller.state.root?.panes.count == 1
                    controller.removePane(pane.id, sessionManager: sessionManager)
                    if closesWorkspace {
                        MacWorkspaceWindowRegistry.shared.close(controller.workspaceID)
                    }
                }
            )
        case .ssh:
            if !persistentStateReady {
                ProgressView("Loading saved hosts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
            } else if let session = controller.session(for: pane.id) {
                TerminalWindowView(
                    session: session,
                    ownsSessionLifecycle: false,
                    externalSearchRequestNonce: findNonce(for: pane.id),
                    onNewTerminalTab: { newWorkspaceTabAction() },
                    onSessionRequestedClose: {
                        controller.disconnectSSHPane(
                            pane.id,
                            sessionManager: sessionManager
                        )
                    }
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { controller.focus(pane.id) })
            } else {
                sshPlaceholder(for: pane)
                    .task(id: controller.error(for: pane.id)) {
                        await controller.prepareSSHPaneIfNeeded(
                            pane,
                            sessionManager: sessionManager,
                            settingsManager: settingsManager
                        )
                    }
            }
        }
    }

    private func sshPlaceholder(for pane: MacWorkspacePane) -> some View {
        Group {
            if controller.isLoading(pane.id) {
                ProgressView("Connecting…")
            } else if let error = controller.error(for: pane.id) {
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { controller.retryPane(pane.id) }
                    Button("Close Pane", role: .destructive) {
                        controller.removePane(pane.id, sessionManager: sessionManager)
                    }
                }
            } else {
                ProgressView("Preparing SSH session…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture { controller.focus(pane.id) }
    }

    private func splitHandle(
        _ handle: MacWorkspaceLayout.Handle,
        globalOrigin: CGPoint
    ) -> some View {
        let hitWidth = handle.axis == .horizontal ? max(14, handle.frame.width) : handle.frame.width
        let hitHeight = handle.axis == .vertical ? max(14, handle.frame.height) : handle.frame.height
        return Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(
                        width: handle.axis == .horizontal ? 2 : 30,
                        height: handle.axis == .horizontal ? 30 : 2
                    )
            }
            .frame(width: hitWidth, height: hitHeight)
            .position(x: handle.frame.midX, y: handle.frame.midY)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let point = CGPoint(
                            x: value.location.x - globalOrigin.x,
                            y: value.location.y - globalOrigin.y
                        )
                        let rawFraction: Double
                        switch handle.axis {
                        case .horizontal:
                            rawFraction = Double(
                                (point.x - handle.container.minX)
                                    / max(1, handle.container.width)
                            )
                        case .vertical:
                            rawFraction = Double(
                                (point.y - handle.container.minY)
                                    / max(1, handle.container.height)
                            )
                        }
                        controller.updateSplitFraction(handle.id, fraction: rawFraction)
                    }
            )
            .onHover { hovering in
                if hovering {
                    (handle.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityLabel(handle.axis == .horizontal ? "Vertical split divider" : "Horizontal split divider")
            .accessibilityValue("\(Int(handle.fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                controller.updateSplitFraction(handle.id, fraction: handle.fraction + delta)
            }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                if let color = controller.workgroupColor?.color {
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: 18)
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Image(systemName: "apple.terminal")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(controller.windowTitle)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup {
            Button("New Local Pane", systemImage: "rectangle.split.2x1") {
                controller.addPane(intent: .local, axis: .horizontal)
            }
            .disabled(!controller.canAddPane)

            Button("Connect Host", systemImage: "network") {
                controller.requestSSHPane(axis: .horizontal)
            }
            .disabled(!controller.canAddPane)

            Button("Secure Keyboard Entry", systemImage: secureKeyboardEntry.isEnabled(for: controller.workspaceID) ? "lock.fill" : "lock.open") {
                secureKeyboardEntry.toggle(for: controller.workspaceID)
            }
            .disabled(controller.focusedPaneID == nil)
        }
    }

    private var focusedActions: MacWorkspaceFocusedActions {
        MacWorkspaceFocusedActions(
            workspaceID: controller.workspaceID,
            canAddPane: controller.canAddPane,
            hasFocusedPane: controller.focusedPaneID != nil,
            secureKeyboardEntryEnabled: secureKeyboardEntry.isEnabled(for: controller.workspaceID),
            addLocalPane: { controller.addPane(intent: .local, axis: $0) },
            requestSSHPane: { controller.requestSSHPane(axis: $0) },
            closeFocusedPane: {
                if settingsManager.confirmBeforeClosing {
                    showingPaneCloseConfirmation = true
                } else {
                    controller.removeFocusedPane(sessionManager: sessionManager)
                }
            },
            focusNextPane: { controller.focusNextPane() },
            findInFocusedPane: { controller.requestFindInFocusedPane() },
            toggleSecureKeyboardEntry: {
                secureKeyboardEntry.toggle(for: controller.workspaceID)
            }
        )
    }

    private var newWorkspaceTabAction: MacNewWorkspaceTabAction {
        MacNewWorkspaceTabAction {
            let request = MacWorkspaceLaunchRequest(startsEmpty: true)
            MacWorkspaceWindowRegistry.shared.prepareTab(
                sourceWorkspaceID: controller.workspaceID,
                destinationWorkspaceID: request.workspaceID
            )
            openWindow(id: "workspace", value: request)
        }
    }

    private func findNonce(for paneID: UUID) -> UInt64 {
        controller.findTargetPaneID == paneID ? controller.findRequestNonce : 0
    }

    private var sshPickerPresented: Binding<Bool> {
        Binding(
            get: { controller.pendingSSHAxis != nil },
            set: { if !$0 { controller.cancelSSHPaneRequest() } }
        )
    }

    private var sshPicker: some View {
        NavigationStack {
            Group {
                if sessionManager.serverManager.servers.isEmpty {
                    ContentUnavailableView(
                        "No Saved Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host in Connections, then return here to open it in a pane.")
                    )
                } else {
                    List(sessionManager.serverManager.servers) { server in
                        Button {
                            controller.addSSHPane(serverID: server.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name)
                                Text("\(server.username)@\(server.host):\(server.port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Connect Saved Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { controller.cancelSSHPaneRequest() }
                }
                ToolbarItem {
                    Button("Open Connections") {
                        controller.cancelSSHPaneRequest()
                        openWindow(id: "main")
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var secureKeyboardErrorPresented: Binding<Bool> {
        Binding(
            get: { secureKeyboardEntry.lastError != nil },
            set: { if !$0 { secureKeyboardEntry.clearError() } }
        )
    }
}

private struct MacWorkspaceLayout {
    struct Handle: Identifiable {
        let id: UUID
        let axis: MacWorkspaceSplitAxis
        let fraction: Double
        let frame: CGRect
        let container: CGRect
    }

    private(set) var paneFrames: [UUID: CGRect] = [:]
    private(set) var handles: [Handle] = []

    init(root: MacWorkspaceNode, in bounds: CGRect) {
        place(root, in: bounds)
    }

    private mutating func place(_ node: MacWorkspaceNode, in rect: CGRect) {
        switch node {
        case .pane(let pane):
            paneFrames[pane.id] = rect
        case .split(let split):
            let gap: CGFloat = 8
            let fraction = CGFloat(min(0.9, max(0.1, split.fraction)))
            switch split.axis {
            case .horizontal:
                let usable = max(0, rect.width - gap)
                let firstWidth = usable * fraction
                let first = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                let handle = CGRect(x: first.maxX, y: rect.minY, width: gap, height: rect.height)
                let second = CGRect(x: handle.maxX, y: rect.minY, width: usable - firstWidth, height: rect.height)
                handles.append(Handle(id: split.id, axis: split.axis, fraction: split.fraction, frame: handle, container: rect))
                place(split.first, in: first)
                place(split.second, in: second)
            case .vertical:
                let usable = max(0, rect.height - gap)
                let firstHeight = usable * fraction
                let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                let handle = CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: gap)
                let second = CGRect(x: rect.minX, y: handle.maxY, width: rect.width, height: usable - firstHeight)
                handles.append(Handle(id: split.id, axis: split.axis, fraction: split.fraction, frame: handle, container: rect))
                place(split.first, in: first)
                place(split.second, in: second)
            }
        }
    }
}

@MainActor
final class MacWorkspaceWindowRegistry {
    static let shared = MacWorkspaceWindowRegistry()
    private static let maximumPendingTabs = 32
    private static let maximumPendingBatches = 32

    private var windows: [UUID: WeakWindow] = [:]
    private var pendingTabs: [UUID: WeakWindow] = [:]
    private var pendingBatches: [UUID: PendingBatch] = [:]
    private var batchIDByWorkspaceID: [UUID: UUID] = [:]
    var pendingTabCount: Int { pendingTabs.count }
    var pendingBatchCount: Int { pendingBatches.count }

    func register(_ window: NSWindow, workspaceID: UUID) {
        windows[workspaceID] = WeakWindow(window)
        if let batchID = batchIDByWorkspaceID[workspaceID] {
            assembleBatchIfReady(batchID)
        }
        guard let source = pendingTabs.removeValue(forKey: workspaceID)?.value,
              source !== window,
              source.isVisible else { return }
        source.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    func prepareTab(sourceWorkspaceID: UUID, destinationWorkspaceID: UUID) {
        guard let sourceWindow = windows[sourceWorkspaceID]?.value else {
            pendingTabs.removeValue(forKey: destinationWorkspaceID)
            return
        }
        prepareTab(sourceWindow: sourceWindow, destinationWorkspaceID: destinationWorkspaceID)
    }

    func prepareTab(sourceWindow: NSWindow, destinationWorkspaceID: UUID) {
        pendingTabs = pendingTabs.filter { $0.value.value != nil }
        if pendingTabs.count >= Self.maximumPendingTabs,
           let oldestDeterministicKey = pendingTabs.keys.sorted(by: {
               $0.uuidString < $1.uuidString
           }).first {
            pendingTabs.removeValue(forKey: oldestDeterministicKey)
        }
        pendingTabs[destinationWorkspaceID] = WeakWindow(sourceWindow)
    }

    func prepareTabBatch(workspaceIDs: [UUID]) {
        var seen = Set<UUID>()
        let orderedIDs = workspaceIDs.filter { seen.insert($0).inserted }
        guard orderedIDs.count > 1,
              orderedIDs.count <= MacWorkspaceRestorationState.maximumPaneCount else { return }

        for workspaceID in orderedIDs {
            if let existingBatchID = batchIDByWorkspaceID[workspaceID] {
                cancelBatch(existingBatchID)
            }
        }
        if pendingBatches.count >= Self.maximumPendingBatches,
           let oldestBatchID = pendingBatches.keys.sorted(by: {
               $0.uuidString < $1.uuidString
           }).first {
            cancelBatch(oldestBatchID)
        }

        let batchID = UUID()
        pendingBatches[batchID] = PendingBatch(orderedWorkspaceIDs: orderedIDs)
        for workspaceID in orderedIDs {
            batchIDByWorkspaceID[workspaceID] = batchID
        }
        assembleBatchIfReady(batchID)
    }

    func unregister(_ workspaceID: UUID) {
        let closingWindow = windows.removeValue(forKey: workspaceID)?.value
        if let batchID = batchIDByWorkspaceID[workspaceID] {
            cancelBatch(batchID)
        }
        pendingTabs.removeValue(forKey: workspaceID)
        pendingTabs = pendingTabs.filter { _, source in
            guard let sourceWindow = source.value else { return false }
            return sourceWindow !== closingWindow
        }
    }

    func close(_ workspaceID: UUID) {
        windows[workspaceID]?.value?.performClose(nil)
    }

    private func assembleBatchIfReady(_ batchID: UUID) {
        guard let batch = pendingBatches[batchID] else { return }
        let orderedWindows = batch.orderedWorkspaceIDs.compactMap { windows[$0]?.value }
        guard orderedWindows.count == batch.orderedWorkspaceIDs.count,
              let firstWindow = orderedWindows.first else { return }

        cancelBatch(batchID)
        // AppKit inserts `.above` immediately after the receiver. Reverse
        // assembly therefore preserves the workgroup's saved tab order.
        for window in orderedWindows.dropFirst().reversed() where window !== firstWindow {
            firstWindow.addTabbedWindow(window, ordered: .above)
        }
        firstWindow.makeKeyAndOrderFront(nil)
    }

    private func cancelBatch(_ batchID: UUID) {
        guard let batch = pendingBatches.removeValue(forKey: batchID) else { return }
        for workspaceID in batch.orderedWorkspaceIDs
        where batchIDByWorkspaceID[workspaceID] == batchID {
            batchIDByWorkspaceID.removeValue(forKey: workspaceID)
        }
    }

    private struct PendingBatch {
        let orderedWorkspaceIDs: [UUID]
    }

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }
}
