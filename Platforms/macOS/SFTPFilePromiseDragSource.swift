#if os(macOS)

//
//  SFTPFilePromiseDragSource.swift
//  glas.sh
//
//  Native Finder drag source for verified remote-file downloads.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

actor SFTPFilePromiseTransferRegistry {
    private var acceptsTransfers = true
    private var activeTransfers: [UUID: Task<Void, Error>] = [:]

    func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard acceptsTransfers else { throw CancellationError() }

        let id = UUID()
        let transfer = Task {
            try await operation()
        }
        activeTransfers[id] = transfer
        defer { activeTransfers.removeValue(forKey: id) }

        try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: {
            transfer.cancel()
        }
    }

    func cancelAllAndWait() async {
        acceptsTransfers = false
        let transfers = Array(activeTransfers.values)
        transfers.forEach { $0.cancel() }
        for transfer in transfers {
            _ = await transfer.result
        }
    }
}

struct SFTPFilePromisePayload: Identifiable, Sendable {
    let id: String
    let filename: String
    let fileType: UTType
    let prepare: @Sendable () async -> Void
    let write: @Sendable (URL) async throws -> Void

    init(
        id: String,
        filename: String,
        fileType: UTType,
        prepare: @escaping @Sendable () async -> Void = {},
        write: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.id = id
        self.filename = filename
        self.fileType = fileType
        self.prepare = prepare
        self.write = write
    }

    func fulfill(at destinationURL: URL) async throws {
        await prepare()
        try await PromiseWriteQueue.shared.perform {
            try await write(destinationURL)
        }
    }
}

struct SFTPFilePromiseDragSource: NSViewRepresentable {
    let payloads: [SFTPFilePromisePayload]

    func makeCoordinator() -> Coordinator {
        Coordinator(payloads: payloads)
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.setAccessibilityElement(false)
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.attachIfNeeded(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.payloads = payloads
        context.coordinator.attachIfNeeded(from: nsView)
    }

    static func dismantleNSView(_ nsView: AttachmentView, coordinator: Coordinator) {
        nsView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        var onHierarchyChange: (() -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onHierarchyChange?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onHierarchyChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSDraggingSource, NSGestureRecognizerDelegate {
        var payloads: [SFTPFilePromisePayload]

        private weak var attachedRow: NSView?
        private let panGesture: NSPanGestureRecognizer
        private var activePromiseIDs: [UUID] = []

        init(payloads: [SFTPFilePromisePayload]) {
            self.payloads = payloads
            panGesture = NSPanGestureRecognizer()
            super.init()
            panGesture.target = self
            panGesture.action = #selector(handlePan(_:))
            panGesture.delegate = self
            panGesture.buttonMask = 0x1
            panGesture.delaysPrimaryMouseButtonEvents = false
        }

        func attachIfNeeded(from marker: NSView) {
            guard let row = marker.firstAncestor(of: NSTableRowView.self),
                  row !== attachedRow else {
                return
            }
            detach()
            row.addGestureRecognizer(panGesture)
            attachedRow = row
        }

        func detach() {
            attachedRow?.removeGestureRecognizer(panGesture)
            attachedRow = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            !payloads.isEmpty
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard gesture.state == .began,
                  let sourceView = gesture.view,
                  let event = NSApp.currentEvent,
                  event.type == .leftMouseDragged,
                  !payloads.isEmpty else {
                return
            }

            let queue = OperationQueue()
            queue.name = "sh.glas.file-promise"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1

            let origin = gesture.location(in: sourceView)
            var promiseIDs: [UUID] = []
            let draggingItems = payloads.enumerated().map { index, payload in
                let promiseID = UUID()
                let delegate = PromiseDelegate(
                    id: promiseID,
                    payload: payload,
                    operationQueue: queue
                )
                PromiseRetention.shared.retain(delegate)
                promiseIDs.append(promiseID)

                let provider = NSFilePromiseProvider(
                    fileType: payload.fileType.identifier,
                    delegate: delegate
                )
                let item = NSDraggingItem(pasteboardWriter: provider)
                let image = NSWorkspace.shared.icon(for: payload.fileType)
                image.size = NSSize(width: 32, height: 32)
                let offset = CGFloat(min(index, 6)) * 3
                item.setDraggingFrame(
                    NSRect(
                        x: origin.x - 16 + offset,
                        y: origin.y - 16 - offset,
                        width: 32,
                        height: 32
                    ),
                    contents: image
                )
                return item
            }

            activePromiseIDs = promiseIDs
            let session = sourceView.beginDraggingSession(
                with: draggingItems,
                event: event,
                source: self
            )
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if operation.isEmpty {
                activePromiseIDs.forEach { PromiseRetention.shared.release($0) }
            }
            activePromiseIDs.removeAll()
        }
    }
}

struct SFTPTableClickTarget: NSViewRepresentable {
    let delayedSingleClick: @MainActor (_ wasSelectedBeforeClick: Bool) -> Void
    let doubleClick: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            delayedSingleClick: delayedSingleClick,
            doubleClick: doubleClick
        )
    }

    func makeNSView(context: Context) -> SFTPFilePromiseDragSource.AttachmentView {
        let view = SFTPFilePromiseDragSource.AttachmentView()
        view.setAccessibilityElement(false)
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.attachIfNeeded(from: view)
        }
        return view
    }

    func updateNSView(
        _ nsView: SFTPFilePromiseDragSource.AttachmentView,
        context: Context
    ) {
        context.coordinator.delayedSingleClick = delayedSingleClick
        context.coordinator.doubleClick = doubleClick
        context.coordinator.attachIfNeeded(from: nsView)
    }

    static func dismantleNSView(
        _ nsView: SFTPFilePromiseDragSource.AttachmentView,
        coordinator: Coordinator
    ) {
        nsView.onHierarchyChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var delayedSingleClick: @MainActor (_ wasSelectedBeforeClick: Bool) -> Void
        var doubleClick: @MainActor () -> Void

        private weak var attachedRow: NSTableRowView?
        private weak var markerView: NSView?
        private let singleClickGesture: SelectionTrackingClickGestureRecognizer
        private let doubleClickGesture: SelectionTrackingClickGestureRecognizer

        init(
            delayedSingleClick: @escaping @MainActor (_ wasSelectedBeforeClick: Bool) -> Void,
            doubleClick: @escaping @MainActor () -> Void
        ) {
            self.delayedSingleClick = delayedSingleClick
            self.doubleClick = doubleClick
            singleClickGesture = SelectionTrackingClickGestureRecognizer()
            doubleClickGesture = SelectionTrackingClickGestureRecognizer()
            super.init()
            singleClickGesture.target = self
            singleClickGesture.action = #selector(handleSingleClick(_:))
            singleClickGesture.numberOfClicksRequired = 1
            singleClickGesture.buttonMask = 0x1
            singleClickGesture.delaysPrimaryMouseButtonEvents = false
            singleClickGesture.delegate = self
            doubleClickGesture.target = self
            doubleClickGesture.action = #selector(handleDoubleClick(_:))
            doubleClickGesture.numberOfClicksRequired = 2
            doubleClickGesture.buttonMask = 0x1
            doubleClickGesture.delaysPrimaryMouseButtonEvents = false
            doubleClickGesture.delegate = self
        }

        func attachIfNeeded(from marker: NSView) {
            guard let row = marker.firstAncestor(of: NSTableRowView.self),
                  row !== attachedRow else {
                markerView = marker
                singleClickGesture.targetView = marker
                doubleClickGesture.targetView = marker
                return
            }
            detach()
            markerView = marker
            singleClickGesture.trackedRow = row
            singleClickGesture.targetView = marker
            doubleClickGesture.trackedRow = row
            doubleClickGesture.targetView = marker
            row.addGestureRecognizer(singleClickGesture)
            row.addGestureRecognizer(doubleClickGesture)
            attachedRow = row
        }

        func detach() {
            attachedRow?.removeGestureRecognizer(singleClickGesture)
            attachedRow?.removeGestureRecognizer(doubleClickGesture)
            attachedRow = nil
            markerView = nil
            singleClickGesture.trackedRow = nil
            singleClickGesture.targetView = nil
            doubleClickGesture.trackedRow = nil
            doubleClickGesture.targetView = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            gestureRecognizer === singleClickGesture
                && otherGestureRecognizer === doubleClickGesture
        }

        @objc private func handleSingleClick(_ gesture: SelectionTrackingClickGestureRecognizer) {
            guard gesture.state == .ended, gesture.beganInsideTarget else { return }
            delayedSingleClick(gesture.wasSelectedBeforeMouseDown)
        }

        @objc private func handleDoubleClick(_ gesture: SelectionTrackingClickGestureRecognizer) {
            guard gesture.state == .ended, gesture.beganInsideTarget else { return }
            doubleClick()
        }
    }
}

@MainActor
private final class SelectionTrackingClickGestureRecognizer: NSClickGestureRecognizer {
    weak var trackedRow: NSTableRowView?
    weak var targetView: NSView?
    private(set) var wasSelectedBeforeMouseDown = false
    private(set) var beganInsideTarget = false

    override func mouseDown(with event: NSEvent) {
        wasSelectedBeforeMouseDown = trackedRow?.isSelected == true
        if let targetView {
            let point = targetView.convert(event.locationInWindow, from: nil)
            beganInsideTarget = targetView.bounds.contains(point)
        } else {
            beganInsideTarget = false
        }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class PromiseRetention {
    static let shared = PromiseRetention()

    private var delegates: [UUID: PromiseDelegate] = [:]

    func retain(_ delegate: PromiseDelegate) {
        delegates[delegate.id] = delegate
    }

    func release(_ id: UUID) {
        delegates.removeValue(forKey: id)
    }
}

private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let id: UUID

    private let payload: SFTPFilePromisePayload
    private let operationQueue: OperationQueue

    init(
        id: UUID,
        payload: SFTPFilePromisePayload,
        operationQueue: OperationQueue
    ) {
        self.id = id
        self.payload = payload
        self.operationQueue = operationQueue
    }

    @MainActor
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        payload.filename
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let payload = payload
        let id = id
        let completion = PromiseCompletion(completionHandler)

        Task {
            do {
                try await payload.fulfill(at: url)
                completion.call(nil)
            } catch {
                completion.call(error)
            }
            await MainActor.run {
                PromiseRetention.shared.release(id)
            }
        }
    }

    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        operationQueue
    }
}

private actor PromiseWriteQueue {
    static let shared = PromiseWriteQueue()

    private var tail: Task<Void, Never>?

    func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let predecessor = tail
        let current = Task<Void, Error> {
            if let predecessor {
                await predecessor.value
            }
            try await operation()
        }
        tail = Task {
            _ = await current.result
        }
        try await current.value
    }
}

nonisolated private struct PromiseCompletion: @unchecked Sendable {
    let call: (Error?) -> Void

    init(_ call: @escaping (Error?) -> Void) {
        self.call = call
    }
}

private extension NSView {
    func firstAncestor<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        var candidate = superview
        while let view = candidate {
            if let match = view as? ViewType {
                return match
            }
            candidate = view.superview
        }
        return nil
    }
}

#endif
