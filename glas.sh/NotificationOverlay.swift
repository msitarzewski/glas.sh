//
//  NotificationOverlay.swift
//  glas.sh
//
//  In-window notification banners for terminal events
//

import SwiftUI

struct TerminalNotification: Identifiable {
    let id: UUID
    let icon: String
    let title: String
    let message: String?
    let style: Style
    let timestamp: Date

    enum Style {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .warning: return .yellow
            case .error: return .red
            }
        }
    }

    init(icon: String, title: String, message: String? = nil, style: Style) {
        self.id = UUID()
        self.icon = icon
        self.title = title
        self.message = message
        self.style = style
        self.timestamp = Date()
    }
}

@MainActor
@Observable
class NotificationManager {
    var active: [TerminalNotification] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    func post(icon: String, title: String, message: String? = nil, style: TerminalNotification.Style) {
        let notification = TerminalNotification(icon: icon, title: title, message: message, style: style)

        // Max 3 visible
        if active.count >= 3 {
            let oldest = active[0]
            dismiss(oldest.id)
        }

        active.append(notification)

        // Auto-dismiss after 4 seconds
        dismissTasks[notification.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.active.removeAll { $0.id == notification.id }
            }
            self.dismissTasks.removeValue(forKey: notification.id)
        }
    }

    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
        withAnimation(.easeOut(duration: 0.3)) {
            active.removeAll { $0.id == id }
        }
    }
}

struct NotificationBanner: View {
    let notification: TerminalNotification
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notification.icon)
                .font(.body)
                .foregroundStyle(notification.style.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if let message = notification.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
