import AppKit
import Carbon.HIToolbox
import Observation

/// Balances Carbon secure-event-input calls for the one workspace that owns
/// the checked menu command. The API is process-wide and reference counted, so
/// a single authority prevents unmatched enable/disable calls across windows.
@MainActor
@Observable
final class MacSecureKeyboardEntry {
    static let shared = MacSecureKeyboardEntry()

    private(set) var ownerWorkspaceID: UUID?
    private(set) var lastError: String?
    private var observers: [NSObjectProtocol] = []

    private init(notificationCenter: NotificationCenter = .default) {
        for name in [
            NSApplication.didResignActiveNotification,
            NSApplication.willTerminateNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    MacSecureKeyboardEntry.shared.disableAll()
                }
            })
        }
    }

    func isEnabled(for workspaceID: UUID) -> Bool {
        ownerWorkspaceID == workspaceID
    }

    func setEnabled(_ enabled: Bool, for workspaceID: UUID) {
        enabled ? enable(for: workspaceID) : disable(for: workspaceID)
    }

    func toggle(for workspaceID: UUID) {
        setEnabled(!isEnabled(for: workspaceID), for: workspaceID)
    }

    func enable(for workspaceID: UUID) {
        guard ownerWorkspaceID != workspaceID else { return }
        disableAll()
        guard ownerWorkspaceID == nil else { return }
        let status = EnableSecureEventInput()
        guard status == noErr else {
            lastError = "Secure Keyboard Entry could not be enabled (OSStatus \(status))."
            return
        }
        lastError = nil
        ownerWorkspaceID = workspaceID
    }

    func disable(for workspaceID: UUID) {
        guard ownerWorkspaceID == workspaceID else { return }
        disableAll()
    }

    func disableAll() {
        guard ownerWorkspaceID != nil else { return }
        let status = DisableSecureEventInput()
        if status == noErr {
            ownerWorkspaceID = nil
            lastError = nil
        } else {
            lastError = "Secure Keyboard Entry could not be disabled cleanly (OSStatus \(status))."
        }
    }

    func clearError() {
        lastError = nil
    }
}
