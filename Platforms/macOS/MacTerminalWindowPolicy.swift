#if os(macOS)
import AppKit
import SwiftUI

enum MacTerminalToolbarItemID {
    static let tabActions = "sh.glas.toolbar.tab-actions"
    static let workspaceTools = "sh.glas.toolbar.workspace-tools"
    static let terminalTools = "sh.glas.toolbar.terminal-tools"
}

struct MacTerminalWindowReader: NSViewRepresentable {
    let tabbingIdentifier: String
    var onWindow: (NSWindow) -> Void
    var onClose: () -> Void
    var shouldConfirmClose: () -> Bool
    var opensSidebarInitially: Bool

    init(
        tabbingIdentifier: String,
        onWindow: @escaping (NSWindow) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        shouldConfirmClose: @escaping () -> Bool = { false },
        opensSidebarInitially: Bool = false
    ) {
        self.tabbingIdentifier = tabbingIdentifier
        self.onWindow = onWindow
        self.onClose = onClose
        self.shouldConfirmClose = shouldConfirmClose
        self.opensSidebarInitially = opensSidebarInitially
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NonHitTestingWindowReaderView(frame: .zero)
        let coordinator = context.coordinator
        DispatchQueue.main.async { configure(view.window, coordinator: coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { configure(nsView.window, coordinator: coordinator) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restoreWindowDelegate()
        coordinator.stopObservingWindowClose()
        coordinator.stopManagingToolbar()
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        MacTerminalWindowPolicy.apply(window, tabbingIdentifier: tabbingIdentifier)
        coordinator.observeWindowClose(window, action: onClose)
        coordinator.interceptWindowClose(window, shouldConfirm: shouldConfirmClose)
        coordinator.manageToolbar(in: window)
        coordinator.configureInitialSidebar(in: window, enabled: opensSidebarInitially)
        onWindow(window)
    }

    @MainActor
    private final class NonHitTestingWindowReaderView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        static let active = NSHashTable<Coordinator>.weakObjects()
        private weak var observedWindow: NSWindow?
        private var closeAction: (() -> Void)?
        private var shouldConfirmClose: (() -> Bool)?
        // AppKit performs delegate discovery/forwarding on its main thread, but
        // NSObject's Objective-C forwarding overrides are nonisolated in Swift.
        nonisolated(unsafe) private weak var originalWindowDelegate: (any NSWindowDelegate)?
        private var isConfirmingClose = false
        private var didRunCloseAction = false
        private weak var observedToolbar: NSToolbar?
        private weak var trailingFlexibleSpaceItem: NSToolbarItem?
        private weak var interGroupSpaceItem: NSToolbarItem?
        private var isReconcilingToolbar = false
        private var wantsInitialSidebar = false
        private var didApplyInitialSidebar = false
        private var sidebarDiscoveryAttempts = 0

        func configureInitialSidebar(in window: NSWindow, enabled: Bool) {
            wantsInitialSidebar = enabled
            applyInitialSidebarIfNeeded(in: window)
        }

        private func applyInitialSidebarIfNeeded(in window: NSWindow) {
            guard wantsInitialSidebar, !didApplyInitialSidebar,
                  sidebarDiscoveryAttempts < 16,
                  let root = window.contentView else { return }
            sidebarDiscoveryAttempts += 1
            // Use AppKit's public sidebar semantics only. SwiftUI can assemble
            // the native split after this reader attaches; didUpdate retries
            // briefly. Unsupported hosts simply keep their system default.
            var views = [root]
            var index = 0
            while index < views.count, index < 256 {
                let view = views[index]
                index += 1
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                    didApplyInitialSidebar = true
                    sidebar.isCollapsed = false
                    return
                }
                views.append(contentsOf: view.subviews)
            }
        }

        func observeWindowClose(
            _ window: NSWindow,
            action: @escaping () -> Void
        ) {
            closeAction = action
            guard observedWindow !== window else { return }
            if observedWindow != nil {
                restoreWindowDelegate()
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didUpdateNotification,
                    object: observedWindow
                )
                stopManagingToolbar()
            }
            observedWindow = window
            didRunCloseAction = false
            Self.active.add(self)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(observedWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(observedWindowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }

        func stopObservingWindowClose() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didUpdateNotification,
                object: observedWindow
            )
            observedWindow = nil
            closeAction = nil
            Self.active.remove(self)
        }

        func manageToolbar(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            if observedToolbar !== toolbar {
                stopManagingToolbar()
                observedToolbar = toolbar
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(toolbarWillAddItem(_:)),
                    name: NSToolbar.willAddItemNotification,
                    object: toolbar
                )
            }
            reconcileNativeToolbarSpacing(in: toolbar)
        }

        func stopManagingToolbar() {
            if let observedToolbar {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSToolbar.willAddItemNotification,
                    object: observedToolbar
                )
            }
            observedToolbar = nil
            trailingFlexibleSpaceItem = nil
            interGroupSpaceItem = nil
            isReconcilingToolbar = false
        }

        func interceptWindowClose(
            _ window: NSWindow,
            shouldConfirm: @escaping () -> Bool
        ) {
            self.shouldConfirmClose = shouldConfirm
            guard observedWindow === window, window.delegate !== self else { return }
            originalWindowDelegate = window.delegate
            window.delegate = self
        }

        func restoreWindowDelegate() {
            if let window = observedWindow, window.delegate === self {
                window.delegate = originalWindowDelegate
            }
            originalWindowDelegate = nil
            shouldConfirmClose = nil
        }

        // SwiftUI keeps ownership of its window lifecycle and restoration callbacks.
        // Forward every optional delegate method except the close gate we extend.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalWindowDelegate?.responds(to: selector) == true
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalWindowDelegate?.responds(to: selector) == true {
                return originalWindowDelegate
            }
            return super.forwardingTarget(for: selector)
        }

        var requiresCloseConfirmation: Bool { shouldConfirmClose?() == true }

        func finishSessions() {
            guard !didRunCloseAction else { return }
            didRunCloseAction = true
            closeAction?()
        }

        func windowShouldClose(_ window: NSWindow) -> Bool {
            guard !isConfirmingClose else { return false }
            guard originalWindowDelegate?.windowShouldClose?(window) != false else { return false }
            guard requiresCloseConfirmation else { return true }
            isConfirmingClose = true
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "Running terminal sessions in this window will be disconnected."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window) { [weak self, weak window] response in
                self?.isConfirmingClose = false
                if response == .alertFirstButtonReturn {
                    window?.close()
                }
            }
            return false
        }

        @objc private func toolbarWillAddItem(_ notification: Notification) {
            guard notification.object as? NSToolbar === observedToolbar else { return }
            DispatchQueue.main.async { [weak self] in
                guard let toolbar = self?.observedToolbar else { return }
                self?.reconcileNativeToolbarSpacing(in: toolbar)
            }
        }

        private func reconcileNativeToolbarSpacing(in toolbar: NSToolbar) {
            guard !isReconcilingToolbar else { return }
            isReconcilingToolbar = true
            defer { isReconcilingToolbar = false }

            guard let workspaceIndex = toolbar.items.firstIndex(where: {
                $0.itemIdentifier.rawValue == MacTerminalToolbarItemID.workspaceTools
            }) else {
                removeOwnedItem(trailingFlexibleSpaceItem, from: toolbar)
                removeOwnedItem(interGroupSpaceItem, from: toolbar)
                return
            }

            if workspaceIndex > 0,
               toolbar.items[workspaceIndex - 1].itemIdentifier == .flexibleSpace {
                trailingFlexibleSpaceItem = toolbar.items[workspaceIndex - 1]
            } else {
                removeOwnedItem(trailingFlexibleSpaceItem, from: toolbar)
                guard let insertionIndex = toolbar.items.firstIndex(where: {
                    $0.itemIdentifier.rawValue == MacTerminalToolbarItemID.workspaceTools
                }) else { return }
                toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: insertionIndex)
                trailingFlexibleSpaceItem = insertedItem(
                    with: .flexibleSpace,
                    at: insertionIndex,
                    in: toolbar
                )
            }

            guard let terminalIndex = toolbar.items.firstIndex(where: {
                $0.itemIdentifier.rawValue == MacTerminalToolbarItemID.terminalTools
            }) else {
                removeOwnedItem(interGroupSpaceItem, from: toolbar)
                return
            }

            if terminalIndex > 0,
               toolbar.items[terminalIndex - 1].itemIdentifier == .space {
                interGroupSpaceItem = toolbar.items[terminalIndex - 1]
            } else {
                removeOwnedItem(interGroupSpaceItem, from: toolbar)
                guard let insertionIndex = toolbar.items.firstIndex(where: {
                    $0.itemIdentifier.rawValue == MacTerminalToolbarItemID.terminalTools
                }) else { return }
                toolbar.insertItem(withItemIdentifier: .space, at: insertionIndex)
                interGroupSpaceItem = insertedItem(
                    with: .space,
                    at: insertionIndex,
                    in: toolbar
                )
            }
        }

        private func insertedItem(
            with identifier: NSToolbarItem.Identifier,
            at index: Int,
            in toolbar: NSToolbar
        ) -> NSToolbarItem? {
            guard toolbar.items.indices.contains(index),
                  toolbar.items[index].itemIdentifier == identifier else { return nil }
            return toolbar.items[index]
        }

        private func removeOwnedItem(_ item: NSToolbarItem?, from toolbar: NSToolbar) {
            guard let item,
                  let index = toolbar.items.firstIndex(where: { $0 === item }) else { return }
            toolbar.removeItem(at: index)
        }

        @objc private func observedWindowDidUpdate(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            manageToolbar(in: window)
            applyInitialSidebarIfNeeded(in: window)
        }

        @objc private func observedWindowWillClose(_ notification: Notification) {
            finishSessions()
        }
    }
}

@MainActor
enum MacTerminalWindowPolicy {
    static func apply(_ window: NSWindow, tabbingIdentifier: String) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // Match Apple's full-height sidebar windows: native sidebar material
        // extends beneath the traffic lights while the toolbar remains system
        // glass and the terminal canvas keeps its independent clear backing.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // SwiftUI's sidebar-adaptable TabView owns terminal tabs inside this
        // window. Disallow a second AppKit tab layer and its horizontal strip.
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = ""
        window.isRestorable = true
        window.autorecalculatesKeyViewLoop = true
        window.toolbarStyle = .unifiedCompact
        // Never set alphaValue: foreground glyphs and the cursor must stay fully
        // opaque while theme fill and blur vary independently behind them.
    }
}
#endif
