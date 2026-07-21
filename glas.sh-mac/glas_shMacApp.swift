import AppKit
import SwiftUI

@main
struct GlasShMacApp: App {
    @State private var sessionManager = SessionManager(loadImmediately: false)
    @State private var settingsManager = SettingsManager(loadImmediately: false)

    var body: some Scene {
        Window("Connections", id: "main") {
            MainBootstrapView()
                .environment(sessionManager)
                .environment(settingsManager)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.presented)
        .commands { MacWorkspaceCommands() }

        WindowGroup("Terminal", id: "workspace", for: MacWorkspaceLaunchRequest.self) { $request in
            MacWorkspaceSceneRoot(request: request)
                .environment(sessionManager)
                .environment(settingsManager)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .windowToolbarStyle(.unifiedCompact)

        WindowGroup(id: "sftp", for: SFTPBrowserContext.self) { $context in
            if let context, sessionManager.session(for: context.sessionID) != nil {
                SFTPBrowserView(sessionID: context.sessionID)
                    .environment(sessionManager)
                    .environment(settingsManager)
            } else {
                SFTPBrowserNotFoundView(context: context)
            }
        }
        .defaultSize(width: 820, height: 620)

        Window("Port Forwarding", id: "port-forwarding") {
            PortForwardingManagerView()
                .environment(sessionManager)
        }
        .defaultSize(width: 700, height: 560)

        Settings {
            SettingsView()
                .environment(sessionManager)
                .environment(settingsManager)
        }

        #if DEBUG
        WindowGroup(id: "html-preview", for: HTMLPreviewContext.self) { $context in
            if let context {
                HTMLPreviewWindow(context: context)
                    .environment(sessionManager)
            } else {
                HTMLPreviewNotFoundView(context: context)
            }
        }
        .defaultSize(width: 1000, height: 760)
        #endif
    }
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
        let view = NSView(frame: .zero)
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
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        MacTerminalWindowPolicy.apply(window, tabbingIdentifier: tabbingIdentifier)
        coordinator.observeWindowClose(window, action: onClose)
        coordinator.interceptCloseButton(window, shouldConfirm: shouldConfirmClose)
        onWindow(window)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var observedWindow: NSWindow?
        private var closeAction: (() -> Void)?
        private var shouldConfirmClose: (() -> Bool)?
        private weak var originalCloseTarget: AnyObject?
        private var originalCloseAction: Selector?

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
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        func stopObservingWindowClose() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
            observedWindow = nil
            closeAction = nil
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
        // AppKit owns and draws the standard titlebar material. The window and
        // terminal canvas remain clear independently below the content layout
        // guide, so adjustable terminal transparency never erases the chrome.
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        installTitlebarMaterial(in: window)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = tabbingIdentifier
        window.isRestorable = true
        window.autorecalculatesKeyViewLoop = true
        // Never set alphaValue: foreground glyphs and the cursor must stay fully
        // opaque while theme fill and blur vary independently behind them.
    }

    private static func installTitlebarMaterial(in window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }

        if let existing = themeFrame.subviews
            .compactMap({ $0 as? MacTerminalTitlebarMaterialView })
            .first(where: {
                $0.identifier == MacTerminalTitlebarMaterialView.materialIdentifier
            }) {
            if existing.contentBoundary === contentView {
                return
            }
            existing.removeFromSuperview()
        }

        let materialView = MacTerminalTitlebarMaterialView(frame: .zero)
        materialView.identifier = MacTerminalTitlebarMaterialView.materialIdentifier
        materialView.contentBoundary = contentView
        materialView.material = .titlebar
        materialView.blendingMode = .behindWindow
        materialView.state = .followsWindowActiveState
        materialView.alphaValue = 1
        materialView.translatesAutoresizingMaskIntoConstraints = false
        themeFrame.addSubview(materialView, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: themeFrame.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: themeFrame.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: themeFrame.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: contentView.topAnchor),
        ])
    }
}

@MainActor
final class MacTerminalTitlebarMaterialView: NSVisualEffectView {
    static let materialIdentifier = NSUserInterfaceItemIdentifier(
        "sh.glas.terminal-titlebar-material"
    )

    weak var contentBoundary: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
