import SwiftUI
#if canImport(UIKit)
import UIKit
import Combine
import SwiftTerm

@MainActor
public final class SwiftTermHostModel: ObservableObject {
    private weak var terminalView: TerminalView?
    private var attachedViewID: ObjectIdentifier?
    private var pendingChunks: [Data] = []
    private var lastNonce: UInt64 = 0
    private var focusRetryTask: Task<Void, Never>?

    public init() {}

    public func attach(_ view: TerminalView) {
        let viewID = ObjectIdentifier(view)
        guard attachedViewID != viewID else {
            flushPending()
            return
        }
        terminalView = view
        attachedViewID = viewID
        flushPending()
        focus()
    }

    public func focus() {
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // First responder can fail transiently during window activation;
            // retry briefly to lock keyboard ownership.
            for _ in 0..<4 {
                if self.terminalView?.becomeFirstResponder() == true {
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    public var isLikelyRunningInteractiveProgram: Bool {
        terminalView?.getTerminal().isCurrentBufferAlternate ?? false
    }

    public func ingest(data: Data, nonce: UInt64) {
        guard nonce != lastNonce else { return }
        lastNonce = nonce
        pendingChunks.append(data)
        flushPending()
    }

    private func flushPending() {
        guard let terminalView else { return }
        for chunk in pendingChunks {
            terminalView.feed(byteArray: ArraySlice(chunk))
        }
        pendingChunks.removeAll(keepingCapacity: true)
    }
}

public struct SwiftTermTheme: Equatable {
    public var fontSize: CGFloat
    public var foreground: (red: Double, green: Double, blue: Double)
    public var background: (red: Double, green: Double, blue: Double, alpha: Double)
    public var cursor: (red: Double, green: Double, blue: Double)

    public init(
        fontSize: CGFloat,
        foreground: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double, alpha: Double),
        cursor: (red: Double, green: Double, blue: Double)
    ) {
        self.fontSize = fontSize
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    public static func == (lhs: SwiftTermTheme, rhs: SwiftTermTheme) -> Bool {
        lhs.fontSize == rhs.fontSize
            && lhs.foreground == rhs.foreground
            && lhs.background == rhs.background
            && lhs.cursor == rhs.cursor
    }
}

public struct SwiftTermHostView: UIViewRepresentable {
    @ObservedObject var model: SwiftTermHostModel
    let theme: SwiftTermTheme
    let onSendData: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onTitleChanged: (String) -> Void

    public init(
        model: SwiftTermHostModel,
        theme: SwiftTermTheme,
        onSendData: @escaping (Data) -> Void,
        onResize: @escaping (Int, Int) -> Void,
        onTitleChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.theme = theme
        self.onSendData = onSendData
        self.onResize = onResize
        self.onTitleChanged = onTitleChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onSendData: onSendData,
            onResize: onResize,
            onTitleChanged: onTitleChanged
        )
    }

    public func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.notifyUpdateChanges = false
        terminal.isOpaque = false
        terminal.backgroundColor = .clear
        terminal.clearsContextBeforeDrawing = false
        terminal.layer.cornerRadius = 18
        terminal.layer.masksToBounds = true
        applyTheme(theme, to: terminal)
        context.coordinator.lastTheme = theme
        model.attach(terminal)
        return terminal
    }

    public func updateUIView(_ uiView: TerminalView, context: Context) {
        if uiView.layer.cornerRadius != 18 {
            uiView.layer.cornerRadius = 18
        }
        if !uiView.layer.masksToBounds {
            uiView.layer.masksToBounds = true
        }
        if context.coordinator.lastTheme != theme {
            applyTheme(theme, to: uiView)
            context.coordinator.lastTheme = theme
        }
        model.attach(uiView)
    }

    private func applyTheme(_ theme: SwiftTermTheme, to view: TerminalView) {
        view.font = UIFont.monospacedSystemFont(ofSize: max(10, theme.fontSize), weight: .regular)
        view.nativeForegroundColor = UIColor(
            red: theme.foreground.red,
            green: theme.foreground.green,
            blue: theme.foreground.blue,
            alpha: 1
        )
        view.nativeBackgroundColor = UIColor(
            red: theme.background.red,
            green: theme.background.green,
            blue: theme.background.blue,
            alpha: theme.background.alpha
        )
        view.caretColor = UIColor(
            red: theme.cursor.red,
            green: theme.cursor.green,
            blue: theme.cursor.blue,
            alpha: 1
        )
    }

    public final class Coordinator: NSObject, TerminalViewDelegate {
        private let onSendData: (Data) -> Void
        private let onResize: (Int, Int) -> Void
        private let onTitleChanged: (String) -> Void
        fileprivate var lastTheme: SwiftTermTheme?

        init(
            onSendData: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitleChanged: @escaping (String) -> Void
        ) {
            self.onSendData = onSendData
            self.onResize = onResize
            self.onTitleChanged = onTitleChanged
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            onTitleChanged(title)
        }

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSendData(Data(data))
        }

        public func scrolled(source: TerminalView, position: Double) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        public func bell(source: TerminalView) {}
        public func clipboardCopy(source: TerminalView, content: Data) {}
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
