//
//  SFTPTransferActivity.swift
//  glas.sh
//
//  Per-window, bounded transfer activity for the SFTP browser.
//

import Foundation
import Observation

nonisolated enum SFTPTransferKind: Equatable, Sendable {
    case download
    case upload
    case finderDownload
    case remoteCopy
    case remoteMove

    var title: String {
        switch self {
        case .download: "Download"
        case .upload: "Upload"
        case .finderDownload: "Finder Download"
        case .remoteCopy: "Remote Copy"
        case .remoteMove: "Remote Move"
        }
    }

    var activeLabel: String {
        switch self {
        case .download: "Downloading"
        case .upload: "Uploading"
        case .finderDownload: "Saving to Finder"
        case .remoteCopy: "Copying"
        case .remoteMove: "Moving"
        }
    }

    var completedLabel: String {
        switch self {
        case .download, .finderDownload: "Downloaded"
        case .upload: "Uploaded"
        case .remoteCopy: "Copied"
        case .remoteMove: "Moved"
        }
    }

    var systemImage: String {
        switch self {
        case .download, .finderDownload: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .remoteCopy: "doc.on.doc"
        case .remoteMove: "folder"
        }
    }
}

nonisolated enum SFTPTransferActivityState: Equatable, Sendable {
    case pending
    case transferring
    case verifying
    case completed
    case failed
    case cancelled

    var isInFlight: Bool {
        switch self {
        case .pending, .transferring, .verifying: true
        case .completed, .failed, .cancelled: false
        }
    }

    var isTerminal: Bool { !isInFlight }
}

nonisolated enum SFTPTransferProgressUpdate: Equatable, Sendable {
    case transferring(completedBytes: UInt64, totalBytes: UInt64)
    case verifying
}

nonisolated struct SFTPTransferActivity: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SFTPTransferKind
    var filename: String
    var state: SFTPTransferActivityState
    var completedBytes: UInt64
    var totalBytes: UInt64?
    var detail: String?

    var progress: Double? {
        guard state == .transferring,
              let totalBytes,
              totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    var statusLabel: String {
        switch state {
        case .pending:
            "Waiting"
        case .transferring:
            if let progress {
                "\(Int(progress * 100))%"
            } else {
                kind.activeLabel
            }
        case .verifying:
            "Verifying"
        case .completed:
            kind.completedLabel
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}

@MainActor
@Observable
final class SFTPTransferActivityStore {
    private(set) var activities: [SFTPTransferActivity] = []
    let maximumTerminalItemCount: Int

    init(maximumTerminalItemCount: Int = 20) {
        self.maximumTerminalItemCount = max(0, maximumTerminalItemCount)
    }

    var hasActivities: Bool { !activities.isEmpty }

    var hasInFlightActivities: Bool {
        activities.contains { $0.state.isInFlight }
    }

    var hasTerminalActivities: Bool {
        activities.contains { $0.state.isTerminal }
    }

    var activeActivity: SFTPTransferActivity? {
        activities.first { $0.state == .transferring || $0.state == .verifying }
    }

    var pendingCount: Int {
        activities.count { $0.state == .pending }
    }

    var displayedActivities: [SFTPTransferActivity] {
        let active = activities.filter {
            $0.state == .transferring || $0.state == .verifying
        }
        let pending = activities.filter { $0.state == .pending }
        let terminal = Array(activities.filter(\.state.isTerminal).reversed())
        return active + pending + terminal
    }

    var headline: String {
        if let activeActivity {
            return "\(activeActivity.kind.activeLabel) \(activeActivity.filename)"
        }
        if pendingCount > 0 {
            return pendingCount == 1 ? "1 transfer waiting" : "\(pendingCount) transfers waiting"
        }
        let failureCount = activities.count { $0.state == .failed }
        if failureCount > 0 {
            return failureCount == 1 ? "1 transfer failed" : "\(failureCount) transfers failed"
        }
        let completedCount = activities.count { $0.state == .completed }
        if completedCount > 0 {
            return completedCount == 1 ? "1 transfer completed" : "\(completedCount) transfers completed"
        }
        let cancelledCount = activities.count { $0.state == .cancelled }
        if cancelledCount > 0 {
            return cancelledCount == 1 ? "1 transfer cancelled" : "\(cancelledCount) transfers cancelled"
        }
        return "Transfers"
    }

    @discardableResult
    func enqueue(
        id: UUID = UUID(),
        kind: SFTPTransferKind,
        filename: String,
        totalBytes: UInt64? = nil
    ) -> UUID {
        guard !activities.contains(where: { $0.id == id }) else { return id }
        activities.append(SFTPTransferActivity(
            id: id,
            kind: kind,
            filename: filename,
            state: .pending,
            completedBytes: 0,
            totalBytes: totalBytes,
            detail: nil
        ))
        return id
    }

    func updateFilename(_ filename: String, for id: UUID) {
        update(id) { $0.filename = filename }
    }

    func begin(_ id: UUID) {
        update(id) {
            $0.state = .transferring
            $0.detail = nil
        }
    }

    func apply(_ progress: SFTPTransferProgressUpdate, to id: UUID) {
        update(id) { activity in
            switch progress {
            case .transferring(let completedBytes, let totalBytes):
                activity.state = .transferring
                activity.completedBytes = min(completedBytes, totalBytes)
                activity.totalBytes = totalBytes
                activity.detail = nil
            case .verifying:
                activity.state = .verifying
                activity.detail = nil
            }
        }
    }

    func complete(_ id: UUID, detail: String? = nil) {
        finish(id, as: .completed, detail: detail)
    }

    func fail(_ id: UUID, detail: String) {
        finish(id, as: .failed, detail: detail)
    }

    func cancel(_ id: UUID, detail: String? = nil) {
        finish(id, as: .cancelled, detail: detail)
    }

    func cancelPending(_ ids: some Sequence<UUID>, detail: String? = nil) {
        for id in ids where activity(id)?.state == .pending {
            cancel(id, detail: detail)
        }
    }

    func clearTerminalActivities() {
        activities.removeAll { $0.state.isTerminal }
    }

    func activity(_ id: UUID) -> SFTPTransferActivity? {
        activities.first { $0.id == id }
    }

    private func finish(
        _ id: UUID,
        as state: SFTPTransferActivityState,
        detail: String?
    ) {
        update(id) {
            $0.state = state
            $0.detail = detail
            if state == .completed, let totalBytes = $0.totalBytes {
                $0.completedBytes = totalBytes
            }
        }
        trimTerminalActivities()
    }

    private func update(_ id: UUID, change: (inout SFTPTransferActivity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[index])
    }

    private func trimTerminalActivities() {
        let terminalIndices = activities.indices.filter { activities[$0].state.isTerminal }
        let overflow = terminalIndices.count - maximumTerminalItemCount
        guard overflow > 0 else { return }
        for index in terminalIndices.prefix(overflow).reversed() {
            activities.remove(at: index)
        }
    }
}
