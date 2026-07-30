#if os(macOS)
import AppKit
import Observation
import RealityKitContent
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
    @State private var windowController: MacWorkspaceWindowController
    @State private var secureKeyboardEntry = MacSecureKeyboardEntry.shared
    @State private var terminalWindow: NSWindow?

    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow

    init(request: MacWorkspaceLaunchRequest) {
        _windowController = State(
            initialValue: MacWorkspaceWindowController(request: request)
        )
    }

    var body: some View {
        let selected = windowController.selectedTab
        let identity = selected.windowIdentity(
            servers: sessionManager.serverManager.servers
        )

        TabView(selection: selectedTabBinding) {
            ForEach(windowController.tabs, id: \.workspaceID) { controller in
                let tabIdentity = controller.windowIdentity(
                    servers: sessionManager.serverManager.servers
                )
                Tab(value: controller.workspaceID) {
                    MacWorkspaceTabContent(
                        controller: controller,
                        onNewTab: addTab,
                        onCloseEmptyTab: { closeTab(controller.workspaceID) }
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tabIdentity.title)
                                .lineLimit(1)
                            if let subtitle = tabIdentity.subtitle {
                                Text(subtitle)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: "apple.terminal")
                            .foregroundStyle(controller.workgroupColor?.color ?? .secondary)
                    }
                }
                .accessibilityLabel(tabIdentity.title)
                .accessibilityValue(tabIdentity.subtitle ?? "")
                .accessibilityIdentifier(
                    "mac-workspace-tab-\(controller.workspaceID.uuidString.lowercased())"
                )
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .accessibilityIdentifier("mac-workspace-tabs")
        .frame(minWidth: 720, minHeight: 460)
        .containerBackground(.clear, for: .window)
        .navigationTitle(identity.title)
        .navigationSubtitle(identity.subtitle ?? "")
        .background {
            MacTerminalWindowReader(
                tabbingIdentifier: "sh.glas.workspace.\(windowController.windowID.uuidString)",
                onWindow: { window in
                    terminalWindow = window
                    window.title = identity.title
                    window.subtitle = identity.subtitle ?? ""
                },
                onClose: {
                    windowController.closeAllSessions(sessionManager: sessionManager)
                    for tab in windowController.tabs {
                        secureKeyboardEntry.disable(for: tab.workspaceID)
                    }
                },
                shouldConfirmClose: {
                    settingsManager.confirmBeforeClosing && !windowController.isEmpty
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("New Terminal Tab", systemImage: "plus", action: addTab)
                    .help("New Terminal Tab")
                    .disabled(!windowController.canAddTab)
                    .accessibilityIdentifier("mac-workspace-new-tab")
            }

            if windowController.canTransferSelectedTab {
                ToolbarItem(id: MacTerminalToolbarItemID.tabActions) {
                    Menu("Tab Actions", systemImage: "ellipsis.circle") {
                        Button("Move Tab to New Window", systemImage: "macwindow.badge.plus") {
                            moveSelectedTabToNewWindow()
                        }
                    }
                    .help("Tab Actions")
                }
                .macOverflowFirstWhenCompact()
            }

            ToolbarItem(id: MacTerminalToolbarItemID.workspaceTools) {
                HStack {
                    Button("New Local Pane", systemImage: "rectangle.split.2x1") {
                        selected.addPane(intent: .local, axis: .horizontal)
                    }
                    .disabled(!selected.canAddPane)
                    .accessibilityIdentifier("mac-workspace-new-local-pane")

                    Button("Connect Host", systemImage: "network") {
                        selected.requestSSHPane(axis: .horizontal)
                    }
                    .disabled(!selected.canAddPane)
                    .accessibilityIdentifier("mac-workspace-connect-host")

                    Button(
                        "Secure Keyboard Entry",
                        systemImage: secureKeyboardEntry.isEnabled(for: selected.workspaceID)
                            ? "lock.fill"
                            : "lock.open"
                    ) {
                        secureKeyboardEntry.toggle(for: selected.workspaceID)
                    }
                    .disabled(selected.focusedPaneID == nil)
                    .accessibilityIdentifier("mac-workspace-secure-keyboard-entry")
                }
                .padding(.horizontal, 6)
            }
            .macOverflowFirstWhenCompact()
        }
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .focusedSceneValue(
            \.macNewWorkspaceTabAction,
            MacNewWorkspaceTabAction(
                isEnabled: windowController.canAddTab,
                addTab
            )
        )
    }

    private var selectedTabBinding: Binding<UUID> {
        Binding(
            get: { windowController.selectedTabID },
            set: { windowController.select($0) }
        )
    }

    private func addTab() {
        windowController.addTab()
    }

    private func closeTab(_ workspaceID: UUID) {
        let closesWindow = windowController.removeTab(
            workspaceID,
            sessionManager: sessionManager
        )
        secureKeyboardEntry.disable(for: workspaceID)
        if closesWindow {
            terminalWindow?.performClose(nil)
        }
    }

    private func moveSelectedTabToNewWindow() {
        guard let request = windowController.transferSelectedTab() else { return }
        openWindow(id: "workspace", value: request)
    }
}

private struct MacWorkspaceTabContent: View {
    @State private var controller: MacWorkspaceController
    @State private var secureKeyboardEntry = MacSecureKeyboardEntry.shared
    @State private var persistentStateReady = false
    @State private var showingPaneCloseConfirmation = false

    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow

    private let onNewTab: () -> Void
    private let onCloseEmptyTab: () -> Void

    init(
        controller: MacWorkspaceController,
        onNewTab: @escaping () -> Void,
        onCloseEmptyTab: @escaping () -> Void
    ) {
        _controller = State(initialValue: controller)
        self.onNewTab = onNewTab
        self.onCloseEmptyTab = onCloseEmptyTab
    }

    var body: some View {
        workspaceContent
            .frame(minHeight: 460)
            .containerBackground(.clear, for: .window)
            .toolbarBackground(.regularMaterial, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .focusedSceneValue(\.macWorkspaceActions, focusedActions)
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
            let runtime = controller.localRuntime(for: pane.id)
            let recorder = controller.recorder(for: pane.id)
            MacLocalTerminalPaneView(
                runtime: runtime,
                recorder: recorder,
                workspaceID: controller.workspaceID,
                isFocused: isFocused,
                showsPaneChrome: showsPaneChrome,
                findRequestNonce: findNonce(for: pane.id),
                claimStartupCommand: { controller.claimStartupCommand(for: pane.id) },
                onFocus: { controller.focus(pane.id) },
                onDisconnect: {
                    let closesWorkspace = controller.state.root?.panes.count == 1
                    controller.removePane(pane.id, sessionManager: sessionManager)
                    if closesWorkspace {
                        onCloseEmptyTab()
                    }
                },
                hostModel: runtime.model,
                processState: runtime.processState
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
                    isTerminalActive: isFocused,
                    showsMacPaneChrome: showsPaneChrome,
                    externalSearchRequestNonce: findNonce(for: pane.id),
                    onNewTerminalTab: onNewTab,
                    onSessionRequestedClose: {
                        controller.disconnectSSHPane(
                            pane.id,
                            sessionManager: sessionManager
                        )
                    }
                )
                .overlay {
                    if showsPaneChrome {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
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

extension ToolbarContent {
    @ToolbarContentBuilder
    func macOverflowFirstWhenCompact() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.low)
        } else {
            self
        }
    }

    @ToolbarContentBuilder
    func macKeepVisibleWhenCompact() -> some ToolbarContent {
        if #available(macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
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

#endif
