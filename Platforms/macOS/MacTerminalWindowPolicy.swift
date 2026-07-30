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

    init(
        tabbingIdentifier: String,
        onWindow: @escaping (NSWindow) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        shouldConfirmClose: @escaping () -> Bool = { false }
    ) {
        self.tabbingIdentifier = tabbingIdentifier
        self.onWindow = onWindow
        self.onClose = onClose
        self.shouldConfirmClose = shouldConfirmClose
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
        coordinator.restoreCloseButton()
        coordinator.stopObservingWindowClose()
        coordinator.stopManagingToolbar()
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        MacTerminalWindowPolicy.apply(window, tabbingIdentifier: tabbingIdentifier)
        coordinator.observeWindowClose(window, action: onClose)
        coordinator.interceptCloseButton(window, shouldConfirm: shouldConfirmClose)
        coordinator.manageToolbar(in: window)
        onWindow(window)
    }

    @MainActor
    private final class NonHitTestingWindowReaderView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var observedWindow: NSWindow?
        private var closeAction: (() -> Void)?
        private var shouldConfirmClose: (() -> Bool)?
        private weak var originalCloseTarget: AnyObject?
        private var originalCloseAction: Selector?
        private weak var observedToolbar: NSToolbar?
        private weak var trailingFlexibleSpaceItem: NSToolbarItem?
        private weak var interGroupSpaceItem: NSToolbarItem?
        private var isReconcilingToolbar = false

        func observeWindowClose(
            _ window: NSWindow,
            action: @escaping () -> Void
        ) {
            closeAction = action
            guard observedWindow !== window else { return }
            if observedWindow != nil {
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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
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

        func interceptCloseButton(
            _ window: NSWindow,
            shouldConfirm: @escaping () -> Bool
        ) {
            self.shouldConfirmClose = shouldConfirm
            guard observedWindow === window,
                  let closeButton = window.standardWindowButton(.closeButton),
                  closeButton.target !== self else { return }
            originalCloseTarget = closeButton.target
            originalCloseAction = closeButton.action
            closeButton.target = self
            closeButton.action = #selector(requestClose(_:))
        }

        func restoreCloseButton() {
            guard let window = observedWindow,
                  let closeButton = window.standardWindowButton(.closeButton),
                  closeButton.target === self else { return }
            closeButton.target = originalCloseTarget
            closeButton.action = originalCloseAction
            originalCloseTarget = nil
            originalCloseAction = nil
            shouldConfirmClose = nil
        }

        @objc private func requestClose(_ sender: Any?) {
            guard let window = observedWindow else { return }
            guard shouldConfirmClose?() == true else {
                window.close()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "Running terminal sessions in this window will be disconnected."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    window.close()
                }
            }
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

        @objc private func windowDidUpdate(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  window === observedWindow else { return }
            manageToolbar(in: window)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            closeAction?()
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
