#if os(macOS)
import AppKit
import SwiftUI

@MainActor
struct MacWorkspaceFocusedActions {
    let workspaceID: UUID
    let canAddPane: Bool
    let hasFocusedPane: Bool
    let secureKeyboardEntryEnabled: Bool
    let addLocalPane: (MacWorkspaceSplitAxis) -> Void
    let requestSSHPane: (MacWorkspaceSplitAxis) -> Void
    let closeFocusedPane: () -> Void
    let focusNextPane: () -> Void
    let findInFocusedPane: () -> Void
    let toggleSecureKeyboardEntry: () -> Void
}

@MainActor
struct MacNewWorkspaceTabAction {
    let isEnabled: Bool
    private let action: () -> Void

    init(isEnabled: Bool, _ action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
    }

    func callAsFunction() {
        guard isEnabled else { return }
        action()
    }
}

@MainActor
struct MacCloseWorkspaceTabAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func callAsFunction() {
        action()
    }
}

private struct MacWorkspaceFocusedActionsKey: FocusedValueKey {
    typealias Value = MacWorkspaceFocusedActions
}

private struct MacNewWorkspaceTabActionKey: FocusedValueKey {
    typealias Value = MacNewWorkspaceTabAction
}

private struct MacCloseWorkspaceTabActionKey: FocusedValueKey {
    typealias Value = MacCloseWorkspaceTabAction
}

extension FocusedValues {
    var macCloseWorkspaceTabAction: MacCloseWorkspaceTabAction? {
        get { self[MacCloseWorkspaceTabActionKey.self] }
        set { self[MacCloseWorkspaceTabActionKey.self] = newValue }
    }

    var macWorkspaceActions: MacWorkspaceFocusedActions? {
        get { self[MacWorkspaceFocusedActionsKey.self] }
        set { self[MacWorkspaceFocusedActionsKey.self] = newValue }
    }

    var macNewWorkspaceTabAction: MacNewWorkspaceTabAction? {
        get { self[MacNewWorkspaceTabActionKey.self] }
        set { self[MacNewWorkspaceTabActionKey.self] = newValue }
    }
}

struct MacWorkspaceCommands: Commands {
    @FocusedValue(\.macWorkspaceActions) private var actions
    @FocusedValue(\.macNewWorkspaceTabAction) private var newWorkspaceTabAction
    @FocusedValue(\.macCloseWorkspaceTabAction) private var closeWorkspaceTabAction
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Terminal Window") {
                openWindow(id: "workspace", value: MacWorkspaceLaunchRequest())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Workspace Tab") {
                if let newWorkspaceTabAction {
                    newWorkspaceTabAction()
                } else {
                    openWindow(
                        id: "workspace",
                        value: MacWorkspaceLaunchRequest(startsEmpty: true)
                    )
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(newWorkspaceTabAction?.isEnabled == false)

            Button("Connect Saved Host…") {
                actions?.requestSSHPane(.horizontal)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(actions?.canAddPane != true)
        }

        // Replace the native Close command instead of registering a second
        // Cmd-W shortcut that could still close the whole workspace window.
        CommandGroup(replacing: .saveItem) {
            Button(closeWorkspaceTabAction == nil ? "Close Window" : "Close Tab") {
                guard let window = NSApp.keyWindow,
                      window.attachedSheet == nil,
                      window.sheetParent == nil else { return }
                if let closeWorkspaceTabAction {
                    closeWorkspaceTabAction()
                } else {
                    window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu("Terminal") {
            Button("Find in Pane…") {
                actions?.findInFocusedPane()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions?.hasFocusedPane != true)

            Divider()

            Button("Split Right") {
                actions?.addLocalPane(.horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(actions?.canAddPane != true)

            Button("Split Down") {
                actions?.addLocalPane(.vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions?.canAddPane != true)

            Button("Connect Saved Host in Split…") {
                actions?.requestSSHPane(.horizontal)
            }
            .disabled(actions?.canAddPane != true)

            Divider()

            Button("Focus Next Pane") {
                actions?.focusNextPane()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(actions?.hasFocusedPane != true)

            Button("Close Pane") {
                actions?.closeFocusedPane()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(actions?.hasFocusedPane != true)

            Divider()

            Button {
                actions?.toggleSecureKeyboardEntry()
            } label: {
                if actions?.secureKeyboardEntryEnabled == true {
                    Label("Secure Keyboard Entry", systemImage: "checkmark")
                } else {
                    Text("Secure Keyboard Entry")
                }
            }
            .disabled(actions?.hasFocusedPane != true)
        }
    }
}
#endif
