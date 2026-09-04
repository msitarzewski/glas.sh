//
//  SFTPBrowserView.swift
//  glas.sh
//
//  SFTP file browser for remote servers
//

import SwiftUI
import Citadel
import NIOCore
import NIOFoundationCompat
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import GlassEditorCore
import GlassEditorUI

#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

nonisolated private enum SFTPTransferError: LocalizedError {
    case unsafeName
    case destinationEscapesFolder
    case cannotCreateTemporaryFile
    case missingRemoteSize
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case checksumMismatch
    case atomicCommitUnavailable
    case atomicReplacementUnavailable
    case invalidResumePartial
    case sourceChanged
    case remoteSourceChanged
    case remoteFileIsNotRegular
    case invalidResumeMetadata
    case resumeMetadataCapacityReached

    var errorDescription: String? {
        switch self {
        case .unsafeName:
            return "The file name is not a safe basename."
        case .destinationEscapesFolder:
            return "The destination is outside the selected folder."
        case .cannotCreateTemporaryFile:
            return "A protected temporary file could not be created."
        case .missingRemoteSize:
            return "The server did not report a file size for transfer verification."
        case .sizeMismatch(let expected, let actual):
            return "Transfer size mismatch (expected \(expected) bytes, received \(actual))."
        case .checksumMismatch:
            return "The remote file checksum did not match the local source."
        case .atomicCommitUnavailable:
            return "This server does not advertise atomic no-clobber upload support."
        case .atomicReplacementUnavailable:
            return "This server does not advertise atomic remote-file replacement support."
        case .invalidResumePartial:
            return "The interrupted transfer could not be resumed because its partial content no longer matches the source."
        case .sourceChanged:
            return "The local source changed during upload. Select it again to start a verified transfer."
        case .remoteSourceChanged:
            return "The remote source changed during download. Start the download again."
        case .remoteFileIsNotRegular:
            return "The remote path is not a regular file."
        case .invalidResumeMetadata:
            return "The protected upload recovery record is invalid and must be resolved before retrying."
        case .resumeMetadataCapacityReached:
            return "The upload recovery limit has been reached. Resolve retained partial uploads before starting another."
        }
    }
}

nonisolated private enum SFTPLocalOpenError: Error {
    case notFound
}

nonisolated private struct SFTPUploadWorkerFailure: LocalizedError, Sendable {
    enum Kind: Sendable {
        case general
        case cancelled
        case remoteTargetChanged
        case commitOutcomeUnknown
    }

    let message: String
    let kind: Kind

    init(message: String, kind: Kind = .general) {
        self.message = message
        self.kind = kind
    }

    var errorDescription: String? { message }
}

nonisolated private enum SFTPUploadCommitPolicy: Sendable {
    case createNoClobber
    case replaceExisting(expectedStat: RemoteStat, expectedDigest: ContentDigest)
}

nonisolated private enum SFTPLocalUploadSource: Sendable {
    case fileImporter
    case fileDrop
}

nonisolated private struct SFTPRemoteCommitGuardFailure: Error, Sendable {}

nonisolated private struct SFTPUploadResult: Sendable {
    let cleanupWarning: Bool
    let committedStat: RemoteStat?
    let committedDigest: ContentDigest
}

nonisolated private struct SFTPDownloadWorkerFailure: LocalizedError, Sendable {
    let underlyingDescription: String
    let partialWasRetained: Bool
    let wasCancelled: Bool

    private var retentionDescription: String {
        partialWasRetained
            ? " A protected partial was retained and will be validated before any future resume."
            : " No partial file was kept."
    }

    var errorDescription: String? {
        wasCancelled
            ? "Download cancelled.\(retentionDescription)"
            : "\(underlyingDescription)\(retentionDescription)"
    }

    func userFacingDescription(filename: String) -> String {
        if wasCancelled {
            return "Download cancelled.\(retentionDescription)"
        }
        return "Download of \(filename) failed: \(underlyingDescription)\(retentionDescription)"
    }
}

nonisolated struct SFTPDownloadReadBatchDecision: Equatable, Sendable {
    let acceptedResponseCount: Int
    let nextChunkSize: UInt32?
    let reachedEOF: Bool
}

nonisolated private enum SFTPLocalProtectionClass: Int32 {
    // Darwin content-protection classes A and B. Using F_SETPROTECTIONCLASS
    // applies the policy to the already-open inode without resolving a path.
    case complete = 1
    case completeUnlessOpen = 2
}

nonisolated struct SFTPLocalFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    var modificationTime: TimeInterval {
        TimeInterval(modificationSeconds) + TimeInterval(modificationNanoseconds) / 1_000_000_000
    }

    func isSameFile(as other: SFTPLocalFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

nonisolated struct SFTPLocalDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated struct SFTPUploadResumeRecord: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    var updatedAt: Date
    let serverID: UUID
    let remoteDirectory: String
    let finalName: String
    let sourceName: String
    let sourceSize: UInt64
    let sourceModificationTime: TimeInterval
    let partialName: String

    func matches(
        serverID: UUID,
        remoteDirectory: String,
        finalName: String,
        sourceName: String,
        sourceSize: UInt64,
        sourceModificationTime: TimeInterval
    ) -> Bool {
        version == Self.currentVersion
            && self.serverID == serverID
            && self.remoteDirectory == remoteDirectory
            && self.finalName == finalName
            && self.sourceName == sourceName
            && self.sourceSize == sourceSize
            && self.sourceModificationTime == sourceModificationTime
            && SFTPBrowserView.isSafeBasename(partialName)
            && partialName.hasPrefix(".glas-sh-upload-")
            && partialName.hasSuffix(".partial")
    }
}

nonisolated enum SFTPLocalResumeDecision: Equatable, Sendable {
    case create
    case resume(offset: UInt64)
    case replaceOversized
    case rejectUnsafe
}

#if os(macOS)
nonisolated struct SFTPBrowserTableEntry: Identifiable, Sendable {
    let entry: SFTPPathComponent
    let isDirectory: Bool

    var id: String { entry.filename }
}

nonisolated struct SFTPBrowserTableSortComparator: SortComparator, Sendable {
    enum Column: Hashable, Sendable {
        case name
        case size
        case modified
        case permissions
    }

    let column: Column
    var order: SortOrder

    init(column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(
        _ lhs: SFTPBrowserTableEntry,
        _ rhs: SFTPBrowserTableEntry
    ) -> ComparisonResult {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory ? .orderedAscending : .orderedDescending
        }

        let columnResult = switch column {
        case .name:
            ordered(lhs.entry.filename.localizedStandardCompare(rhs.entry.filename))
        case .size:
            compareOptional(lhs.entry.attributes.size, rhs.entry.attributes.size)
        case .modified:
            compareOptional(
                lhs.entry.attributes.accessModificationTime?.modificationTime,
                rhs.entry.attributes.accessModificationTime?.modificationTime
            )
        case .permissions:
            compareOptional(
                lhs.entry.attributes.permissions,
                rhs.entry.attributes.permissions
            )
        }

        if columnResult != .orderedSame { return columnResult }
        return lhs.entry.filename.localizedStandardCompare(rhs.entry.filename)
    }

    private func compareOptional<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case (.some(let lhs), .some(let rhs)):
            if lhs < rhs { return ordered(.orderedAscending) }
            if lhs > rhs { return ordered(.orderedDescending) }
            return .orderedSame
        }
    }

    private func ordered(_ result: ComparisonResult) -> ComparisonResult {
        order == .forward ? result : result.reversed
    }
}

nonisolated private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedSame: .orderedSame
        case .orderedDescending: .orderedAscending
        }
    }
}
#endif

nonisolated private enum SFTPRemoteOperationKind: String, Sendable {
    case copy = "Copy"
    case move = "Move"
}

nonisolated enum SFTPRemoteOperationPhase: Sendable {
    case inspectDestination
    case readSource
    case createStaging
    case verifySource
    case verifyStaging
    case publishDestination
    case prepareStagingMetadata
    case preserveMetadata
    case retireSource
    case verifyRetiredSource
    case removeRetiredSource
    case cleanupStaging

    func failureMessage(path: String, serverDescription: String) -> String {
        let serverResponse = "Server response: \(serverDescription)"
        switch self {
        case .inspectDestination:
            return "Could not inspect the remote destination \"\(path)\". Check search permission on that folder and its parents. \(serverResponse) No changes were made."
        case .readSource:
            return "Could not read the remote source \"\(path)\". Check read permission on files and search permission on source folders. \(serverResponse) No destination was published."
        case .createStaging:
            return "Could not create a protected staging item in \"\(path)\". Check write and search permission on the destination folder. \(serverResponse) No existing destination was overwritten."
        case .verifySource:
            return "Could not re-read the remote source \"\(path)\" for verification. Check read and search permission, then retry. \(serverResponse) The copy was not published."
        case .verifyStaging:
            return "Could not verify the protected staging copy at \"\(path)\". Check read and search permission on the destination. \(serverResponse) No final destination was published."
        case .publishDestination:
            return "The verified copy could not be published at \"\(path)\". Check write and search permission on the destination folder. \(serverResponse) No existing destination was overwritten; a hidden staging item may remain."
        case .prepareStagingMetadata:
            return "The bytes were copied into protected staging at \"\(path)\", but the original permissions or timestamps could not be applied. Check permission to change remote metadata. \(serverResponse) No final destination was published; a hidden staging item may remain."
        case .preserveMetadata:
            return "The copied bytes were published at \"\(path)\", but the original permissions or timestamps could not be applied. Check permission to change remote metadata. \(serverResponse) The destination exists and may use server-default metadata."
        case .retireSource:
            return "The verified destination was created, but the source \"\(path)\" could not be renamed for safe cleanup. Check write and search permission on its parent folder, including sticky-bit and ACL rules. \(serverResponse) The original source remains."
        case .verifyRetiredSource:
            return "The verified destination was created, but the retained source at \"\(path)\" could not be proven identical to the copied source. \(serverResponse) The retained source was not deleted and may require manual recovery."
        case .removeRetiredSource:
            return "The verified destination was created, but the retained source \"\(path)\" could not be removed. Check delete permission throughout the retained tree. \(serverResponse) Both the destination and retained source remain."
        case .cleanupStaging:
            return "The copy was published at \"\(path)\", but its hidden staging item could not be removed. Check delete permission on the destination folder. \(serverResponse) The verified destination remains available."
        }
    }
}

private struct SFTPRemoteOperationRequest: Identifiable {
    let id = UUID()
    let kind: SFTPRemoteOperationKind
    let sourceDirectory: String
    let entries: [SFTPPathComponent]
}

nonisolated private enum SFTPRemoteOperationError: LocalizedError {
    case destinationCollision(String)
    case destinationInsideSource
    case unsupportedItem(String)
    case tooManyEntries(Int)
    case aggregateSizeExceeded(UInt64)
    case sourceChanged(String)
    case verificationFailed(String)
    case remoteCommandUnavailable

    var errorDescription: String? {
        switch self {
        case .destinationCollision(let name):
            return "The destination already contains \"\(name)\". Nothing was overwritten."
        case .destinationInsideSource:
            return "A folder cannot be copied or moved into itself or one of its descendants."
        case .unsupportedItem(let name):
            return "\"\(name)\" is a symbolic link or special file and cannot be copied safely yet."
        case .tooManyEntries(let maximum):
            return "The remote operation exceeded its \(maximum)-item safety limit."
        case .aggregateSizeExceeded(let maximum):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(clamping: maximum), countStyle: .file)
            return "The remote operation exceeded its \(limit) transfer limit."
        case .sourceChanged(let name):
            return "\"\(name)\" changed while it was being copied. The copy was not published."
        case .verificationFailed(let name):
            return "The copied bytes for \"\(name)\" did not match the source. The copy was not published."
        case .remoteCommandUnavailable:
            return "The server does not permit the required remote copy command."
        }
    }
}

nonisolated struct SFTPRemoteManifestEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
    }

    let relativePath: String
    let kind: Kind
    let size: UInt64
    let permissions: UInt32?
    let accessTime: Date?
    let modificationTime: Date?
    let digest: Data?
}

struct SFTPBrowserView: View {
    let sessionID: UUID
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var sftpClient: SFTPClient?
    @State private var currentPath: String = "/"
    @State private var entries: [SFTPPathComponent] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var navigationStack: [String] = ["/"]

    // File operations
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showingFileImporter = false
    @State private var showingFolderPicker = false
    @State private var pendingDownloads: [SFTPPathComponent] = []
    @State private var transferActivity = SFTPTransferActivityStore()
    @State private var transferActivityIsExpanded = false
    @State private var showingDeleteConfirmation = false
    @State private var entryToDelete: SFTPPathComponent?
    @State private var showingRenamePrompt = false
    @State private var entryToRename: SFTPPathComponent?
    @State private var renameDraft = ""
    @State private var inlineRenameFilename: String?
    @State private var operationInProgress: String?
    @State private var transferTask: Task<Void, Never>?
    @FocusState private var focusedRenameFilename: String?

    // Selection
    @State private var selectedFilenames: Set<String> = []
    @State private var showingFileInfo: SFTPPathComponent?
    @State private var refreshedFileInfoAttributes: SFTPFileAttributes?
    @State private var fileInfoRefreshError: String?
    @State private var fileInfoGeneralExpanded = true
    @State private var fileInfoNetworkExpanded = true
    @State private var fileInfoNameExpanded = false
    @State private var fileInfoEditorExpanded = false
    @State private var fileInfoPermissionsExpanded = true
    @State private var fileInfoRawExpanded = false
    @State private var remoteEditorDocument: SFTPRemoteEditorDocument?
    @State private var showingBatchDeleteConfirmation = false
    @State private var isReceivingFileDrop = false
    #if os(macOS)
    @State private var filePromiseTransfers = SFTPFilePromiseTransferRegistry()
    @State private var macOSTableSortOrder = [
        SFTPBrowserTableSortComparator(column: .name)
    ]
    #endif

    // Remote copy / move destination browsing
    @State private var remoteOperationRequest: SFTPRemoteOperationRequest?
    @State private var remoteDestinationPath = "/"
    @State private var remoteDestinationEntries: [SFTPPathComponent] = []
    @State private var remoteDestinationIsLoading = false
    @State private var remoteDestinationError: String?
    @State private var remoteOperationFailureMessage: String?

    // Filtering
    @State private var showHiddenFiles = false
    @State private var filterText = ""
    @State private var isSearchingRemote = false
    @State private var searchResults: [String] = []
    @State private var showingSearchResults = false

    private var session: TerminalSession? {
        sessionManager.session(for: sessionID)
    }

    private var remoteOperationFailureBinding: Binding<Bool> {
        Binding(
            get: { remoteOperationFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    remoteOperationFailureMessage = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(currentPath)
                .searchable(text: $filterText, prompt: "Filter files...")
                .terminalTextInputDefaults()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sftpBottomShelf
                }
                .onSubmit(of: .search) {
                    if !filterText.isEmpty {
                        Task { await remoteFind(filterText) }
                    }
                }
                .onChange(of: filterText) { _, newValue in
                    if newValue.isEmpty {
                        showingSearchResults = false
                        searchResults = []
                    }
                }
                .toolbar { toolbarContent }
        }
        .task { await connectAndLoad() }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            transferTask = Task { await handleFileImport(result) }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            transferTask = Task { await handleFolderSelection(result) }
        }
        .onDisappear {
            Task { _ = await shutdownTransferAndConnection() }
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                Task { await createFolder(named: newFolderName) }
            }
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert("Delete Item?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    Task { await deleteEntry(entry) }
                }
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let entry = entryToDelete {
                Text("Are you sure you want to delete \"\(entry.filename)\"? This cannot be undone.")
            }
        }
        .alert("Delete \(selectedFilenames.count) Items?", isPresented: $showingBatchDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
                Task { await deleteSelectedFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \(selectedFilenames.count) selected items? This cannot be undone.")
        }
        .alert("Rename", isPresented: $showingRenamePrompt) {
            TextField("New name", text: $renameDraft)
            Button("Rename") {
                commitPromptedRename()
            }
            .disabled(!Self.isSafeBasename(renameDraft))
            Button("Cancel", role: .cancel) {
                cancelRename()
            }
        } message: {
            if let entryToRename {
                Text("Enter a new name for \"\(entryToRename.filename)\".")
            }
        }
        .alert("Remote Operation", isPresented: remoteOperationFailureBinding) {
            Button("OK") {
                remoteOperationFailureMessage = nil
            }
        } message: {
            if let remoteOperationFailureMessage {
                Text(remoteOperationFailureMessage)
            }
        }
        .sheet(isPresented: fileInfoBinding) {
            if let entry = showingFileInfo {
                fileInfoSheet(for: entry)
                    .task(id: entry.filename) {
                        await refreshFileInfo(for: entry)
                    }
            }
        }
        .sheet(item: $remoteOperationRequest) { request in
            remoteDestinationSheet(for: request)
        }
        .sheet(item: $remoteEditorDocument) { document in
            SFTPRemoteEditorView(
                document: document,
                surfaceCondition: remoteEditorSurfaceCondition,
                save: { observation in
                    await saveRemoteEditor(document, authorizedObservation: observation)
                },
                checkRemote: {
                    await checkRemoteEditor(document)
                },
                resolveConflict: { resolution, observation in
                    await resolveRemoteEditorConflict(
                        resolution,
                        document: document,
                        observation: observation
                    )
                },
                localCopySaved: {
                    await reloadRemoteEditor(document)
                },
                close: {
                    remoteEditorDocument = nil
                }
            )
        }
        .onChange(of: selectedFilenames) { _, selection in
            if let inlineRenameFilename,
               selection != Set([inlineRenameFilename]) {
                cancelRename()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = error {
            ContentUnavailableView {
                Label("Connection Error", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    self.error = nil
                    Task { await connectAndLoad() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if isLoading && entries.isEmpty {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("Empty Directory", systemImage: "folder")
            } description: {
                Text("This directory contains no files.")
            }
        } else {
            fileList
        }
    }

    @ViewBuilder
    private var sftpBottomShelf: some View {
        if !selectedFilenames.isEmpty
            || operationInProgress != nil
            || transferActivity.hasActivities {
            VStack(spacing: 0) {
                if !selectedFilenames.isEmpty {
                    selectionBar
                        .padding(8)
                }

                if let operationInProgress,
                   !(transferTask != nil && transferActivity.hasActivities),
                   !transferActivity.hasInFlightActivities {
                    Divider()
                    transientOperationStatus(operationInProgress)
                }

                if transferActivity.hasActivities {
                    Divider()
                    transferActivityShelf
                }
            }
            .background(.bar)
        }
    }

    private func transientOperationStatus(_ description: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(description)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            if transferTask != nil {
                Button("Cancel", role: .cancel) {
                    transferTask?.cancel()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var transferActivityShelf: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        transferActivityIsExpanded.toggle()
                    }
                } label: {
                    transferActivitySummary
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(transferActivity.headline)
                .accessibilityValue(
                    transferActivityIsExpanded ? "Expanded" : "Collapsed"
                )
                .accessibilityHint(
                    transferActivityIsExpanded
                        ? "Collapses transfer activity"
                        : "Shows pending and recent transfers"
                )

                if transferTask != nil, transferActivity.hasInFlightActivities {
                    Button {
                        transferTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel current transfer batch")
                    #if os(visionOS)
                    .frame(minWidth: 60, minHeight: 60)
                    #endif
                }
            }
            .padding(.horizontal, 14)
            #if os(visionOS)
            .frame(minHeight: 60)
            #else
            .frame(minHeight: 40)
            #endif

            if transferActivityIsExpanded {
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transferActivity.displayedActivities) { activity in
                            transferActivityRow(activity)
                            if activity.id != transferActivity.displayedActivities.last?.id {
                                Divider()
                                    .padding(.leading, 46)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)

                if transferActivity.hasTerminalActivities {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Clear History") {
                            transferActivity.clearTerminalActivities()
                            if !transferActivity.hasActivities {
                                transferActivityIsExpanded = false
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        #if os(visionOS)
                        .frame(minHeight: 60)
                        #endif
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var transferActivitySummary: some View {
        HStack(spacing: 8) {
            if let active = transferActivity.activeActivity {
                Image(systemName: active.kind.systemImage)
                    .foregroundStyle(.secondary)
                Text(transferActivity.headline)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress = active.progress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text(active.statusLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(active.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if transferActivity.pendingCount > 0 {
                    Text("\(transferActivity.pendingCount) waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: transferSummarySystemImage)
                    .foregroundStyle(transferSummaryColor)
                Text(transferActivity.headline)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            Image(systemName: transferActivityIsExpanded ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func transferActivityRow(_ activity: SFTPTransferActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transferStatusSystemImage(activity.state))
                .foregroundStyle(transferStatusColor(activity.state))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.filename)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(activity.statusLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(activity.kind.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let progress = activity.progress {
                    ProgressView(value: progress)
                        .accessibilityValue(activity.statusLabel)
                }

                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(
                            activity.state == .failed ? Color.red : Color.secondary
                        )
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var transferSummarySystemImage: String {
        if transferActivity.activities.contains(where: { $0.state == .failed }) {
            return "exclamationmark.circle.fill"
        }
        if transferActivity.pendingCount > 0 { return "clock" }
        if transferActivity.activities.contains(where: { $0.state == .cancelled }),
           !transferActivity.activities.contains(where: { $0.state == .completed }) {
            return "xmark.circle"
        }
        return "checkmark.circle.fill"
    }

    private var transferSummaryColor: Color {
        transferActivity.activities.contains(where: { $0.state == .failed })
            ? .red
            : .secondary
    }

    private func transferStatusSystemImage(_ state: SFTPTransferActivityState) -> String {
        switch state {
        case .pending: "clock"
        case .transferring: "arrow.left.arrow.right.circle"
        case .verifying: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func transferStatusColor(_ state: SFTPTransferActivityState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .pending, .transferring, .verifying: .accentColor
        }
    }

    private var fileList: some View {
        Group {
            #if os(macOS)
            macOSFileTable
            #else
            List {
                fileListRows
            }
            #endif
        }
        .listStyle(.plain)
        .refreshable {
            await loadDirectory()
        }
        #if os(macOS)
        .dropDestination(
            for: URL.self,
            isEnabled: canAcceptFileDrop
        ) { urls, _ in
            beginFileDropUpload(urls)
        }
        .onDropSessionUpdated { session in
            guard session.localSession == nil else {
                isReceivingFileDrop = false
                return
            }
            switch session.phase {
            case .entering, .active:
                isReceivingFileDrop = true
            case .exiting, .ended, .dataTransferCompleted:
                isReceivingFileDrop = false
            @unknown default:
                isReceivingFileDrop = false
            }
        }
        .overlay {
            if isReceivingFileDrop {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #endif
    }

    #if os(macOS)
    private var macOSFileTable: some View {
        VStack(spacing: 0) {
            if showingSearchResults {
                List {
                    searchResultsSection
                }
                .listStyle(.plain)
                .frame(height: 180)

                Divider()
            }

            if navigationStack.count > 1 {
                Button {
                    navigateUp()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.up.left")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Parent Directory")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Divider()
            }

            Table(
                macOSTableEntries,
                selection: $selectedFilenames,
                sortOrder: $macOSTableSortOrder
            ) {
                TableColumn(
                    "Name",
                    sortUsing: SFTPBrowserTableSortComparator(column: .name)
                ) { tableEntry in
                    macOSTableNameCell(for: tableEntry.entry)
                }
                .width(min: 220, ideal: 360)

                TableColumn(
                    "Size",
                    sortUsing: SFTPBrowserTableSortComparator(column: .size)
                ) { tableEntry in
                    macOSTableSizeCell(for: tableEntry.entry)
                }
                .width(min: 70, ideal: 90, max: 120)

                TableColumn(
                    "Modified",
                    sortUsing: SFTPBrowserTableSortComparator(column: .modified)
                ) { tableEntry in
                    macOSTableModifiedCell(for: tableEntry.entry)
                }
                .width(min: 120, ideal: 150, max: 190)

                TableColumn(
                    "Permissions",
                    sortUsing: SFTPBrowserTableSortComparator(column: .permissions)
                ) { tableEntry in
                    macOSTablePermissionsCell(for: tableEntry.entry)
                }
                .width(min: 92, ideal: 108, max: 130)

                TableColumn("Actions") { tableEntry in
                    macOSTableActionsCell(for: tableEntry.entry)
                }
                .width(min: 128, ideal: 140, max: 156)
            }
            .contextMenu(forSelectionType: String.self) { filenames in
                selectionContextMenu(for: contextEntries(for: filenames), includesClipboardCopy: false)
            }
            .copyable(clipboardURLs(for: selectedFilenames))
        }
    }

    private var macOSTableEntries: [SFTPBrowserTableEntry] {
        let tableEntries = sortedEntries.map {
            SFTPBrowserTableEntry(entry: $0, isDirectory: isDirectory($0))
        }
        guard !macOSTableSortOrder.isEmpty else { return tableEntries }
        return tableEntries.sorted(using: macOSTableSortOrder)
    }

    private func macOSTableNameCell(for entry: SFTPPathComponent) -> some View {
        let isDir = isDirectory(entry)

        return HStack(spacing: 8) {
            Image(systemName: iconName(for: entry))
                .foregroundStyle(isDir ? .blue : .secondary)
                .frame(width: 20)

            if inlineRenameFilename == entry.filename {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedRenameFilename, equals: entry.filename)
                    .onSubmit {
                        commitInlineRename(entry)
                    }
                    .onExitCommand {
                        cancelRename()
                    }
            } else {
                Text(entry.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .background {
            ZStack {
                SFTPTableClickTarget(
                    delayedSingleClick: { wasSelectedBeforeClick in
                        handleDelayedTableClick(
                            entry,
                            wasSelectedBeforeClick: wasSelectedBeforeClick
                        )
                    },
                    doubleClick: {
                        guard isDir else { return }
                        cancelRename()
                        Task { await handleEntryTap(entry) }
                    }
                )

                if !isDir {
                    SFTPFilePromiseDragSource(
                        payloads: filePromisePayloads(for: entry)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func macOSTableSizeCell(for entry: SFTPPathComponent) -> some View {
        if isDirectory(entry) {
            Text("—")
                .foregroundStyle(.tertiary)
        } else if let size = entry.attributes.size {
            Text(formattedFileSize(size))
                .monospacedDigit()
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func macOSTableModifiedCell(for entry: SFTPPathComponent) -> some View {
        if let time = entry.attributes.accessModificationTime {
            Text(formattedDate(time.modificationTime))
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func macOSTablePermissionsCell(for entry: SFTPPathComponent) -> some View {
        if let permissions = entry.attributes.permissions {
            Text(formattedPermissions(permissions))
                .font(.body.monospaced())
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    private func macOSTableActionsCell(for entry: SFTPPathComponent) -> some View {
        HStack(spacing: 10) {
            if !isDirectory(entry) {
                Button {
                    beginRemoteEdit(entry)
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit \(entry.filename)")

                Button {
                    startDownload(entry)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Download \(entry.filename)")
            }

            Button {
                presentFileInfo(entry)
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Info for \(entry.filename)")
        }
        .buttonStyle(.borderless)
    }
    #endif

    @ViewBuilder
    private var fileListRows: some View {
        if showingSearchResults {
            searchResultsSection
        }

        if navigationStack.count > 1 {
            Button {
                navigateUp()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.turn.up.left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text("Parent Directory")
                        .foregroundStyle(.secondary)
                }
            }
        }

        ForEach(sortedEntries, id: \.filename) { entry in
            fileListRow(for: entry)
                .contextMenu {
                    selectionContextMenu(
                        for: contextEntries(for: entry),
                        includesClipboardCopy: true
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        entryToDelete = entry
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func fileListRow(for entry: SFTPPathComponent) -> some View {
        #if os(macOS)
        if isDirectory(entry) {
            fileRow(for: entry)
        } else {
            fileRow(for: entry)
                .tag(entry.filename)
                .background {
                    SFTPFilePromiseDragSource(
                        payloads: filePromisePayloads(for: entry)
                    )
                }
        }
        #else
        fileRow(for: entry)
        #endif
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedFilenames.count) selected")
                .font(.caption.weight(.semibold))

            Divider().frame(height: 16)

            Button {
                Task { await downloadSelectedFiles() }
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!selectionContainsFile)

            Button(role: .destructive) {
                showingBatchDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider().frame(height: 16)

            Button("Deselect All") {
                selectedFilenames.removeAll()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        #if os(visionOS)
        .background(.ultraThinMaterial, in: Capsule())
        #else
        .glassEffect(.regular, in: .capsule)
        #endif
    }

    #if os(macOS)
    private func filePromisePayloads(for entry: SFTPPathComponent) -> [SFTPFilePromisePayload] {
        guard let client = sftpClient,
              transferTask == nil,
              operationInProgress == nil else {
            return []
        }

        let draggedEntries: [SFTPPathComponent]
        if selectedFilenames.contains(entry.filename) {
            draggedEntries = sortedEntries.filter {
                !isDirectory($0) && selectedFilenames.contains($0.filename)
            }
        } else {
            draggedEntries = [entry]
        }

        let serverID = session?.server.id ?? sessionID
        let filePromiseTransfers = filePromiseTransfers
        let transferActivity = transferActivity
        return draggedEntries.map { draggedEntry in
            let filename = draggedEntry.filename
            let remotePath = remotePath(for: filename)
            let activityID = UUID()
            let fileType = UTType(filenameExtension: (filename as NSString).pathExtension)
                ?? .data

            return SFTPFilePromisePayload(
                id: remotePath,
                filename: filename,
                fileType: fileType,
                prepare: {
                    await transferActivity.enqueue(
                        id: activityID,
                        kind: .finderDownload,
                        filename: filename,
                        totalBytes: draggedEntry.attributes.size
                    )
                }
            ) { destinationURL in
                await transferActivity.begin(activityID)
                do {
                    try await filePromiseTransfers.perform {
                        try await Self.writePromisedRemoteFile(
                            client: client,
                            serverID: serverID,
                            remotePath: remotePath,
                            sourceName: filename,
                            destinationURL: destinationURL
                        ) { progress in
                            transferActivity.apply(progress, to: activityID)
                        }
                    }
                    await transferActivity.complete(activityID)
                } catch let failure as SFTPDownloadWorkerFailure {
                    if failure.wasCancelled {
                        await transferActivity.cancel(
                            activityID,
                            detail: failure.localizedDescription
                        )
                    } else {
                        await transferActivity.fail(
                            activityID,
                            detail: failure.localizedDescription
                        )
                    }
                    throw failure
                } catch {
                    if error is CancellationError {
                        await transferActivity.cancel(
                            activityID,
                            detail: "Finder download cancelled."
                        )
                    } else {
                        await transferActivity.fail(
                            activityID,
                            detail: error.localizedDescription
                        )
                    }
                    throw error
                }
            }
        }
    }
    #endif

    private var sortedEntries: [SFTPPathComponent] {
        entries
            .filter { $0.filename != "." && $0.filename != ".." }
            .filter { showHiddenFiles || !$0.filename.hasPrefix(".") }
            .filter {
                filterText.isEmpty || $0.filename.localizedCaseInsensitiveContains(filterText)
            }
            .sorted { lhs, rhs in
                let lhsIsDir = isDirectory(lhs)
                let rhsIsDir = isDirectory(rhs)
                if lhsIsDir != rhsIsDir {
                    return lhsIsDir
                }
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }
    }

    private var selectionContainsFile: Bool {
        sortedEntries.contains {
            !isDirectory($0) && selectedFilenames.contains($0.filename)
        }
    }

    private var selectableEntries: [SFTPPathComponent] {
        #if os(macOS)
        sortedEntries
        #else
        sortedEntries.filter { !isDirectory($0) }
        #endif
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(for entry: SFTPPathComponent) -> some View {
        let isDir = isDirectory(entry)
        let isSelected = selectedFilenames.contains(entry.filename)

        let row = HStack(spacing: 12) {
            #if !os(macOS)
            if !isDir {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.blue : Color.gray.opacity(0.4))
                    .frame(width: 24)
            }
            #endif

            Image(systemName: iconName(for: entry))
                .font(.title3)
                .foregroundStyle(isDir ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let size = entry.attributes.size, !isDir {
                        Text(formattedFileSize(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let permissions = entry.attributes.permissions {
                        Text(formattedPermissions(permissions))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    if let time = entry.attributes.accessModificationTime {
                        Text(formattedDate(time.modificationTime))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if isDir {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    beginRemoteEdit(entry)
                } label: {
                    Image(systemName: "pencil")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(entry.filename)")

                Button {
                    showingFileInfo = entry
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Info for \(entry.filename)")

                Button {
                    startDownload(entry)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(entry.filename)")
            }
        }
        .contentShape(Rectangle())

        if isDir {
            row.onTapGesture {
                Task { await handleEntryTap(entry) }
            }
        } else {
            #if os(macOS)
            row
            #else
            row.onTapGesture {
                toggleSelection(entry.filename)
            }
            #endif
        }
    }

    @MainActor
    @discardableResult
    private func shutdownTransferAndConnection() async -> Bool {
        let activeTransfer = transferTask
        transferTask = nil
        activeTransfer?.cancel()
        await activeTransfer?.value

        #if os(macOS)
        await filePromiseTransfers.cancelAllAndWait()
        #endif

        let activeClient = sftpClient
        guard let activeClient else { return true }
        do {
            try await activeClient.close()
            sftpClient = nil
            return true
        } catch {
            self.error = "The SFTP connection could not be closed cleanly. Try Done again before leaving this window."
            return false
        }
    }

    private func toggleSelection(_ filename: String) {
        if selectedFilenames.contains(filename) {
            selectedFilenames.remove(filename)
        } else {
            selectedFilenames.insert(filename)
        }
    }

    private func contextEntries(for filenames: Set<String>) -> [SFTPPathComponent] {
        let effectiveNames = filenames.isEmpty ? selectedFilenames : filenames
        return sortedEntries.filter { effectiveNames.contains($0.filename) }
    }

    private func contextEntries(for entry: SFTPPathComponent) -> [SFTPPathComponent] {
        guard selectedFilenames.contains(entry.filename) else { return [entry] }
        let selectedEntries = sortedEntries.filter { selectedFilenames.contains($0.filename) }
        return selectedEntries.isEmpty ? [entry] : selectedEntries
    }

    @ViewBuilder
    private func selectionContextMenu(
        for targetEntries: [SFTPPathComponent],
        includesClipboardCopy: Bool
    ) -> some View {
        if !targetEntries.isEmpty {
            if targetEntries.count == 1, let entry = targetEntries.first {
                if isDirectory(entry) {
                    Button("Open") {
                        Task { await handleEntryTap(entry) }
                    }
                } else {
                    Button("Edit") {
                        beginRemoteEdit(entry)
                    }
                }
            }

            if includesClipboardCopy {
                Button("Copy") {
                    copyRemoteReferences(targetEntries)
                }
                .keyboardShortcut("c", modifiers: .command)
            }

            Menu("Remote") {
                Button("Copy…") {
                    beginRemoteOperation(.copy, entries: targetEntries)
                }
                Button("Move…") {
                    beginRemoteOperation(.move, entries: targetEntries)
                }
            }
            .disabled(operationInProgress != nil || transferTask != nil)

            Divider()

            if targetEntries.count == 1, let entry = targetEntries.first {
                Button("Rename") {
                    beginRename(entry)
                }
                Button("Get Info") {
                    presentFileInfo(entry)
                }
            }

            if targetEntries.contains(where: { !isDirectory($0) }) {
                Button("Download") {
                    beginDownload(targetEntries)
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                prepareDeletion(of: targetEntries)
            }
        }
    }

    private func beginDownload(_ targetEntries: [SFTPPathComponent]) {
        let files = targetEntries.filter { !isDirectory($0) }
        guard !files.isEmpty else { return }
        pendingDownloads = files
        showingFolderPicker = true
    }

    private func prepareDeletion(of targetEntries: [SFTPPathComponent]) {
        guard !targetEntries.isEmpty else { return }
        if targetEntries.count == 1, let entry = targetEntries.first {
            entryToDelete = entry
            showingDeleteConfirmation = true
        } else {
            selectedFilenames = Set(targetEntries.map(\.filename))
            showingBatchDeleteConfirmation = true
        }
    }

    private func presentFileInfo(_ entry: SFTPPathComponent) {
        refreshedFileInfoAttributes = nil
        fileInfoRefreshError = nil
        fileInfoGeneralExpanded = true
        fileInfoNetworkExpanded = true
        fileInfoNameExpanded = false
        fileInfoEditorExpanded = false
        fileInfoPermissionsExpanded = true
        fileInfoRawExpanded = false
        showingFileInfo = entry
    }

    private func beginRename(_ entry: SFTPPathComponent) {
        guard operationInProgress == nil, transferTask == nil else { return }
        #if os(macOS)
        beginInlineRename(entry)
        #else
        entryToRename = entry
        renameDraft = entry.filename
        showingRenamePrompt = true
        #endif
    }

    #if os(macOS)
    private func handleDelayedTableClick(
        _ entry: SFTPPathComponent,
        wasSelectedBeforeClick: Bool
    ) {
        guard wasSelectedBeforeClick,
              selectedFilenames == Set([entry.filename]),
              inlineRenameFilename == nil,
              operationInProgress == nil,
              transferTask == nil else { return }
        beginInlineRename(entry)
    }

    private func beginInlineRename(_ entry: SFTPPathComponent) {
        selectedFilenames = [entry.filename]
        entryToRename = entry
        renameDraft = entry.filename
        inlineRenameFilename = entry.filename
        Task { @MainActor in
            focusedRenameFilename = entry.filename
        }
    }

    private func commitInlineRename(_ entry: SFTPPathComponent) {
        guard inlineRenameFilename == entry.filename else { return }
        let requestedName = renameDraft
        inlineRenameFilename = nil
        focusedRenameFilename = nil
        Task { await renameEntry(entry, to: requestedName) }
    }
    #endif

    private func commitPromptedRename() {
        guard let entryToRename else { return }
        let requestedName = renameDraft
        showingRenamePrompt = false
        Task { await renameEntry(entryToRename, to: requestedName) }
    }

    private func cancelRename() {
        showingRenamePrompt = false
        entryToRename = nil
        renameDraft = ""
        inlineRenameFilename = nil
        focusedRenameFilename = nil
    }

    private func renameEntry(_ entry: SFTPPathComponent, to newName: String) async {
        guard let client = sftpClient else { return }
        guard Self.isSafeBasename(entry.filename), Self.isSafeBasename(newName) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            cancelRename()
            return
        }
        guard newName != entry.filename else {
            cancelRename()
            return
        }
        let normalizedNewName = Self.normalizedCollisionName(newName)
        guard !entries.contains(where: {
            $0.filename != entry.filename
                && Self.normalizedCollisionName($0.filename) == normalizedNewName
        }) else {
            error = SFTPRemoteOperationError.destinationCollision(newName).localizedDescription
            cancelRename()
            return
        }

        operationInProgress = "Renaming \(entry.filename)…"
        defer {
            operationInProgress = nil
            cancelRename()
        }
        do {
            try await client.rename(
                at: remotePath(for: entry.filename),
                to: remotePath(for: newName)
            )
            if selectedFilenames.remove(entry.filename) != nil {
                selectedFilenames.insert(newName)
            }
            await loadDirectory()
        } catch {
            self.error = "Rename failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func remoteClipboardURL(
        username: String,
        host: String,
        port: Int,
        path: String
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = username
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    private func clipboardURLs(for filenames: Set<String>) -> [URL] {
        clipboardURLs(for: contextEntries(for: filenames))
    }

    private func clipboardURLs(for targetEntries: [SFTPPathComponent]) -> [URL] {
        guard let server = session?.server else { return [] }
        return targetEntries.compactMap { entry in
            Self.remoteClipboardURL(
                username: server.username,
                host: server.host,
                port: server.port,
                path: remotePath(for: entry.filename)
            )
        }
    }

    private func copyRemoteReferences(_ targetEntries: [SFTPPathComponent]) {
        let urls = clipboardURLs(for: targetEntries)
        guard !urls.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        #elseif os(iOS) || os(visionOS)
        UIPasteboard.general.urls = urls
        #endif
    }

    private func beginRemoteOperation(
        _ kind: SFTPRemoteOperationKind,
        entries targetEntries: [SFTPPathComponent]
    ) {
        guard !targetEntries.isEmpty,
              operationInProgress == nil,
              transferTask == nil else { return }
        remoteDestinationPath = currentPath
        remoteDestinationEntries = []
        remoteDestinationError = nil
        remoteOperationRequest = SFTPRemoteOperationRequest(
            kind: kind,
            sourceDirectory: currentPath,
            entries: targetEntries
        )
    }

    private func remoteDestinationSheet(for request: SFTPRemoteOperationRequest) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(remoteDestinationPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)

                    if remoteDestinationPath != "/" {
                        Button {
                            navigateRemoteDestination(to: Self.remoteParentPath(remoteDestinationPath))
                        } label: {
                            Label("Parent Directory", systemImage: "arrow.turn.up.left")
                        }
                    }
                }

                Section("Folders") {
                    if remoteDestinationIsLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(remoteDestinationFolders, id: \.filename) { entry in
                            Button {
                                navigateRemoteDestination(
                                    to: Self.remotePath(
                                        directory: remoteDestinationPath,
                                        basename: entry.filename
                                    )
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.blue)
                                    Text(entry.filename)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let remoteDestinationError {
                    Section {
                        Label(remoteDestinationError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Label(
                        "The remote server checks permissions when the operation starts. glas.sh stages and verifies copied bytes before publishing them.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(request.kind.rawValue) to Remote Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        remoteOperationRequest = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("\(request.kind.rawValue) Here") {
                        startRemoteOperation(request, destinationDirectory: remoteDestinationPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(remoteDestinationIsLoading)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .task(id: request.id) {
            await loadRemoteDestination()
        }
    }

    private var remoteDestinationFolders: [SFTPPathComponent] {
        remoteDestinationEntries
            .filter { $0.filename != "." && $0.filename != ".." }
            .filter { isDirectory($0) }
            .sorted {
                $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
            }
    }

    private func navigateRemoteDestination(to path: String) {
        remoteDestinationPath = path
        remoteDestinationEntries = []
        remoteDestinationError = nil
        Task { await loadRemoteDestination() }
    }

    private func loadRemoteDestination() async {
        guard let client = sftpClient else { return }
        remoteDestinationIsLoading = true
        defer { remoteDestinationIsLoading = false }
        do {
            let listing = try await client.listDirectory(atPath: remoteDestinationPath)
            remoteDestinationEntries = listing.flatMap(\.components)
            remoteDestinationError = nil
        } catch {
            remoteDestinationError = "This folder could not be opened: \(error.localizedDescription)"
        }
    }

    private func startRemoteOperation(
        _ request: SFTPRemoteOperationRequest,
        destinationDirectory: String
    ) {
        remoteOperationRequest = nil
        let activityKind: SFTPTransferKind = request.kind == .copy
            ? .remoteCopy
            : .remoteMove
        let activityIDs = request.entries.map {
            transferActivity.enqueue(kind: activityKind, filename: $0.filename)
        }
        transferTask = Task {
            await performRemoteOperation(
                request,
                destinationDirectory: destinationDirectory,
                activityIDs: activityIDs
            )
        }
    }

    nonisolated static func remotePath(directory: String, basename: String) -> String {
        directory == "/" ? "/" + basename : directory + "/" + basename
    }

    nonisolated static func remoteParentPath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    nonisolated static func isRemotePath(_ candidate: String, inside source: String) -> Bool {
        let normalizedSource = source == "/"
            ? "/"
            : "/" + source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedCandidate = candidate == "/"
            ? "/"
            : "/" + candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedCandidate != normalizedSource else { return true }
        if normalizedSource == "/" { return true }
        return normalizedCandidate.hasPrefix(normalizedSource + "/")
    }

    private var canAcceptFileDrop: Bool {
        sftpClient != nil && transferTask == nil && operationInProgress == nil
    }

    private func beginFileDropUpload(_ urls: [URL]) {
        isReceivingFileDrop = false
        guard canAcceptFileDrop else {
            error = "Wait for the current SFTP operation to finish before dropping files."
            return
        }
        guard !urls.isEmpty else { return }
        transferTask = Task { await uploadLocalFiles(urls, source: .fileDrop) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
                Task {
                    if await shutdownTransferAndConnection() {
                        dismiss()
                    }
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                if !selectableEntries.isEmpty {
                    Button {
                        selectedFilenames = Set(selectableEntries.map(\.filename))
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    #if os(macOS)
                    .keyboardShortcut("a", modifiers: .command)
                    #endif

                    if !selectedFilenames.isEmpty {
                        Button {
                            selectedFilenames.removeAll()
                        } label: {
                            Label("Deselect All", systemImage: "circle")
                        }
                        #if os(macOS)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        #endif
                    }

                    Divider()
                }

                Button {
                    newFolderName = ""
                    showingNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    showingFileImporter = true
                } label: {
                    Label("Upload File", systemImage: "square.and.arrow.up")
                }

                Divider()

                Toggle(isOn: $showHiddenFiles) {
                    Label("Show Hidden Files", systemImage: "eye")
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Button {
                    Task { await loadDirectory() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }

        ToolbarItem(placement: .principal) {
            pathBreadcrumb
        }
    }

    private var pathBreadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let components = pathComponents(from: currentPath)
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        let targetPath = buildPath(from: components, upTo: index)
                        Task { await navigateTo(targetPath) }
                    } label: {
                        Text(component.isEmpty ? "/" : component)
                            .font(.caption)
                            .fontWeight(index == components.count - 1 ? .semibold : .regular)
                            .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Connection and Loading

    private func connectAndLoad() async {
        guard let session = session else {
            error = "Session not found."
            return
        }

        guard let sshConnection = session.getSSHConnection() else {
            error = "SSH connection not available."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = try await sshConnection.openSFTPClient()
            self.sftpClient = client

            // Resolve home directory as starting path
            let homePath = try await client.getRealPath(atPath: ".")
            currentPath = homePath
            navigationStack = [homePath]

            await loadDirectory()
        } catch {
            self.error = "Failed to open SFTP connection: \(error.localizedDescription)"
        }
    }

    private func loadDirectory() async {
        guard let client = sftpClient else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let names = try await client.listDirectory(atPath: currentPath)
            let allComponents = names.flatMap { $0.components }
            entries = allComponents
            error = nil
        } catch {
            self.error = "Failed to list directory: \(error.localizedDescription)"
        }
    }

    // MARK: - Navigation

    private func handleEntryTap(_ entry: SFTPPathComponent) async {
        if isDirectory(entry) {
            guard Self.isSafeBasename(entry.filename) else {
                error = SFTPTransferError.unsafeName.localizedDescription
                return
            }
            selectedFilenames.removeAll()
            let newPath = remotePath(for: entry.filename)
            await navigateTo(newPath)
        }
    }

    private func navigateTo(_ path: String) async {
        currentPath = path
        navigationStack.append(path)
        await loadDirectory()
    }

    private func navigateUp() {
        guard navigationStack.count > 1 else { return }
        navigationStack.removeLast()
        currentPath = navigationStack.last ?? "/"
        selectedFilenames.removeAll()
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    nonisolated static let remoteEditorConfiguration = GlassEditorConfiguration()

    private var remoteEditorSurfaceCondition: SurfaceCondition {
        let sessionOverride = settingsManager.sessionOverride(for: sessionID)
        let appearance = TerminalGlassAppearance.resolved(
            globalOpacity: settingsManager.windowOpacity,
            globalBlur: settingsManager.blurBackground,
            sessionOverride: sessionOverride
        )
        let material = MaterialWeight(
            rawValue: sessionOverride?.glassFrost ?? settingsManager.glassFrost
        ) ?? .ultraThin
        return SurfaceCondition(
            windowOpacity: appearance.opacity,
            backing: .material(material)
        )
    }

    private func beginRemoteEdit(_ entry: SFTPPathComponent) {
        guard transferTask == nil, operationInProgress == nil else { return }
        transferTask = Task {
            await openRemoteEditor(entry)
            transferTask = nil
        }
    }

    private func openRemoteEditor(_ entry: SFTPPathComponent) async {
        guard let client = sftpClient, let session else { return }
        guard Self.isSafeBasename(entry.filename) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            return
        }

        let path = remotePath(for: entry.filename)
        let configuration = Self.remoteEditorConfiguration
        operationInProgress = "Opening \(entry.filename)…"
        defer { operationInProgress = nil }

        do {
            let observation = try await Self.readVerifiedRemoteObservation(
                client: client,
                path: path,
                maximumBytes: configuration.largeFileByteCeiling
            )
            let ref = RemoteDocumentRef(
                connectionID: sessionID,
                host: session.server.host,
                path: path
            )
            let snapshot = try DocumentLoader.load(
                fromData: observation.data,
                origin: .remote(ref),
                configuration: configuration,
                openedDigest: observation.digest,
                openedStat: observation.stat
            )
            let model = GlassEditorModel(
                snapshot: snapshot,
                configuration: configuration,
                language: LanguageID.forFileExtension(
                    (entry.filename as NSString).pathExtension
                ),
                surfaceCondition: remoteEditorSurfaceCondition
            )
            remoteEditorDocument = SFTPRemoteEditorDocument(
                filename: entry.filename,
                remotePath: path,
                model: model,
                remoteSession: RemoteDocumentSession(
                    ref: ref,
                    openedStat: observation.stat,
                    openedDigest: observation.digest
                )
            )
        } catch {
            self.error = "Could not open \(entry.filename) for editing: \(error.localizedDescription)"
        }
    }

    private func checkRemoteEditor(
        _ document: SFTPRemoteEditorDocument,
        requiresDigest: Bool = false
    ) async {
        guard let client = sftpClient, requiresDigest || !document.isWorking else { return }

        do {
            let attributes = try await client.getLinkAttributes(at: document.remotePath)
            let currentStat = Self.remoteStat(from: attributes)
            let tierOne = ConflictDetector.classify(
                session: document.remoteSession,
                currentStat: currentStat,
                currentDigest: nil,
                localDirty: document.model.isDirty
            )
            guard requiresDigest || tierOne != .noConflict else {
                document.model.conflictState = .noConflict
                return
            }

            let observation = try await Self.readVerifiedRemoteObservation(
                client: client,
                path: document.remotePath,
                maximumBytes: document.model.configuration.largeFileByteCeiling
            )
            let resolved = ConflictDetector.classify(
                session: document.remoteSession,
                currentStat: observation.stat,
                currentDigest: observation.digest,
                localDirty: document.model.isDirty
            )
            if resolved == .noConflict {
                document.model.conflictState = .noConflict
                document.conflictPrompt = nil
            } else {
                document.surfaceConflict(resolved, observation: observation)
            }
        } catch {
            document.surfaceConflict(.indeterminate, observation: nil)
        }
    }

    private func saveRemoteEditor(
        _ document: SFTPRemoteEditorDocument,
        authorizedObservation: SFTPRemoteFileObservation?
    ) async {
        guard let client = sftpClient, let session else { return }
        guard !document.isWorking else { return }
        guard document.model.isDirty || authorizedObservation != nil else { return }

        document.isWorking = true
        document.statusMessage = "Checking the remote file…"
        defer {
            document.isWorking = false
            document.statusMessage = nil
        }

        do {
            let commitObservation: SFTPRemoteFileObservation
            if let authorizedObservation {
                commitObservation = authorizedObservation
            } else {
                let current: SFTPRemoteFileObservation
                do {
                    current = try await Self.readVerifiedRemoteObservation(
                        client: client,
                        path: document.remotePath,
                        maximumBytes: document.model.configuration.largeFileByteCeiling
                    )
                } catch {
                    document.surfaceConflict(.indeterminate, observation: nil)
                    return
                }
                let conflict = ConflictDetector.classify(
                    session: document.remoteSession,
                    currentStat: current.stat,
                    currentDigest: current.digest,
                    localDirty: document.model.isDirty
                )
                guard conflict == .noConflict else {
                    document.surfaceConflict(conflict, observation: current)
                    return
                }
                commitObservation = current
            }

            let encoded = try EncodingDetector.encode(
                document.model.text,
                as: document.model.snapshot.encoding
            )
            document.statusMessage = "Uploading and verifying \(document.filename)…"
            let result = try await Self.uploadRemoteEditorBytes(
                encoded,
                client: client,
                serverID: session.server.id,
                remoteDirectory: (document.remotePath as NSString).deletingLastPathComponent,
                filename: document.filename,
                targetPath: document.remotePath,
                expectedRemote: commitObservation,
                maximumBytes: document.model.configuration.largeFileByteCeiling
            )
            guard let committedStat = result.committedStat else {
                throw SFTPTransferError.remoteSourceChanged
            }
            document.remoteSession = document.remoteSession.updatingAfterSave(
                stat: committedStat,
                digest: result.committedDigest
            )
            document.model.markClean()
            document.model.conflictState = .noConflict
            document.conflictPrompt = nil
            if result.cleanupWarning {
                document.errorMessage = "The remote file was saved, but a tracked local cleanup record remains."
            }
            await loadDirectory()
        } catch let failure as SFTPUploadWorkerFailure {
            if failure.kind == .commitOutcomeUnknown {
                await reconcileRemoteEditorAfterUnknownCommit(document)
            } else if failure.kind == .remoteTargetChanged {
                await checkRemoteEditor(document, requiresDigest: true)
                if document.model.conflictState == .noConflict {
                    document.errorMessage = "Save stopped before commit because the remote file could not be verified continuously. Try saving again."
                }
            } else {
                document.errorMessage = failure.message
            }
        } catch {
            document.errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func reconcileRemoteEditorAfterUnknownCommit(
        _ document: SFTPRemoteEditorDocument
    ) async {
        guard let client = sftpClient else {
            document.surfaceConflict(.indeterminate, observation: nil)
            return
        }

        do {
            let observation = try await Self.readVerifiedRemoteObservation(
                client: client,
                path: document.remotePath,
                maximumBytes: document.model.configuration.largeFileByteCeiling
            )
            let encoded = try EncodingDetector.encode(
                document.model.text,
                as: document.model.snapshot.encoding
            )
            if observation.data == encoded {
                document.remoteSession = document.remoteSession.updatingAfterSave(
                    stat: observation.stat,
                    digest: observation.digest
                )
                document.model.markClean()
                document.model.conflictState = .noConflict
                document.conflictPrompt = nil
                await loadDirectory()
                return
            }

            let conflict = ConflictDetector.classify(
                session: document.remoteSession,
                currentStat: observation.stat,
                currentDigest: observation.digest,
                localDirty: document.model.isDirty
            )
            if conflict == .noConflict {
                document.errorMessage = "The server did not confirm the atomic replacement. The remote file is unchanged; try saving again."
            } else {
                document.surfaceConflict(conflict, observation: observation)
            }
        } catch {
            document.surfaceConflict(.indeterminate, observation: nil)
        }
    }

    private func resolveRemoteEditorConflict(
        _ resolution: ConflictResolution,
        document: SFTPRemoteEditorDocument,
        observation: SFTPRemoteFileObservation?
    ) async {
        switch resolution {
        case .overwriteRemote:
            await saveRemoteEditor(document, authorizedObservation: observation)
        case .discardLocalAndReload:
            await reloadRemoteEditor(document, preferredObservation: observation)
        case .saveLocalCopy:
            break
        case .keepEditing:
            document.conflictPrompt = nil
        }
    }

    private func reloadRemoteEditor(
        _ document: SFTPRemoteEditorDocument,
        preferredObservation: SFTPRemoteFileObservation? = nil
    ) async {
        guard let client = sftpClient, !document.isWorking else { return }
        document.isWorking = true
        document.statusMessage = "Reloading \(document.filename)…"
        defer {
            document.isWorking = false
            document.statusMessage = nil
        }

        do {
            let observation: SFTPRemoteFileObservation
            if let preferredObservation {
                observation = preferredObservation
            } else {
                observation = try await Self.readVerifiedRemoteObservation(
                    client: client,
                    path: document.remotePath,
                    maximumBytes: document.model.configuration.largeFileByteCeiling
                )
            }
            let snapshot = try DocumentLoader.load(
                fromData: observation.data,
                origin: document.model.snapshot.origin,
                configuration: document.model.configuration,
                openedDigest: observation.digest,
                openedStat: observation.stat
            )
            try document.model.adoptReloadedContent(snapshot)
            document.remoteSession = document.remoteSession.updatingAfterSave(
                stat: observation.stat,
                digest: observation.digest
            )
            document.conflictPrompt = nil
        } catch {
            document.errorMessage = "Reload failed: \(error.localizedDescription)"
        }
    }

    private func remoteEditorConflictDescription(_ state: ConflictState) -> String {
        switch state {
        case .noConflict: "None"
        case .remoteChangedLocalClean: "Remote changed"
        case .remoteChangedLocalDirty: "Conflicting changes"
        case .indeterminate: "Unknown"
        }
    }

    private func downloadSelectedFiles() async {
        let filesToDownload = sortedEntries.filter {
            !isDirectory($0) && selectedFilenames.contains($0.filename)
        }
        guard !filesToDownload.isEmpty else { return }
        pendingDownloads = filesToDownload
        showingFolderPicker = true
    }

    private func startDownload(_ entry: SFTPPathComponent) {
        pendingDownloads = [entry]
        showingFolderPicker = true
    }

    private func deleteSelectedFiles() async {
        let filesToDelete = sortedEntries.filter {
            selectedFilenames.contains($0.filename)
        }
        for entry in filesToDelete {
            await deleteEntry(entry)
        }
        selectedFilenames.removeAll()
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) async {
        defer { transferTask = nil }
        guard case .success(let urls) = result,
              let folderURL = urls.first else { return }

        guard folderURL.startAccessingSecurityScopedResource() else {
            error = "Cannot access the selected folder."
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let openedDestinationDirectory: (
            directory: FileHandle,
            identity: SFTPLocalDirectoryIdentity
        )
        do {
            openedDestinationDirectory = try Self.openLocalDirectoryNoFollow(at: folderURL)
        } catch {
            self.error = "Cannot securely open the selected folder."
            return
        }
        defer { try? openedDestinationDirectory.directory.close() }

        let downloads = pendingDownloads
        pendingDownloads = []
        let activityIDs = downloads.map {
            transferActivity.enqueue(
                kind: .download,
                filename: $0.filename,
                totalBytes: $0.attributes.size
            )
        }

        for (index, entry) in downloads.enumerated() {
            if Task.isCancelled {
                transferActivity.cancelPending(
                    activityIDs.dropFirst(index),
                    detail: "The transfer batch was cancelled."
                )
                break
            }
            await downloadFileToFolder(
                entry,
                destinationDirectory: openedDestinationDirectory.directory,
                destinationDirectoryIdentity: openedDestinationDirectory.identity,
                activityID: activityIDs[index],
                current: index + 1,
                total: downloads.count
            )
            if Task.isCancelled {
                transferActivity.cancelPending(
                    activityIDs.dropFirst(index + 1),
                    detail: "The transfer batch was cancelled."
                )
                break
            }
        }

        selectedFilenames.removeAll()
    }

    private func downloadFileToFolder(
        _ entry: SFTPPathComponent,
        destinationDirectory: FileHandle,
        destinationDirectoryIdentity: SFTPLocalDirectoryIdentity,
        activityID: UUID,
        current: Int,
        total: Int
    ) async {
        guard let client = sftpClient else {
            transferActivity.fail(activityID, detail: "The SFTP connection is unavailable.")
            return
        }
        guard Self.isSafeBasename(entry.filename) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            transferActivity.fail(activityID, detail: SFTPTransferError.unsafeName.localizedDescription)
            return
        }
        let filePath = remotePath(for: entry.filename)
        let listedFileSize = entry.attributes.size
        let fileSize = listedFileSize ?? 0
        let fileSizeText = fileSize > 0 ? " (\(formattedFileSize(fileSize)))" : ""
        let prefix = total > 1 ? "[\(current)/\(total)] " : ""
        transferActivity.begin(activityID)
        operationInProgress = "\(prefix)Downloading \(entry.filename)\(fileSizeText)..."

        do {
            try await Self.performVerifiedDownload(
                client: client,
                serverID: session?.server.id ?? sessionID,
                remotePath: filePath,
                sourceName: entry.filename,
                destinationDirectory: destinationDirectory,
                destinationDirectoryIdentity: destinationDirectoryIdentity,
                exactDestinationName: nil
            ) { progress in
                transferActivity.apply(progress, to: activityID)
                if case .transferring(let completedBytes, let expectedBytes) = progress,
                   expectedBytes > 0 {
                    let value = min(1, Double(completedBytes) / Double(expectedBytes))
                    operationInProgress = "\(prefix)Downloading \(entry.filename) — \(Int(value * 100))%"
                } else if progress == .verifying {
                    operationInProgress = "\(prefix)Verifying \(entry.filename)…"
                }
            }
            transferActivity.complete(activityID)
        } catch let failure as SFTPDownloadWorkerFailure {
            self.error = failure.userFacingDescription(filename: entry.filename)
            if failure.wasCancelled {
                transferActivity.cancel(activityID, detail: failure.localizedDescription)
            } else {
                transferActivity.fail(activityID, detail: failure.localizedDescription)
            }
        } catch {
            self.error = "Download of \(entry.filename) failed: \(error.localizedDescription)"
            if error is CancellationError {
                transferActivity.cancel(activityID, detail: "Download cancelled.")
            } else {
                transferActivity.fail(activityID, detail: error.localizedDescription)
            }
        }

        operationInProgress = nil
    }

    private static func performVerifiedDownload(
        client: SFTPClient,
        serverID: UUID,
        remotePath: String,
        sourceName: String,
        destinationDirectory: FileHandle,
        destinationDirectoryIdentity: SFTPLocalDirectoryIdentity,
        exactDestinationName: String?,
        progress: @escaping @MainActor (SFTPTransferProgressUpdate) -> Void
    ) async throws {
        var retainedPartialName: String?
        var retainedPartialIdentity: SFTPLocalFileIdentity?
        var openedRemoteFile: SFTPFile?

        do {
            guard Self.isSafeBasename(sourceName),
                  exactDestinationName.map(Self.isSafeBasename) ?? true else {
                throw SFTPTransferError.unsafeName
            }
            guard try Self.localDirectoryIdentity(for: destinationDirectory)
                    == destinationDirectoryIdentity else {
                throw SFTPTransferError.cannotCreateTemporaryFile
            }

            // FSTAT binds the source identity to the same opaque handle used for every
            // byte. A path-level STAT could instead describe a replacement inode.
            let remoteFile = try await client.openFile(filePath: remotePath, flags: .read)
            openedRemoteFile = remoteFile
            let sourceAttributes = try await remoteFile.readAttributes()
            guard sourceAttributes.isRegularFile else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            guard let expectedFileSize = sourceAttributes.size else {
                throw SFTPTransferError.missingRemoteSize
            }
            progress(.transferring(completedBytes: 0, totalBytes: expectedFileSize))
            let sourceModificationTime = sourceAttributes.accessModificationTime?.modificationTime
            let destinationName = try exactDestinationName ?? Self.collisionSafeDestinationName(
                for: sourceName,
                in: destinationDirectory
            )
            let resumeIdentity = Self.downloadResumeIdentity(
                serverID: serverID,
                remotePath: remotePath,
                size: expectedFileSize,
                modificationTime: sourceModificationTime
            )
            let temporaryName = ".glas-sh-download-\(resumeIdentity).partial"

            var resumeOffset: UInt64 = 0
            let localFile: FileHandle
            let initialLocalIdentity: SFTPLocalFileIdentity
            do {
                let existing = try Self.openRegularFileNoFollow(
                    in: destinationDirectory,
                    name: temporaryName,
                    flags: O_RDWR
                )
                switch Self.localResumeDecision(
                    fileExists: true,
                    isRegularAndContained: true,
                    size: existing.identity.size,
                    expectedSize: expectedFileSize
                ) {
                case .resume(let offset):
                    resumeOffset = offset
                    do {
                        try Self.setProtection(
                            .completeUnlessOpen,
                            for: existing.file,
                            matching: existing.identity
                        )
                    } catch {
                        try? existing.file.close()
                        throw error
                    }
                    localFile = existing.file
                    initialLocalIdentity = existing.identity
                    retainedPartialName = temporaryName
                    retainedPartialIdentity = existing.identity
                case .replaceOversized:
                    try existing.file.close()
                    try Self.removeLocalFileIfMatching(
                        in: destinationDirectory,
                        name: temporaryName,
                        identity: existing.identity
                    )
                    let created = try Self.createProtectedTemporaryFile(
                        in: destinationDirectory,
                        name: temporaryName
                    )
                    localFile = created.file
                    initialLocalIdentity = created.identity
                    retainedPartialName = temporaryName
                    retainedPartialIdentity = created.identity
                case .create, .rejectUnsafe:
                    try existing.file.close()
                    throw SFTPTransferError.cannotCreateTemporaryFile
                }
            } catch SFTPLocalOpenError.notFound {
                let created = try Self.createProtectedTemporaryFile(
                    in: destinationDirectory,
                    name: temporaryName
                )
                localFile = created.file
                initialLocalIdentity = created.identity
                retainedPartialName = temporaryName
                retainedPartialIdentity = created.identity
            }
            defer { try? localFile.close() }

            var completed = false
            var keepPartial = true
            defer {
                if !completed && !keepPartial {
                    try? Self.removeLocalFileIfMatching(
                        in: destinationDirectory,
                        name: temporaryName,
                        identity: initialLocalIdentity
                    )
                }
            }
            try BoundedStorage.validateWrite(
                currentBytes: resumeOffset,
                incomingBytes: expectedFileSize - resumeOffset,
                maximumBytes: BoundedStorage.maximumDownloadBytes,
                availableCapacity: try Self.availableCapacity(in: destinationDirectory)
            )

            var offset: UInt64 = 0
            var remoteHasher = SHA256()
            var effectiveChunkSize = Self.downloadReadChunkSize
            do {
                // Re-establish trust in every retained byte using the same open remote
                // handle that will supply the remainder. Only then seek to the append point.
                if resumeOffset > 0 {
                    progress(.verifying)
                }
                while offset < resumeOffset {
                    try Task.checkCancellation()
                    let requests = Self.downloadReadWindow(
                        from: offset,
                        through: resumeOffset,
                        chunkSize: effectiveChunkSize
                    )
                    let chunks = try await remoteFile.read(requests)
                    let decision = try Self.downloadReadBatchDecision(
                        requests: requests,
                        readableByteCounts: chunks.map(\.readableBytes)
                    )
                    guard !decision.reachedEOF else {
                        keepPartial = false
                        throw SFTPTransferError.invalidResumePartial
                    }

                    for index in 0..<decision.acceptedResponseCount {
                        try Task.checkCancellation()
                        let request = requests[index]
                        guard request.offset == offset else {
                            keepPartial = false
                            throw SFTPTransferError.invalidResumePartial
                        }
                        let data = Data(buffer: chunks[index])
                        guard let localData = try localFile.read(upToCount: data.count),
                              Self.resumeChunksMatch(source: data, retained: localData) else {
                            keepPartial = false
                            throw SFTPTransferError.invalidResumePartial
                        }
                        remoteHasher.update(data: data)
                        offset += UInt64(data.count)
                    }
                    if let nextChunkSize = decision.nextChunkSize {
                        effectiveChunkSize = nextChunkSize
                    }
                }
                try localFile.seek(toOffset: resumeOffset)
                progress(.transferring(
                    completedBytes: resumeOffset,
                    totalBytes: expectedFileSize
                ))

                downloadLoop: while offset < expectedFileSize {
                    try Task.checkCancellation()
                    let requests = Self.downloadReadWindow(
                        from: offset,
                        through: expectedFileSize,
                        chunkSize: effectiveChunkSize
                    )
                    let chunks = try await remoteFile.read(requests)
                    let decision = try Self.downloadReadBatchDecision(
                        requests: requests,
                        readableByteCounts: chunks.map(\.readableBytes)
                    )

                    for index in 0..<decision.acceptedResponseCount {
                        try Task.checkCancellation()
                        let request = requests[index]
                        guard request.offset == offset else {
                            throw SFTPError.invalidResponse
                        }
                        let chunk = chunks[index]
                        let incomingBytes = UInt64(chunk.readableBytes)
                        try BoundedStorage.validateWrite(
                            currentBytes: offset,
                            incomingBytes: incomingBytes,
                            maximumBytes: BoundedStorage.maximumDownloadBytes,
                            availableCapacity: try Self.availableCapacity(in: destinationDirectory)
                        )
                        let data = Data(buffer: chunk)
                        remoteHasher.update(data: data)
                        try localFile.write(contentsOf: data)
                        offset += incomingBytes
                        progress(.transferring(
                            completedBytes: offset,
                            totalBytes: expectedFileSize
                        ))
                    }
                    if let nextChunkSize = decision.nextChunkSize {
                        effectiveChunkSize = nextChunkSize
                    }
                    if decision.reachedEOF {
                        break downloadLoop
                    }
                }
                progress(.verifying)
                let completedAttributes = try await remoteFile.readAttributes()
                guard completedAttributes.isRegularFile,
                      completedAttributes.size == sourceAttributes.size,
                      completedAttributes.accessModificationTime?.modificationTime
                        == sourceAttributes.accessModificationTime?.modificationTime else {
                    keepPartial = false
                    throw SFTPTransferError.remoteSourceChanged
                }
                try await remoteFile.close()
                openedRemoteFile = nil
            } catch {
                try? await remoteFile.close()
                openedRemoteFile = nil
                throw error
            }

            if offset != expectedFileSize {
                keepPartial = false
                throw SFTPTransferError.sizeMismatch(expected: expectedFileSize, actual: offset)
            }

            try localFile.synchronize()
            let completedLocalIdentity = try Self.localFileIdentity(for: localFile)
            guard completedLocalIdentity.isSameFile(as: initialLocalIdentity) else {
                keepPartial = false
                throw SFTPTransferError.cannotCreateTemporaryFile
            }
            let localDigest = try Self.localSHA256(using: localFile, expectedSize: offset)
            guard localDigest == Data(remoteHasher.finalize()) else {
                keepPartial = false
                throw SFTPTransferError.checksumMismatch
            }
            try Self.setProtection(
                .complete,
                for: localFile,
                matching: completedLocalIdentity
            )
            try Self.checkCancellationBeforeCommit()
            try Self.moveLocalFileNoClobber(
                in: destinationDirectory,
                sourceName: temporaryName,
                destinationName: destinationName,
                matching: completedLocalIdentity
            )
            completed = true
        } catch {
            if let openedRemoteFile {
                try? await openedRemoteFile.close()
            }
            let partialWasRetained = if let retainedPartialName, let retainedPartialIdentity {
                (try? Self.localEntryIdentityNoFollow(
                    in: destinationDirectory,
                    name: retainedPartialName
                ))?
                    .isSameFile(as: retainedPartialIdentity) == true
            } else {
                false
            }
            throw SFTPDownloadWorkerFailure(
                underlyingDescription: error.localizedDescription,
                partialWasRetained: partialWasRetained,
                wasCancelled: error is CancellationError
            )
        }
    }

    #if os(macOS)
    private static func writePromisedRemoteFile(
        client: SFTPClient,
        serverID: UUID,
        remotePath: String,
        sourceName: String,
        destinationURL: URL,
        progress: @escaping @MainActor (SFTPTransferProgressUpdate) -> Void
    ) async throws {
        guard destinationURL.isFileURL,
              Self.isSafeBasename(destinationURL.lastPathComponent) else {
            throw SFTPTransferError.destinationEscapesFolder
        }

        let openedDestinationDirectory = try Self.openLocalDirectoryNoFollow(
            at: destinationURL.deletingLastPathComponent()
        )
        defer { try? openedDestinationDirectory.directory.close() }

        try await Self.performVerifiedDownload(
            client: client,
            serverID: serverID,
            remotePath: remotePath,
            sourceName: sourceName,
            destinationDirectory: openedDestinationDirectory.directory,
            destinationDirectoryIdentity: openedDestinationDirectory.identity,
            exactDestinationName: destinationURL.lastPathComponent,
            progress: progress
        )
    }
    #endif

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            await uploadLocalFiles(urls, source: .fileImporter)

        case .failure(let err):
            transferTask = nil
            self.error = "File selection failed: \(err.localizedDescription)"
        }
    }

    private func uploadLocalFiles(
        _ urls: [URL],
        source: SFTPLocalUploadSource
    ) async {
        defer { transferTask = nil }
        guard let client = sftpClient else {
            error = "The SFTP connection is no longer available."
            return
        }
        let activityIDs = urls.map {
            transferActivity.enqueue(kind: .upload, filename: $0.lastPathComponent)
        }

        // Reserve names for the whole selection. The visible directory listing is only a
        // snapshot, so without a batch reservation two local URLs with the same basename
        // could select the same remote target before the directory is refreshed.
        var reservedRemoteNames = Set(entries.map { Self.normalizedCollisionName($0.filename) })

        for (index, url) in urls.enumerated() {
            let activityID = activityIDs[index]
            if Task.isCancelled {
                transferActivity.cancelPending(
                    activityIDs.dropFirst(index),
                    detail: "The transfer batch was cancelled."
                )
                return
            }
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()
            if !accessedSecurityScope {
                switch source {
                case .fileImporter:
                    // Preserve the existing picker behavior: inaccessible selections are skipped.
                    transferActivity.fail(
                        activityID,
                        detail: "Access to this selected file was unavailable."
                    )
                    continue
                case .fileDrop:
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        error = "Upload failed: glas.sh could not access \(url.lastPathComponent)."
                        transferActivity.fail(
                            activityID,
                            detail: "glas.sh could not access this file."
                        )
                        transferActivity.cancelPending(
                            activityIDs.dropFirst(index + 1),
                            detail: "The transfer batch stopped after a failure."
                        )
                        operationInProgress = nil
                        return
                    }
                }
            }
            do {
                defer {
                    if accessedSecurityScope {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if case .fileDrop = source {
                    let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
                    guard resourceValues.isRegularFile == true else {
                        error = "Only regular files can be uploaded. Folder drops are not supported yet."
                        transferActivity.fail(
                            activityID,
                            detail: "Only regular files can be uploaded."
                        )
                        transferActivity.cancelPending(
                            activityIDs.dropFirst(index + 1),
                            detail: "The transfer batch stopped after a failure."
                        )
                        operationInProgress = nil
                        return
                    }
                }
                let sourceName = url.lastPathComponent
                guard Self.isSafeBasename(sourceName) else {
                    throw SFTPTransferError.unsafeName
                }
                let filename = collisionSafeRemoteName(
                    for: sourceName,
                    reservingIn: &reservedRemoteNames
                )
                transferActivity.updateFilename(filename, for: activityID)
                transferActivity.begin(activityID)
                let targetPath = remotePath(for: filename)
                operationInProgress = filename == sourceName
                    ? "Uploading \(filename)..."
                    : "Uploading as \(filename)..."
                let cleanupWarning = try await Self.performUpload(
                    client: client,
                    sourceURL: url,
                    serverID: session?.server.id ?? sessionID,
                    remoteDirectory: currentPath,
                    sourceName: sourceName,
                    finalName: filename,
                    targetPath: targetPath,
                    maximumUploadBytes: BoundedStorage.maximumUploadBytes
                ) { progress in
                    transferActivity.apply(progress, to: activityID)
                    if progress == .verifying {
                        operationInProgress = "Verifying \(filename)…"
                    }
                }
                transferActivity.complete(
                    activityID,
                    detail: cleanupWarning
                        ? "Completed; a tracked cleanup item remains on the server."
                        : nil
                )
                if cleanupWarning {
                    self.error = "Upload completed, but a tracked hidden cleanup file remains on the server."
                }
            } catch let failure as SFTPUploadWorkerFailure {
                self.error = failure.message
                if failure.kind == .cancelled {
                    transferActivity.cancel(activityID, detail: failure.message)
                } else {
                    transferActivity.fail(activityID, detail: failure.message)
                }
                transferActivity.cancelPending(
                    activityIDs.dropFirst(index + 1),
                    detail: failure.kind == .cancelled
                        ? "The transfer batch was cancelled."
                        : "The transfer batch stopped after a failure."
                )
                operationInProgress = nil
                return
            } catch {
                self.error = error is CancellationError
                    ? "Upload cancelled. No partial file was kept."
                    : "Upload failed: \(error.localizedDescription)"
                if error is CancellationError {
                    transferActivity.cancel(activityID, detail: "Upload cancelled.")
                } else {
                    transferActivity.fail(activityID, detail: error.localizedDescription)
                }
                transferActivity.cancelPending(
                    activityIDs.dropFirst(index + 1),
                    detail: error is CancellationError
                        ? "The transfer batch was cancelled."
                        : "The transfer batch stopped after a failure."
                )
                operationInProgress = nil
                return
            }
        }

        operationInProgress = nil
        await loadDirectory()
    }

    private func createFolder(named name: String) async {
        guard let client = sftpClient, Self.isSafeBasename(name) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            return
        }

        let folderPath = remotePath(for: name)

        operationInProgress = "Creating folder..."
        defer { operationInProgress = nil }

        do {
            try await client.createDirectory(atPath: folderPath)
            newFolderName = ""
            await loadDirectory()
        } catch {
            self.error = "Failed to create folder: \(error.localizedDescription)"
        }
    }

    private func deleteEntry(_ entry: SFTPPathComponent) async {
        guard let client = sftpClient else { return }
        guard Self.isSafeBasename(entry.filename) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            return
        }

        let itemPath = remotePath(for: entry.filename)

        operationInProgress = "Deleting \(entry.filename)..."
        defer {
            operationInProgress = nil
            entryToDelete = nil
        }

        do {
            if isDirectory(entry) {
                try await client.rmdir(at: itemPath)
            } else {
                try await client.remove(at: itemPath)
            }
            await loadDirectory()
        } catch {
            self.error = "Failed to delete \(entry.filename): \(error.localizedDescription)"
        }
    }

    // MARK: - Remote Copy and Move

    private func performRemoteOperation(
        _ request: SFTPRemoteOperationRequest,
        destinationDirectory: String,
        activityIDs: [UUID]
    ) async {
        defer {
            transferTask = nil
            operationInProgress = nil
        }
        guard let client = sftpClient,
              let sshConnection = session?.getSSHConnection() else {
            error = "The SSH connection is no longer available."
            for activityID in activityIDs {
                transferActivity.fail(
                    activityID,
                    detail: "The SSH connection is no longer available."
                )
            }
            return
        }

        var currentActivityID: UUID?
        do {
            try Task.checkCancellation()
            let destinationListing: [SFTPPathComponent]
            do {
                destinationListing = try await client.listDirectory(atPath: destinationDirectory)
                    .flatMap(\.components)
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .inspectDestination
                    .failureMessage(
                        path: destinationDirectory,
                        serverDescription: error.localizedDescription
                    ))
            }
            var reservedDestinationNames = Set(destinationListing.map {
                Self.normalizedCollisionName($0.filename)
            })

            for entry in request.entries {
                guard Self.isSafeBasename(entry.filename) else {
                    throw SFTPTransferError.unsafeName
                }
                let normalizedName = Self.normalizedCollisionName(entry.filename)
                guard !reservedDestinationNames.contains(normalizedName) else {
                    throw SFTPRemoteOperationError.destinationCollision(entry.filename)
                }
                reservedDestinationNames.insert(normalizedName)
                if isDirectory(entry) {
                    let sourcePath = Self.remotePath(
                        directory: request.sourceDirectory,
                        basename: entry.filename
                    )
                    guard !Self.isRemotePath(destinationDirectory, inside: sourcePath) else {
                        throw SFTPRemoteOperationError.destinationInsideSource
                    }
                }
            }

            for (index, entry) in request.entries.enumerated() {
                try Task.checkCancellation()
                let activityID = activityIDs[index]
                currentActivityID = activityID
                transferActivity.begin(activityID)
                let prefix = request.entries.count > 1
                    ? "[\(index + 1)/\(request.entries.count)] "
                    : ""
                let sourcePath = Self.remotePath(
                    directory: request.sourceDirectory,
                    basename: entry.filename
                )
                let destinationPath = Self.remotePath(
                    directory: destinationDirectory,
                    basename: entry.filename
                )

                switch request.kind {
                case .copy:
                    operationInProgress = "\(prefix)Copying \(entry.filename)…"
                    _ = try await performVerifiedRemoteCopy(
                        client: client,
                        sshConnection: sshConnection,
                        sourcePath: sourcePath,
                        sourceName: entry.filename,
                        destinationDirectory: destinationDirectory,
                        destinationPath: destinationPath
                    )

                case .move:
                    operationInProgress = "\(prefix)Moving \(entry.filename)…"
                    do {
                        // SFTP RENAME is the typed, server-side, atomic fast path when
                        // source and destination live on the same filesystem.
                        try await client.rename(at: sourcePath, to: destinationPath)
                    } catch {
                        // Cross-filesystem servers may reject RENAME. Preserve Move
                        // semantics by completing and verifying a copy before deleting
                        // any source bytes.
                        operationInProgress = "\(prefix)Moving \(entry.filename) across filesystems…"
                        let copiedBaseline = try await performVerifiedRemoteCopy(
                            client: client,
                            sshConnection: sshConnection,
                            sourcePath: sourcePath,
                            sourceName: entry.filename,
                            destinationDirectory: destinationDirectory,
                            destinationPath: destinationPath
                        )
                        let sourceBeforeRetirement: [SFTPRemoteManifestEntry]
                        do {
                            sourceBeforeRetirement = try await Self.remoteManifest(
                                client: client,
                                rootPath: sourcePath,
                                maximumEntries: 100_000,
                                maximumBytes: BoundedStorage.maximumDownloadBytes
                            )
                        } catch {
                            throw Self.remotePhaseFailure(
                                .verifySource,
                                path: sourcePath,
                                underlying: error
                            )
                        }
                        guard Self.copyManifestMatches(
                            source: copiedBaseline,
                            destination: sourceBeforeRetirement
                        ) else {
                            throw SFTPRemoteOperationError.sourceChanged(entry.filename)
                        }
                        let retainedSourcePath = Self.remotePath(
                            directory: request.sourceDirectory,
                            basename: ".glas-sh-move-\(UUID().uuidString).retained"
                        )
                        do {
                            // Retire the verified source to an unpredictable sibling name
                            // first. Cleanup can no longer delete a replacement created at
                            // the original path after the copy verification completed.
                            try await client.rename(at: sourcePath, to: retainedSourcePath)
                        } catch {
                            throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                                .retireSource
                                .failureMessage(
                                    path: sourcePath,
                                    serverDescription: error.localizedDescription
                                ))
                        }
                        let retainedSource: [SFTPRemoteManifestEntry]
                        do {
                            retainedSource = try await Self.remoteManifest(
                                client: client,
                                rootPath: retainedSourcePath,
                                maximumEntries: 100_000,
                                maximumBytes: BoundedStorage.maximumDownloadBytes
                            )
                        } catch {
                            throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                                .verifyRetiredSource
                                .failureMessage(
                                    path: retainedSourcePath,
                                    serverDescription: error.localizedDescription
                                ))
                        }
                        guard Self.retainedSourceCanBeRemoved(
                            copiedBaseline: copiedBaseline,
                            retainedSource: retainedSource
                        ) else {
                            throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                                .verifyRetiredSource
                                .failureMessage(
                                    path: retainedSourcePath,
                                    serverDescription: "The retained item changed before cleanup."
                                ))
                        }
                        do {
                            try await Self.removeRemoteTree(client: client, path: retainedSourcePath)
                        } catch {
                            throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                                .removeRetiredSource
                                .failureMessage(
                                    path: retainedSourcePath,
                                    serverDescription: error.localizedDescription
                                ))
                        }
                    }
                }
                transferActivity.complete(activityID)
                currentActivityID = nil
                selectedFilenames.remove(entry.filename)
            }

            await loadDirectory()
        } catch {
            let failureMessage: String
            let wasCancelled = error is CancellationError
                || (error as? SFTPUploadWorkerFailure)?.kind == .cancelled
            if wasCancelled {
                failureMessage = "Remote \(request.kind.rawValue.lowercased()) cancelled. No existing destination was overwritten."
            } else if let failure = error as? SFTPUploadWorkerFailure {
                failureMessage = failure.message
            } else {
                failureMessage = "Remote \(request.kind.rawValue.lowercased()) failed: \(error.localizedDescription) No existing destination was overwritten; an interrupted operation may leave a hidden staging item or a newly created partial folder."
            }
            remoteOperationFailureMessage = failureMessage

            if let currentActivityID {
                if wasCancelled {
                    transferActivity.cancel(currentActivityID, detail: failureMessage)
                } else {
                    transferActivity.fail(currentActivityID, detail: failureMessage)
                }
            } else if !wasCancelled {
                for activityID in activityIDs
                    where transferActivity.activity(activityID)?.state == .pending {
                    transferActivity.fail(activityID, detail: failureMessage)
                }
            }
            transferActivity.cancelPending(
                activityIDs,
                detail: wasCancelled
                    ? "The transfer batch was cancelled."
                    : "The transfer batch stopped after a failure."
            )
            await loadDirectory()
        }
    }

    private func performVerifiedRemoteCopy(
        client: SFTPClient,
        sshConnection: SSHConnection,
        sourcePath: String,
        sourceName: String,
        destinationDirectory: String,
        destinationPath: String
    ) async throws -> [SFTPRemoteManifestEntry] {
        let maximumBytes = BoundedStorage.maximumDownloadBytes
        let maximumEntries = 100_000
        let stagingName = ".glas-sh-copy-\(UUID().uuidString).partial"
        let stagingPath = Self.remotePath(
            directory: destinationDirectory,
            basename: stagingName
        )
        var stagingExists = false
        var destinationWasPublished = false

        do {
            let baseline: [SFTPRemoteManifestEntry]
            do {
                baseline = try await Self.remoteManifest(
                    client: client,
                    rootPath: sourcePath,
                    maximumEntries: maximumEntries,
                    maximumBytes: maximumBytes
                )
            } catch {
                throw Self.remotePhaseFailure(
                    .readSource,
                    path: sourcePath,
                    underlying: error
                )
            }
            guard let root = baseline.first else {
                throw SFTPRemoteOperationError.sourceChanged(sourceName)
            }

            do {
                let command = Self.remoteCopyCommand(
                    sourcePath: sourcePath,
                    stagingPath: stagingPath
                )
                _ = try await sshConnection.executeRemoteCommand(
                    command,
                    maxResponseBytes: 64 * 1024
                )
                stagingExists = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if try await Self.remoteEntryExists(client: client, path: stagingPath) {
                    stagingExists = true
                    try await Self.removeRemoteTree(client: client, path: stagingPath)
                    stagingExists = false
                }
                do {
                    try await Self.relayRemoteCopy(
                        client: client,
                        serverID: session?.server.id ?? sessionID,
                        sourceRoot: sourcePath,
                        stagingRoot: stagingPath,
                        manifest: baseline,
                        maximumBytes: maximumBytes
                    )
                    stagingExists = true
                } catch {
                    stagingExists = (try? await Self.remoteEntryExists(
                        client: client,
                        path: stagingPath
                    )) == true
                    throw error
                }
            }

            let sourceAfterCopy: [SFTPRemoteManifestEntry]
            do {
                sourceAfterCopy = try await Self.remoteManifest(
                    client: client,
                    rootPath: sourcePath,
                    maximumEntries: maximumEntries,
                    maximumBytes: maximumBytes
                )
            } catch {
                throw Self.remotePhaseFailure(
                    .verifySource,
                    path: sourcePath,
                    underlying: error
                )
            }
            guard Self.copyManifestMatches(
                source: baseline,
                destination: sourceAfterCopy
            ) else {
                throw SFTPRemoteOperationError.sourceChanged(sourceName)
            }
            let staged: [SFTPRemoteManifestEntry]
            do {
                staged = try await Self.remoteManifest(
                    client: client,
                    rootPath: stagingPath,
                    maximumEntries: maximumEntries,
                    maximumBytes: maximumBytes
                )
            } catch {
                throw Self.remotePhaseFailure(
                    .verifyStaging,
                    path: stagingPath,
                    underlying: error
                )
            }
            guard Self.copyManifestMatches(source: baseline, destination: staged) else {
                throw SFTPRemoteOperationError.verificationFailed(sourceName)
            }

            switch root.kind {
            case .file:
                do {
                    if client.supportsExtension("hardlink@openssh.com", version: "1") {
                        try await client.hardLink(at: stagingPath, to: destinationPath)
                    } else {
                        _ = try await sshConnection.executeRemoteCommand(
                            Self.remoteNoClobberLinkCommand(
                                sourcePath: stagingPath,
                                destinationPath: destinationPath
                            ),
                            maxResponseBytes: 64 * 1024
                        )
                    }
                } catch {
                    throw Self.remotePhaseFailure(
                        .publishDestination,
                        path: destinationPath,
                        underlying: error
                    )
                }
                destinationWasPublished = true
                do {
                    try await client.remove(at: stagingPath)
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .cleanupStaging
                        .failureMessage(
                            path: destinationPath,
                            serverDescription: error.localizedDescription
                        ))
                }
                stagingExists = false

            case .directory:
                do {
                    // Staging is a verified sibling of the destination. One SFTP
                    // rename publishes the complete tree atomically and fails if a
                    // concurrent writer creates the destination first.
                    try await client.rename(at: stagingPath, to: destinationPath)
                } catch {
                    throw Self.remotePhaseFailure(
                        .publishDestination,
                        path: destinationPath,
                        underlying: error
                    )
                }
                destinationWasPublished = true
                stagingExists = false
            }
            return baseline
        } catch {
            if stagingExists {
                try? await Self.removeRemoteTree(client: client, path: stagingPath)
            }
            if destinationWasPublished {
                // Published files and directories are complete, verified snapshots.
                // Never remove a published destination while reporting later cleanup.
            }
            throw error
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated static func remoteCopyCommand(
        sourcePath: String,
        stagingPath: String
    ) -> String {
        let source = shellQuote(sourcePath)
        let staging = shellQuote(stagingPath)
        return "set -eu; command -v cp >/dev/null 2>&1 || exit 127; if [ -e \(staging) ] || [ -L \(staging) ]; then exit 73; fi; command cp -Rp \(source) \(staging)"
    }

    nonisolated static func remoteNoClobberLinkCommand(
        sourcePath: String,
        destinationPath: String
    ) -> String {
        let source = shellQuote(sourcePath)
        let destination = shellQuote(destinationPath)
        return "set -eu; if [ -e \(destination) ] || [ -L \(destination) ]; then exit 73; fi; command ln \(source) \(destination)"
    }

    nonisolated private static func remotePhaseFailure(
        _ phase: SFTPRemoteOperationPhase,
        path: String,
        underlying error: Error
    ) -> Error {
        if error is CancellationError
            || error is SFTPRemoteOperationError
            || error is SFTPTransferError
            || error is SFTPUploadWorkerFailure {
            return error
        }
        return SFTPUploadWorkerFailure(message: phase.failureMessage(
            path: path,
            serverDescription: error.localizedDescription
        ))
    }

    @concurrent
    private static func remoteManifest(
        client: SFTPClient,
        rootPath: String,
        maximumEntries: Int,
        maximumBytes: UInt64
    ) async throws -> [SFTPRemoteManifestEntry] {
        var pending: [(path: String, relativePath: String)] = [(rootPath, "")]
        var result: [SFTPRemoteManifestEntry] = []
        var aggregateBytes: UInt64 = 0

        while let item = pending.popLast() {
            try Task.checkCancellation()
            guard result.count < maximumEntries else {
                throw SFTPRemoteOperationError.tooManyEntries(maximumEntries)
            }
            let attributes = try await client.getLinkAttributes(at: item.path)
            switch attributes.fileType {
            case .directory:
                result.append(SFTPRemoteManifestEntry(
                    relativePath: item.relativePath,
                    kind: .directory,
                    size: 0,
                    permissions: attributes.permissions,
                    accessTime: attributes.accessModificationTime?.accessTime,
                    modificationTime: attributes.accessModificationTime?.modificationTime,
                    digest: nil
                ))
                let children = try await client.listDirectory(atPath: item.path)
                    .flatMap(\.components)
                    .filter { $0.filename != "." && $0.filename != ".." }
                for child in children.reversed() {
                    guard isSafeBasename(child.filename) else {
                        throw SFTPTransferError.unsafeName
                    }
                    let relativePath = item.relativePath.isEmpty
                        ? child.filename
                        : item.relativePath + "/" + child.filename
                    pending.append((
                        remotePath(directory: item.path, basename: child.filename),
                        relativePath
                    ))
                }

            case .regular:
                guard let size = attributes.size else {
                    throw SFTPTransferError.missingRemoteSize
                }
                let (newAggregate, overflow) = aggregateBytes.addingReportingOverflow(size)
                guard !overflow, newAggregate <= maximumBytes else {
                    throw SFTPRemoteOperationError.aggregateSizeExceeded(maximumBytes)
                }
                aggregateBytes = newAggregate
                let digest = try await remoteDigest(
                    client: client,
                    path: item.path,
                    expectedSize: size,
                    maximumBytes: maximumBytes
                )
                result.append(SFTPRemoteManifestEntry(
                    relativePath: item.relativePath,
                    kind: .file,
                    size: size,
                    permissions: attributes.permissions,
                    accessTime: attributes.accessModificationTime?.accessTime,
                    modificationTime: attributes.accessModificationTime?.modificationTime,
                    digest: digest
                ))

            case .symbolicLink, .characterDevice, .blockDevice, .fifo, .socket, .unknown, .none:
                let name = item.relativePath.isEmpty
                    ? (rootPath as NSString).lastPathComponent
                    : item.relativePath
                throw SFTPRemoteOperationError.unsupportedItem(name)
            }
        }

        return result.sorted { $0.relativePath < $1.relativePath }
    }

    @concurrent
    private static func remoteDigest(
        client: SFTPClient,
        path: String,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) async throws -> Data {
        guard expectedSize <= maximumBytes else {
            throw SFTPRemoteOperationError.aggregateSizeExceeded(maximumBytes)
        }
        let file = try await client.openFile(filePath: path, flags: .read)
        do {
            let openedAttributes = try await file.readAttributes()
            guard openedAttributes.isRegularFile,
                  openedAttributes.size == expectedSize else {
                throw SFTPTransferError.remoteSourceChanged
            }
            var hasher = SHA256()
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await file.read(from: offset, length: 262_144)
                guard chunk.readableBytes > 0 else { break }
                let data = Data(buffer: chunk)
                hasher.update(data: data)
                offset += UInt64(data.count)
                guard offset <= expectedSize else {
                    throw SFTPTransferError.remoteSourceChanged
                }
            }
            let completedAttributes = try await file.readAttributes()
            guard offset == expectedSize,
                  completedAttributes.isRegularFile,
                  completedAttributes.size == openedAttributes.size,
                  completedAttributes.accessModificationTime?.modificationTime
                    == openedAttributes.accessModificationTime?.modificationTime else {
                throw SFTPTransferError.remoteSourceChanged
            }
            try await file.close()
            return Data(hasher.finalize())
        } catch {
            try? await file.close()
            throw error
        }
    }

    nonisolated private static func copyManifestMatches(
        source: [SFTPRemoteManifestEntry],
        destination: [SFTPRemoteManifestEntry]
    ) -> Bool {
        guard source.count == destination.count else { return false }
        return zip(source, destination).allSatisfy { sourceEntry, destinationEntry in
            sourceEntry.relativePath == destinationEntry.relativePath
                && sourceEntry.kind == destinationEntry.kind
                && sourceEntry.size == destinationEntry.size
                && sourceEntry.permissions.map { $0 & 0o7777 }
                    == destinationEntry.permissions.map { $0 & 0o7777 }
                && sourceEntry.modificationTime == destinationEntry.modificationTime
                && sourceEntry.digest == destinationEntry.digest
        }
    }

    nonisolated static func retainedSourceCanBeRemoved(
        copiedBaseline: [SFTPRemoteManifestEntry],
        retainedSource: [SFTPRemoteManifestEntry]
    ) -> Bool {
        copyManifestMatches(source: copiedBaseline, destination: retainedSource)
    }

    @concurrent
    private static func relayRemoteCopy(
        client: SFTPClient,
        serverID: UUID,
        sourceRoot: String,
        stagingRoot: String,
        manifest: [SFTPRemoteManifestEntry],
        maximumBytes: UInt64
    ) async throws {
        guard let root = manifest.first else {
            throw SFTPTransferError.remoteSourceChanged
        }
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("glas-sh-remote-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localRoot,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let localDirectory = try openLocalDirectoryNoFollow(at: localRoot)
        defer { try? localDirectory.directory.close() }

        switch root.kind {
        case .file:
            let sourceName = (sourceRoot as NSString).lastPathComponent
            let stagingName = (stagingRoot as NSString).lastPathComponent
            do {
                try await performVerifiedDownload(
                    client: client,
                    serverID: serverID,
                    remotePath: sourceRoot,
                    sourceName: sourceName,
                    destinationDirectory: localDirectory.directory,
                    destinationDirectoryIdentity: localDirectory.identity,
                    exactDestinationName: sourceName,
                    progress: { _ in }
                )
            } catch let failure as SFTPDownloadWorkerFailure where failure.wasCancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .readSource
                    .failureMessage(
                        path: sourceRoot,
                        serverDescription: error.localizedDescription
                    ))
            }
            let localURL = localRoot.appendingPathComponent(sourceName)
            do {
                _ = try await performUpload(
                    client: client,
                    sourceURL: localURL,
                    serverID: serverID,
                    remoteDirectory: remoteParentPath(stagingRoot),
                    sourceName: sourceName,
                    finalName: stagingName,
                    targetPath: stagingRoot,
                    maximumUploadBytes: maximumBytes
                )
            } catch let failure as SFTPUploadWorkerFailure where failure.kind == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .createStaging
                    .failureMessage(
                        path: remoteParentPath(stagingRoot),
                        serverDescription: error.localizedDescription
                    ))
            }
            do {
                try await applyRemoteAttributes(
                    client: client,
                    path: stagingRoot,
                    manifestEntry: root
                )
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .prepareStagingMetadata
                    .failureMessage(
                        path: stagingRoot,
                        serverDescription: error.localizedDescription
                    ))
            }

        case .directory:
            do {
                try await client.createDirectory(atPath: stagingRoot)
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .createStaging
                    .failureMessage(
                        path: remoteParentPath(stagingRoot),
                        serverDescription: error.localizedDescription
                    ))
            }
            let directories = manifest
                .filter { $0.kind == .directory && !$0.relativePath.isEmpty }
                .sorted { pathDepth($0.relativePath) < pathDepth($1.relativePath) }
            for directory in directories {
                let destination = remotePath(directory: stagingRoot, relativePath: directory.relativePath)
                do {
                    try await client.createDirectory(atPath: destination)
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .createStaging
                        .failureMessage(
                            path: remoteParentPath(destination),
                            serverDescription: error.localizedDescription
                        ))
                }
            }

            for fileEntry in manifest.filter({ $0.kind == .file }) {
                try Task.checkCancellation()
                let sourcePath = remotePath(directory: sourceRoot, relativePath: fileEntry.relativePath)
                let destinationPath = remotePath(directory: stagingRoot, relativePath: fileEntry.relativePath)
                let basename = (fileEntry.relativePath as NSString).lastPathComponent
                guard isSafeBasename(basename) else { throw SFTPTransferError.unsafeName }
                do {
                    try await performVerifiedDownload(
                        client: client,
                        serverID: serverID,
                        remotePath: sourcePath,
                        sourceName: basename,
                        destinationDirectory: localDirectory.directory,
                        destinationDirectoryIdentity: localDirectory.identity,
                        exactDestinationName: basename,
                        progress: { _ in }
                    )
                } catch let failure as SFTPDownloadWorkerFailure where failure.wasCancelled {
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .readSource
                        .failureMessage(
                            path: sourcePath,
                            serverDescription: error.localizedDescription
                        ))
                }
                let localURL = localRoot.appendingPathComponent(basename)
                do {
                    _ = try await performUpload(
                        client: client,
                        sourceURL: localURL,
                        serverID: serverID,
                        remoteDirectory: remoteParentPath(destinationPath),
                        sourceName: basename,
                        finalName: basename,
                        targetPath: destinationPath,
                        maximumUploadBytes: maximumBytes
                    )
                } catch let failure as SFTPUploadWorkerFailure where failure.kind == .cancelled {
                    throw CancellationError()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .createStaging
                        .failureMessage(
                            path: remoteParentPath(destinationPath),
                            serverDescription: error.localizedDescription
                        ))
                }
                do {
                    try await applyRemoteAttributes(
                        client: client,
                        path: destinationPath,
                        manifestEntry: fileEntry
                    )
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .prepareStagingMetadata
                        .failureMessage(
                            path: destinationPath,
                            serverDescription: error.localizedDescription
                        ))
                }
                try FileManager.default.removeItem(at: localURL)
            }
            for directory in directories.sorted(by: {
                pathDepth($0.relativePath) > pathDepth($1.relativePath)
            }) {
                let destination = remotePath(
                    directory: stagingRoot,
                    relativePath: directory.relativePath
                )
                do {
                    try await applyRemoteAttributes(
                        client: client,
                        path: destination,
                        manifestEntry: directory
                    )
                } catch {
                    throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                        .prepareStagingMetadata
                        .failureMessage(
                            path: destination,
                            serverDescription: error.localizedDescription
                        ))
                }
            }
            do {
                try await applyRemoteAttributes(
                    client: client,
                    path: stagingRoot,
                    manifestEntry: root
                )
            } catch {
                throw SFTPUploadWorkerFailure(message: SFTPRemoteOperationPhase
                    .prepareStagingMetadata
                    .failureMessage(
                        path: stagingRoot,
                        serverDescription: error.localizedDescription
                    ))
            }
        }
    }

    @concurrent
    private static func applyRemoteAttributes(
        client: SFTPClient,
        path: String,
        manifestEntry: SFTPRemoteManifestEntry
    ) async throws {
        var attributes = SFTPFileAttributes.none
        attributes.permissions = manifestEntry.permissions.map { $0 & 0o7777 }
        if let accessTime = manifestEntry.accessTime,
           let modificationTime = manifestEntry.modificationTime {
            attributes.accessModificationTime = .init(
                accessTime: accessTime,
                modificationTime: modificationTime
            )
        }
        if !attributes.flags.isEmpty {
            try await client.setAttributes(at: path, to: attributes)
        }
    }

    nonisolated private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    nonisolated private static func remotePath(directory: String, relativePath: String) -> String {
        guard !relativePath.isEmpty else { return directory }
        return directory == "/" ? "/" + relativePath : directory + "/" + relativePath
    }

    @concurrent
    private static func remoteEntryExists(client: SFTPClient, path: String) async throws -> Bool {
        let parent = remoteParentPath(path)
        let name = (path as NSString).lastPathComponent
        return try await client.listDirectory(atPath: parent)
            .flatMap(\.components)
            .contains { $0.filename == name }
    }

    @concurrent
    private static func removeRemoteTree(client: SFTPClient, path: String) async throws {
        let attributes = try await client.getLinkAttributes(at: path)
        if attributes.fileType == .directory {
            let children = try await client.listDirectory(atPath: path)
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
            for child in children {
                guard isSafeBasename(child.filename) else { throw SFTPTransferError.unsafeName }
                try await removeRemoteTree(
                    client: client,
                    path: remotePath(directory: path, basename: child.filename)
                )
            }
            try await client.rmdir(at: path)
        } else {
            try await client.remove(at: path)
        }
    }

    // MARK: - Remote Search

    private var searchResultsSection: some View {
        Section {
            if isSearchingRemote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching server...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if searchResults.isEmpty {
                Text("No results found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults, id: \.self) { path in
                    Button {
                        navigateToSearchResult(path)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text(path)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Search Results")
        }
    }

    private func remoteFind(_ query: String) async {
        guard let session = session,
              let sshConnection = session.getSSHConnection() else { return }

        isSearchingRemote = true
        showingSearchResults = true
        searchResults = []

        do {
            let escapedPath = currentPath.replacingOccurrences(of: "'", with: "'\\''")
            let escapedQuery = query.replacingOccurrences(of: "'", with: "'\\''")
            let command = "find '\(escapedPath)' -maxdepth 3 -iname '*\(escapedQuery)*' 2>/dev/null | head -50"
            let output = try await sshConnection.executeRemoteCommand(command)
            searchResults = output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
        }

        isSearchingRemote = false
    }

    @concurrent
    private static func readVerifiedRemoteObservation(
        client: SFTPClient,
        path: String,
        maximumBytes: UInt64
    ) async throws -> SFTPRemoteFileObservation {
        let remoteFile = try await client.openFile(filePath: path, flags: .read)
        do {
            let sourceAttributes = try await remoteFile.readAttributes()
            guard sourceAttributes.isRegularFile else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            guard let expectedSize = sourceAttributes.size else {
                throw SFTPTransferError.missingRemoteSize
            }
            guard expectedSize <= maximumBytes else {
                throw EditorError.fileTooLarge(bytes: expectedSize, ceiling: maximumBytes)
            }
            guard expectedSize <= UInt64(Int.max) else {
                throw EditorError.fileTooLarge(bytes: expectedSize, ceiling: maximumBytes)
            }

            var data = Data()
            data.reserveCapacity(Int(expectedSize))
            var hasher = SHA256()
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await remoteFile.read(from: offset, length: 262_144)
                guard chunk.readableBytes > 0 else { break }
                let chunkData = Data(buffer: chunk)
                data.append(chunkData)
                hasher.update(data: chunkData)
                offset += UInt64(chunkData.count)
                guard offset <= maximumBytes else {
                    throw EditorError.fileTooLarge(bytes: offset, ceiling: maximumBytes)
                }
            }

            let completedAttributes = try await remoteFile.readAttributes()
            guard completedAttributes.isRegularFile,
                  completedAttributes.size == sourceAttributes.size,
                  completedAttributes.accessModificationTime?.modificationTime
                    == sourceAttributes.accessModificationTime?.modificationTime else {
                throw SFTPTransferError.remoteSourceChanged
            }
            guard offset == expectedSize else {
                throw SFTPTransferError.sizeMismatch(expected: expectedSize, actual: offset)
            }
            guard let digest = ContentDigest(bytes: Array(hasher.finalize())) else {
                throw SFTPTransferError.checksumMismatch
            }
            try await remoteFile.close()
            return SFTPRemoteFileObservation(
                data: data,
                stat: remoteStat(from: completedAttributes),
                digest: digest
            )
        } catch {
            try? await remoteFile.close()
            throw error
        }
    }

    nonisolated static func remoteStat(from attributes: SFTPFileAttributes) -> RemoteStat {
        let modificationSeconds = attributes.accessModificationTime.map {
            Int64($0.modificationTime.timeIntervalSince1970.rounded(.towardZero))
        }
        return RemoteStat(
            size: attributes.size,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: nil
        )
    }

    @concurrent
    private static func uploadRemoteEditorBytes(
        _ data: Data,
        client: SFTPClient,
        serverID: UUID,
        remoteDirectory: String,
        filename: String,
        targetPath: String,
        expectedRemote: SFTPRemoteFileObservation,
        maximumBytes: UInt64
    ) async throws -> SFTPUploadResult {
        let stagingDirectoryURL = try uploadMetadataDirectory()
        let stagingDirectory = try openLocalDirectoryNoFollow(at: stagingDirectoryURL)
        defer { try? stagingDirectory.directory.close() }

        let stagingName = ".glas-sh-editor-\(UUID().uuidString).source"
        let staged = try createProtectedTemporaryFile(
            in: stagingDirectory.directory,
            name: stagingName
        )
        var stagedIdentity = staged.identity
        do {
            try staged.file.write(contentsOf: data)
            try staged.file.synchronize()
            stagedIdentity = try localFileIdentity(for: staged.file)
            try setProtection(.complete, for: staged.file, matching: stagedIdentity)
            try staged.file.close()

            let result = try await performReplacementUpload(
                client: client,
                sourceURL: stagingDirectoryURL.appendingPathComponent(stagingName),
                serverID: serverID,
                remoteDirectory: remoteDirectory,
                sourceName: filename,
                finalName: filename,
                targetPath: targetPath,
                maximumUploadBytes: maximumBytes,
                expectedStat: expectedRemote.stat,
                expectedDigest: expectedRemote.digest
            )
            try removeLocalFileIfMatching(
                in: stagingDirectory.directory,
                name: stagingName,
                identity: stagedIdentity
            )
            return result
        } catch {
            try? staged.file.close()
            try? removeLocalFileIfMatching(
                in: stagingDirectory.directory,
                name: stagingName,
                identity: stagedIdentity
            )
            throw error
        }
    }

    @concurrent
    private static func performUpload(
        client: SFTPClient,
        sourceURL: URL,
        serverID: UUID,
        remoteDirectory: String,
        sourceName: String,
        finalName: String,
        targetPath: String,
        maximumUploadBytes: UInt64,
        progress: (@MainActor @Sendable (SFTPTransferProgressUpdate) -> Void)? = nil
    ) async throws -> Bool {
        try await performVerifiedUpload(
            client: client,
            sourceURL: sourceURL,
            serverID: serverID,
            remoteDirectory: remoteDirectory,
            sourceName: sourceName,
            finalName: finalName,
            targetPath: targetPath,
            maximumUploadBytes: maximumUploadBytes,
            commitPolicy: .createNoClobber,
            progress: progress
        ).cleanupWarning
    }

    @concurrent
    private static func performReplacementUpload(
        client: SFTPClient,
        sourceURL: URL,
        serverID: UUID,
        remoteDirectory: String,
        sourceName: String,
        finalName: String,
        targetPath: String,
        maximumUploadBytes: UInt64,
        expectedStat: RemoteStat,
        expectedDigest: ContentDigest
    ) async throws -> SFTPUploadResult {
        try await performVerifiedUpload(
            client: client,
            sourceURL: sourceURL,
            serverID: serverID,
            remoteDirectory: remoteDirectory,
            sourceName: sourceName,
            finalName: finalName,
            targetPath: targetPath,
            maximumUploadBytes: maximumUploadBytes,
            commitPolicy: .replaceExisting(
                expectedStat: expectedStat,
                expectedDigest: expectedDigest
            )
        )
    }

    @concurrent
    private static func performVerifiedUpload(
        client: SFTPClient,
        sourceURL: URL,
        serverID: UUID,
        remoteDirectory: String,
        sourceName: String,
        finalName: String,
        targetPath: String,
        maximumUploadBytes: UInt64,
        commitPolicy: SFTPUploadCommitPolicy,
        progress: (@MainActor @Sendable (SFTPTransferProgressUpdate) -> Void)? = nil
    ) async throws -> SFTPUploadResult {
        var replacementCommitMayHaveRun = false
        switch commitPolicy {
        case .createNoClobber:
            guard client.supportsExtension("hardlink@openssh.com", version: "1") else {
                throw SFTPTransferError.atomicCommitUnavailable
            }
        case .replaceExisting:
            guard client.supportsExtension("posix-rename@openssh.com", version: "1") else {
                throw SFTPTransferError.atomicReplacementUnavailable
            }
        }

        let openedSource = try openLocalSourceNoFollow(at: sourceURL)
        let localFile = openedSource.file
        let sourceIdentity = openedSource.identity
        defer { try? localFile.close() }
        guard sourceIdentity.size <= maximumUploadBytes else {
            let formattedLimit = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: maximumUploadBytes),
                countStyle: .file
            )
            throw SFTPUploadWorkerFailure(
                message: "The transfer exceeded its \(formattedLimit) storage limit."
            )
        }
        await progress?(.transferring(
            completedBytes: 0,
            totalBytes: sourceIdentity.size
        ))

        let resumeIdentity = uploadResumeIdentity(
            serverID: serverID,
            remoteDirectory: remoteDirectory,
            finalName: finalName,
            sourceName: sourceName,
            sourceSize: sourceIdentity.size,
            sourceModificationTime: sourceIdentity.modificationTime
        )
        let recordURL = try uploadRecordURL(for: resumeIdentity)
        var record = try loadUploadRecord(at: recordURL)
        if let existingRecord = record {
            guard existingRecord.matches(
                serverID: serverID,
                remoteDirectory: remoteDirectory,
                finalName: finalName,
                sourceName: sourceName,
                sourceSize: sourceIdentity.size,
                sourceModificationTime: sourceIdentity.modificationTime
            ) else {
                throw SFTPTransferError.invalidResumeMetadata
            }
            record?.updatedAt = Date()
        } else {
            record = SFTPUploadResumeRecord(
                version: SFTPUploadResumeRecord.currentVersion,
                createdAt: Date(),
                updatedAt: Date(),
                serverID: serverID,
                remoteDirectory: remoteDirectory,
                finalName: finalName,
                sourceName: sourceName,
                sourceSize: sourceIdentity.size,
                sourceModificationTime: sourceIdentity.modificationTime,
                partialName: ".glas-sh-upload-\(UUID().uuidString).partial"
            )
        }
        guard let record else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        try saveUploadRecord(record, at: recordURL)
        let partialPath = remoteDirectory.hasSuffix("/")
            ? remoteDirectory + record.partialName
            : remoteDirectory + "/" + record.partialName

        // Stream only to an unpredictable hidden name. The completed, verified
        // inode is exposed by OpenSSH hardlink, preserving atomic no-clobber.
        let remoteFile: SFTPFile
        do {
            let retainedAttributes = try await client.getLinkAttributes(at: partialPath)
            guard retainedAttributes.isRegularFile else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            remoteFile = try await client.openFile(
                filePath: partialPath,
                flags: [.read, .write]
            )
        } catch let transferError as SFTPTransferError {
            throw transferError
        } catch {
            remoteFile = try await client.openFile(
                filePath: partialPath,
                flags: [.read, .write, .create, .forceCreate]
            )
        }

        do {
            var offset: UInt64 = 0
            var localHasher = SHA256()
            let initialRemoteAttributes = try await remoteFile.readAttributes()
            guard initialRemoteAttributes.isRegularFile,
                  let initialRemoteSize = initialRemoteAttributes.size else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            guard initialRemoteSize <= sourceIdentity.size else {
                throw SFTPTransferError.invalidResumePartial
            }

            if initialRemoteSize > 0 {
                await progress?(.verifying)
            }
            while true {
                try Task.checkCancellation()
                let chunk = try await remoteFile.read(from: offset, length: 262_144)
                let remoteData = Data(buffer: chunk)
                guard !remoteData.isEmpty else { break }
                guard let localData = try localFile.read(upToCount: remoteData.count),
                      resumeChunksMatch(source: remoteData, retained: localData) else {
                    throw SFTPTransferError.invalidResumePartial
                }
                localHasher.update(data: localData)
                offset += UInt64(localData.count)
            }
            guard offset == initialRemoteSize else {
                throw SFTPTransferError.remoteSourceChanged
            }
            await progress?(.transferring(
                completedBytes: offset,
                totalBytes: sourceIdentity.size
            ))

            while let data = try localFile.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                localHasher.update(data: data)
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
                await progress?(.transferring(
                    completedBytes: offset,
                    totalBytes: sourceIdentity.size
                ))
            }
            guard offset == sourceIdentity.size,
                  Self.localFile(localFile, matches: sourceIdentity) else {
                throw SFTPTransferError.sourceChanged
            }
            if client.supportsExtension("fsync@openssh.com", version: "1") {
                try await remoteFile.synchronize()
            }

            let uploadedAttributes = try await remoteFile.readAttributes()
            guard uploadedAttributes.isRegularFile else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            guard let remoteSize = uploadedAttributes.size else {
                throw SFTPTransferError.missingRemoteSize
            }
            guard remoteSize == offset else {
                throw SFTPTransferError.sizeMismatch(expected: offset, actual: remoteSize)
            }

            await progress?(.verifying)
            let localDigest = Data(localHasher.finalize())
            var remoteHasher = SHA256()
            var remoteOffset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await remoteFile.read(from: remoteOffset, length: 262_144)
                guard chunk.readableBytes > 0 else { break }
                let data = Data(buffer: chunk)
                remoteHasher.update(data: data)
                remoteOffset += UInt64(data.count)
            }
            guard remoteOffset == offset else {
                throw SFTPTransferError.sizeMismatch(expected: offset, actual: remoteOffset)
            }
            let remoteDigest = Data(remoteHasher.finalize())
            guard localDigest == remoteDigest else {
                throw SFTPTransferError.checksumMismatch
            }

            let verifiedHandleAttributes = try await remoteFile.readAttributes()
            guard verifiedHandleAttributes.isRegularFile,
                  verifiedHandleAttributes.size == uploadedAttributes.size,
                  verifiedHandleAttributes.accessModificationTime?.modificationTime
                    == uploadedAttributes.accessModificationTime?.modificationTime else {
                throw SFTPTransferError.remoteSourceChanged
            }
            let verifiedPathAttributes = try await client.getLinkAttributes(at: partialPath)
            guard verifiedPathAttributes.isRegularFile,
                  verifiedPathAttributes.size == verifiedHandleAttributes.size,
                  verifiedPathAttributes.accessModificationTime?.modificationTime
                    == verifiedHandleAttributes.accessModificationTime?.modificationTime else {
                throw SFTPTransferError.remoteSourceChanged
            }

            guard let committedDigest = ContentDigest(bytes: Array(remoteDigest)) else {
                throw SFTPTransferError.checksumMismatch
            }

            switch commitPolicy {
            case .createNoClobber:
                // Preserve the established import path exactly: the verified partial is
                // exposed through an atomic no-clobber hard link, then cleaned up.
                try checkCancellationBeforeCommit()
                try await client.hardLink(at: partialPath, to: targetPath)
                try await remoteFile.close()
                do {
                    try await client.remove(at: partialPath)
                    try FileManager.default.removeItem(at: recordURL)
                    return SFTPUploadResult(
                        cleanupWarning: false,
                        committedStat: nil,
                        committedDigest: committedDigest
                    )
                } catch {
                    return SFTPUploadResult(
                        cleanupWarning: true,
                        committedStat: nil,
                        committedDigest: committedDigest
                    )
                }

            case .replaceExisting(let expectedStat, let expectedDigest):
                // The human authorization applies to the remote identity that was
                // observed before upload. Re-check immediately before the atomic rename
                // so another writer cannot hide inside the upload interval.
                let currentTarget: SFTPRemoteFileObservation
                do {
                    currentTarget = try await readVerifiedRemoteObservation(
                        client: client,
                        path: targetPath,
                        maximumBytes: maximumUploadBytes
                    )
                } catch {
                    throw SFTPRemoteCommitGuardFailure()
                }
                guard currentTarget.stat == expectedStat,
                      currentTarget.digest == expectedDigest else {
                    throw SFTPRemoteCommitGuardFailure()
                }

                let targetAttributes: SFTPFileAttributes
                do {
                    targetAttributes = try await client.getLinkAttributes(at: targetPath)
                } catch {
                    throw SFTPRemoteCommitGuardFailure()
                }
                guard remoteStat(from: targetAttributes) == currentTarget.stat else {
                    throw SFTPRemoteCommitGuardFailure()
                }
                if let permissions = targetAttributes.permissions {
                    var replacementAttributes = SFTPFileAttributes.none
                    // Preserve normal rwx/sticky behavior but do not re-arm setuid or
                    // setgid bits onto newly written content.
                    replacementAttributes.permissions = permissions & 0o1777
                    try await remoteFile.setAttributes(to: replacementAttributes)
                }
                let committedAttributes = try await remoteFile.readAttributes()
                guard committedAttributes.isRegularFile,
                      committedAttributes.size == verifiedHandleAttributes.size else {
                    throw SFTPTransferError.remoteSourceChanged
                }

                try checkCancellationBeforeCommit()
                replacementCommitMayHaveRun = true
                try await client.posixRename(at: partialPath, to: targetPath)
                try await remoteFile.close()

                let cleanupWarning: Bool
                do {
                    try FileManager.default.removeItem(at: recordURL)
                    cleanupWarning = false
                } catch {
                    cleanupWarning = true
                }
                return SFTPUploadResult(
                    cleanupWarning: cleanupWarning,
                    committedStat: remoteStat(from: committedAttributes),
                    committedDigest: committedDigest
                )
            }
        } catch {
            try? await remoteFile.close()
            switch commitPolicy {
            case .createNoClobber:
                let message = error is CancellationError
                    ? "Upload cancelled. A hidden partial may remain and will be validated before any future resume; no final file was exposed."
                    : "Upload of \(finalName) failed: \(error.localizedDescription). A hidden partial may remain and will be validated before any future resume; no incomplete final file was exposed."
                throw SFTPUploadWorkerFailure(
                    message: message,
                    kind: error is CancellationError ? .cancelled : .general
                )

            case .replaceExisting:
                // Editor saves are bounded to the in-memory editor ceiling, so retrying
                // from the model is preferable to orphaning a resume record whose local
                // staging file is intentionally short-lived.
                try? await client.remove(at: partialPath)
                try? FileManager.default.removeItem(at: recordURL)
                let kind: SFTPUploadWorkerFailure.Kind
                if error is SFTPRemoteCommitGuardFailure {
                    kind = .remoteTargetChanged
                } else if replacementCommitMayHaveRun {
                    kind = .commitOutcomeUnknown
                } else if error is CancellationError {
                    kind = .cancelled
                } else {
                    kind = .general
                }
                let message: String
                if replacementCommitMayHaveRun {
                    message = "The server did not confirm whether \(finalName) was replaced. glas.sh will verify the remote bytes before allowing another save."
                } else if error is CancellationError {
                    message = "Save cancelled. The original remote file was not replaced."
                } else {
                    message = "Save of \(finalName) failed: \(error.localizedDescription). The original remote file was not replaced."
                }
                throw SFTPUploadWorkerFailure(message: message, kind: kind)
            }
        }
    }

    private func navigateToSearchResult(_ path: String) {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty else { return }
        showingSearchResults = false
        searchResults = []
        filterText = ""
        Task { await navigateTo(parentPath) }
    }

    // MARK: - Helpers

    nonisolated static let downloadReadChunkSize: UInt32 = 256 * 1024
    nonisolated static let downloadMaximumConcurrentReads = SFTPFile.maximumPipelinedReadCount
    nonisolated private static let uploadMetadataMaximumRecordCount = 128
    nonisolated private static let uploadMetadataMaximumRecordBytes = 64 * 1024

    nonisolated static func downloadReadWindow(
        from offset: UInt64,
        through endOffset: UInt64,
        chunkSize: UInt32 = downloadReadChunkSize
    ) -> [SFTPFile.ReadRequest] {
        guard offset < endOffset, chunkSize > 0 else { return [] }

        var requests: [SFTPFile.ReadRequest] = []
        requests.reserveCapacity(downloadMaximumConcurrentReads)
        var nextOffset = offset
        while nextOffset < endOffset,
              requests.count < downloadMaximumConcurrentReads {
            let length = UInt32(min(UInt64(chunkSize), endOffset - nextOffset))
            requests.append(.init(offset: nextOffset, length: length))
            nextOffset += UInt64(length)
        }
        return requests
    }

    nonisolated static func downloadReadBatchDecision(
        requests: [SFTPFile.ReadRequest],
        readableByteCounts: [Int]
    ) throws -> SFTPDownloadReadBatchDecision {
        guard requests.count == readableByteCounts.count else {
            throw SFTPError.missingResponse
        }

        var acceptedResponseCount = 0
        for (request, readableByteCount) in zip(requests, readableByteCounts) {
            guard readableByteCount >= 0,
                  readableByteCount <= Int(request.length) else {
                throw SFTPError.invalidResponse
            }
            guard readableByteCount > 0 else {
                return .init(
                    acceptedResponseCount: acceptedResponseCount,
                    nextChunkSize: nil,
                    reachedEOF: true
                )
            }

            acceptedResponseCount += 1
            if readableByteCount < Int(request.length) {
                return .init(
                    acceptedResponseCount: acceptedResponseCount,
                    nextChunkSize: UInt32(readableByteCount),
                    reachedEOF: false
                )
            }
        }

        return .init(
            acceptedResponseCount: acceptedResponseCount,
            nextChunkSize: nil,
            reachedEOF: false
        )
    }

    nonisolated static func checkCancellationBeforeCommit() throws {
        try Task.checkCancellation()
    }

    nonisolated private static func transferIdentityDigest(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func downloadResumeIdentity(
        serverID: UUID,
        remotePath: String,
        size: UInt64,
        modificationTime: Date?
    ) -> String {
        transferIdentityDigest([
            "download-v1",
            serverID.uuidString.lowercased(),
            remotePath,
            String(size),
            modificationTime.map { String($0.timeIntervalSince1970.bitPattern) } ?? "none"
        ])
    }

    nonisolated static func uploadResumeIdentity(
        serverID: UUID,
        remoteDirectory: String,
        finalName: String,
        sourceName: String,
        sourceSize: UInt64,
        sourceModificationTime: TimeInterval
    ) -> String {
        transferIdentityDigest([
            "upload-v1",
            serverID.uuidString.lowercased(),
            remoteDirectory,
            finalName,
            sourceName,
            String(sourceSize),
            String(sourceModificationTime.bitPattern)
        ])
    }

    static func localResumeDecision(
        fileExists: Bool,
        isRegularAndContained: Bool,
        size: UInt64?,
        expectedSize: UInt64?
    ) -> SFTPLocalResumeDecision {
        guard fileExists else { return .create }
        guard isRegularAndContained, let size, let expectedSize else {
            return .rejectUnsafe
        }
        return size <= expectedSize ? .resume(offset: size) : .replaceOversized
    }

    nonisolated static func resumeChunksMatch(source: Data, retained: Data) -> Bool {
        !source.isEmpty && source.count == retained.count && source == retained
    }

    nonisolated static func localFileIdentity(for file: FileHandle) throws -> SFTPLocalFileIdentity {
        var metadata = stat()
        guard Darwin.fstat(file.fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        return SFTPLocalFileIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            size: UInt64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    nonisolated static func localDirectoryIdentity(for directory: FileHandle) throws -> SFTPLocalDirectoryIdentity {
        var metadata = stat()
        guard Darwin.fstat(directory.fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        return SFTPLocalDirectoryIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        )
    }

    nonisolated static func openLocalDirectoryNoFollow(
        at url: URL
    ) throws -> (directory: FileHandle, identity: SFTPLocalDirectoryIdentity) {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        let directory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return (directory, try localDirectoryIdentity(for: directory))
        } catch {
            try? directory.close()
            throw error
        }
    }

    nonisolated private static func localEntryIdentityNoFollow(
        in directory: FileHandle,
        name: String
    ) throws -> SFTPLocalFileIdentity {
        guard isSafeBasename(name) else { throw SFTPTransferError.unsafeName }
        var metadata = stat()
        let result = name.withCString { entryName in
            Darwin.fstatat(
                directory.fileDescriptor,
                entryName,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            if errno == ENOENT { throw SFTPLocalOpenError.notFound }
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        return SFTPLocalFileIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            size: UInt64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private static func localEntryExistsNoFollow(
        in directory: FileHandle,
        name: String
    ) throws -> Bool {
        guard isSafeBasename(name) else { throw SFTPTransferError.unsafeName }
        var metadata = stat()
        let result = name.withCString { entryName in
            Darwin.fstatat(
                directory.fileDescriptor,
                entryName,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw SFTPTransferError.cannotCreateTemporaryFile
    }

    nonisolated private static func openRegularFileNoFollow(
        at url: URL,
        flags: Int32,
        createExclusively: Bool = false
    ) throws -> (file: FileHandle, identity: SFTPLocalFileIdentity) {
        let openFlags = flags | O_NOFOLLOW | O_CLOEXEC
            | (createExclusively ? O_CREAT | O_EXCL : 0)
        let descriptor = url.path.withCString { path in
            createExclusively
                ? Darwin.open(path, openFlags, S_IRUSR | S_IWUSR)
                : Darwin.open(path, openFlags)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw SFTPLocalOpenError.notFound }
            throw SFTPTransferError.cannotCreateTemporaryFile
        }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return (file, try localFileIdentity(for: file))
        } catch {
            try? file.close()
            throw error
        }
    }

    nonisolated private static func openRegularFileNoFollow(
        in directory: FileHandle,
        name: String,
        flags: Int32,
        createExclusively: Bool = false
    ) throws -> (file: FileHandle, identity: SFTPLocalFileIdentity) {
        guard isSafeBasename(name) else { throw SFTPTransferError.unsafeName }
        _ = try localDirectoryIdentity(for: directory)
        let openFlags = flags | O_NOFOLLOW | O_CLOEXEC
            | (createExclusively ? O_CREAT | O_EXCL : 0)
        let descriptor = name.withCString { entryName in
            createExclusively
                ? Darwin.openat(
                    directory.fileDescriptor,
                    entryName,
                    openFlags,
                    S_IRUSR | S_IWUSR
                )
                : Darwin.openat(directory.fileDescriptor, entryName, openFlags)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw SFTPLocalOpenError.notFound }
            throw SFTPTransferError.cannotCreateTemporaryFile
        }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return (file, try localFileIdentity(for: file))
        } catch {
            try? file.close()
            throw error
        }
    }

    nonisolated static func openLocalSourceNoFollow(
        at url: URL
    ) throws -> (file: FileHandle, identity: SFTPLocalFileIdentity) {
        do {
            return try openRegularFileNoFollow(at: url, flags: O_RDONLY)
        } catch {
            throw SFTPTransferError.sourceChanged
        }
    }

    nonisolated static func localFile(
        _ file: FileHandle,
        matches identity: SFTPLocalFileIdentity
    ) -> Bool {
        (try? localFileIdentity(for: file)) == identity
    }

    static func localFileIdentityNoFollow(at url: URL) throws -> SFTPLocalFileIdentity {
        let opened = try openLocalSourceNoFollow(at: url)
        defer { try? opened.file.close() }
        return opened.identity
    }

    nonisolated private static func setProtection(
        _ protection: SFTPLocalProtectionClass,
        for file: FileHandle,
        matching identity: SFTPLocalFileIdentity
    ) throws {
        guard try localFileIdentity(for: file).isSameFile(as: identity),
              Darwin.fcntl(
                file.fileDescriptor,
                F_SETPROTECTIONCLASS,
                protection.rawValue
              ) == 0,
              try localFileIdentity(for: file).isSameFile(as: identity) else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
    }

    nonisolated static func removeLocalFileIfMatching(
        in directory: FileHandle,
        name: String,
        identity: SFTPLocalFileIdentity
    ) throws {
        guard try localEntryIdentityNoFollow(in: directory, name: name).isSameFile(as: identity)
        else { return }
        let result = name.withCString { entryName in
            Darwin.unlinkat(directory.fileDescriptor, entryName, 0)
        }
        guard result == 0 else { throw SFTPTransferError.cannotCreateTemporaryFile }
    }

    static func moveLocalFileNoClobber(
        in directory: FileHandle,
        sourceName: String,
        destinationName: String,
        matching identity: SFTPLocalFileIdentity
    ) throws {
        guard isSafeBasename(sourceName),
              isSafeBasename(destinationName),
              try localEntryIdentityNoFollow(in: directory, name: sourceName)
                .isSameFile(as: identity) else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        let result = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                Darwin.renameatx_np(
                    directory.fileDescriptor,
                    sourcePath,
                    directory.fileDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0,
              try localEntryIdentityNoFollow(in: directory, name: destinationName)
                .isSameFile(as: identity) else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
    }

    nonisolated static func createProtectedTemporaryFile(
        in directory: FileHandle,
        name: String
    ) throws -> (file: FileHandle, identity: SFTPLocalFileIdentity) {
        let opened = try openRegularFileNoFollow(
            in: directory,
            name: name,
            flags: O_RDWR,
            createExclusively: true
        )
        do {
            try setProtection(.completeUnlessOpen, for: opened.file, matching: opened.identity)
            return opened
        } catch {
            var cleanupFailed = false
            do {
                try opened.file.close()
            } catch {
                cleanupFailed = true
            }
            do {
                try removeLocalFileIfMatching(
                    in: directory,
                    name: name,
                    identity: opened.identity
                )
            } catch {
                cleanupFailed = true
            }
            if cleanupFailed {
                throw SFTPTransferError.cannotCreateTemporaryFile
            }
            throw error
        }
    }

    private static func availableCapacity(in directory: FileHandle) throws -> UInt64 {
        var fileSystem = statfs()
        guard Darwin.fstatfs(directory.fileDescriptor, &fileSystem) == 0 else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        let blocks = UInt64(fileSystem.f_bavail)
        let blockSize = UInt64(fileSystem.f_bsize)
        let (capacity, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow else { throw SFTPTransferError.cannotCreateTemporaryFile }
        return capacity
    }

    nonisolated private static func localFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        return size
    }

    private static func localSHA256(using file: FileHandle, expectedSize: UInt64) throws -> Data {
        try file.seek(toOffset: 0)
        var hasher = SHA256()
        var offset: UInt64 = 0
        while let data = try file.read(upToCount: 262_144), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            offset += UInt64(data.count)
        }
        guard offset == expectedSize else {
            throw SFTPTransferError.sizeMismatch(expected: expectedSize, actual: offset)
        }
        return Data(hasher.finalize())
    }

    nonisolated private static func uploadMetadataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SFTPTransferMetadata", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return directory
    }

    nonisolated static func canReserveUploadMetadataRecord(
        existingRecordNames: Set<String>,
        requestedName: String,
        maximumCount: Int = uploadMetadataMaximumRecordCount
    ) -> Bool {
        existingRecordNames.contains(requestedName)
            || existingRecordNames.count < maximumCount
    }

    nonisolated private static func uploadRecordURL(for identity: String) throws -> URL {
        let directory = try uploadMetadataDirectory()
        let recordURL = directory.appendingPathComponent(identity).appendingPathExtension("json")
        let existingNames = try Set(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }.map(\.lastPathComponent))
        guard canReserveUploadMetadataRecord(
            existingRecordNames: existingNames,
            requestedName: recordURL.lastPathComponent
        ) else {
            throw SFTPTransferError.resumeMetadataCapacityReached
        }
        return recordURL
    }

    nonisolated private static func loadUploadRecord(at url: URL) throws -> SFTPUploadResumeRecord? {
        do {
            let size = try localFileSize(at: url)
            guard size <= UInt64(uploadMetadataMaximumRecordBytes),
                  let record = try? JSONDecoder().decode(
                    SFTPUploadResumeRecord.self,
                    from: Data(contentsOf: url)
                  ) else {
                throw SFTPTransferError.invalidResumeMetadata
            }
            return record
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch SFTPLocalOpenError.notFound {
            return nil
        } catch let error as SFTPTransferError {
            throw error
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                return nil
            }
            throw SFTPTransferError.invalidResumeMetadata
        }
    }

    nonisolated private static func saveUploadRecord(_ record: SFTPUploadResumeRecord, at url: URL) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= uploadMetadataMaximumRecordBytes else {
            throw SFTPTransferError.cannotCreateTemporaryFile
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    nonisolated static func isSafeBasename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == name,
              name.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8),
              name != ".",
              name != "..",
              !name.hasPrefix("/"),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0") else { return false }
        guard name.unicodeScalars.allSatisfy({ scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }) else { return false }
        return (name as NSString).lastPathComponent == name
    }

    private func remotePath(for basename: String) -> String {
        currentPath.hasSuffix("/") ? currentPath + basename : currentPath + "/" + basename
    }

    static func isContained(_ candidate: URL, in folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return resolvedCandidate.deletingLastPathComponent() == base
    }

    /// Collision policy is deterministic rename; the final descriptor-relative
    /// RENAME_EXCL remains authoritative if another writer wins after probing.
    private static func collisionSafeDestinationName(
        for basename: String,
        in directory: FileHandle
    ) throws -> String {
        guard Self.isSafeBasename(basename) else { throw SFTPTransferError.unsafeName }
        let stem = (basename as NSString).deletingPathExtension
        let pathExtension = (basename as NSString).pathExtension
        var index = 1
        var candidate = basename

        while try Self.localEntryExistsNoFollow(in: directory, name: candidate) {
            index += 1
            let renamed = pathExtension.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(pathExtension)"
            guard Self.isSafeBasename(renamed) else { throw SFTPTransferError.unsafeName }
            candidate = renamed
        }
        return candidate
    }

    private static func normalizedCollisionName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Upload collision policy mirrors downloads and reserves each result for the complete batch.
    private func collisionSafeRemoteName(
        for basename: String,
        reservingIn reserved: inout Set<String>
    ) -> String {
        let normalizedBasename = Self.normalizedCollisionName(basename)
        guard reserved.contains(normalizedBasename) else {
            reserved.insert(normalizedBasename)
            return basename
        }
        let stem = (basename as NSString).deletingPathExtension
        let pathExtension = (basename as NSString).pathExtension
        var index = 2
        while true {
            let candidate = pathExtension.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(pathExtension)"
            let normalizedCandidate = Self.normalizedCollisionName(candidate)
            if !reserved.contains(normalizedCandidate) {
                reserved.insert(normalizedCandidate)
                return candidate
            }
            index += 1
        }
    }

    private func isDirectory(_ entry: SFTPPathComponent) -> Bool {
        // POSIX: directory bit is 0o40000 (S_IFDIR)
        if let permissions = entry.attributes.permissions {
            return (permissions & 0o170000) == 0o040000
        }
        // Fallback: check longname (ls -l format starts with 'd' for directories)
        return entry.longname.hasPrefix("d")
    }

    private func iconName(for entry: SFTPPathComponent) -> String {
        if isDirectory(entry) {
            return "folder.fill"
        }

        let ext = (entry.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log", "csv", "json", "xml", "yaml", "yml", "toml":
            return "doc.text.fill"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "m",
             "java", "kt", "sh", "bash", "zsh", "php", "html", "css", "sql":
            return "doc.text.fill"
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "svg", "webp", "heic":
            return "photo.fill"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso":
            return "doc.zipper"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "waveform"
        case "mp4", "mov", "avi", "mkv", "wmv", "webm":
            return "film"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }

    private func formattedFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formattedPermissions(_ permissions: UInt32) -> String {
        let mode = permissions & 0o777
        func rwx(_ bits: UInt32) -> String {
            let r = (bits & 4) != 0 ? "r" : "-"
            let w = (bits & 2) != 0 ? "w" : "-"
            let x = (bits & 1) != 0 ? "x" : "-"
            return r + w + x
        }
        let user = rwx(mode >> 6)
        let group = rwx((mode >> 3) & 7)
        let other = rwx(mode & 7)
        return user + group + other
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    private func pathComponents(from path: String) -> [String] {
        if path == "/" { return [""] }
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        components.insert("", at: 0) // Root
        return components
    }

    private func buildPath(from components: [String], upTo index: Int) -> String {
        if index == 0 { return "/" }
        let parts = components[1...index]
        return "/" + parts.joined(separator: "/")
    }

    private var fileInfoBinding: Binding<Bool> {
        Binding(
            get: { showingFileInfo != nil },
            set: {
                if !$0 {
                    showingFileInfo = nil
                    refreshedFileInfoAttributes = nil
                    fileInfoRefreshError = nil
                }
            }
        )
    }

    private func refreshFileInfo(for entry: SFTPPathComponent) async {
        guard let client = sftpClient else { return }
        do {
            let attributes = try await client.getLinkAttributes(
                at: remotePath(for: entry.filename)
            )
            guard showingFileInfo?.filename == entry.filename else { return }
            refreshedFileInfoAttributes = attributes
            fileInfoRefreshError = nil
        } catch {
            guard showingFileInfo?.filename == entry.filename else { return }
            fileInfoRefreshError = "Live attributes unavailable: \(error.localizedDescription)"
        }
    }

    private func fileInfoSheet(for entry: SFTPPathComponent) -> some View {
        let attributes = refreshedFileInfoAttributes ?? entry.attributes
        let isDir = isDirectory(entry)
        let itemPath = remotePath(for: entry.filename)

        return NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: iconName(for: entry))
                        .font(.system(size: 44))
                        .foregroundStyle(isDir ? Color.blue : Color.secondary)
                        .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.filename)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if let size = attributes.size, !isDir {
                            Text("\(formattedFileSize(size)) — \(size.formatted()) bytes")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(isDir ? "Remote folder" : "Remote item")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let modified = attributes.accessModificationTime?.modificationTime {
                            Text("Modified: \(formattedFullDate(modified))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        if let fileInfoRefreshError {
                            Label(fileInfoRefreshError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }

                        fileInfoDisclosure("General", isExpanded: $fileInfoGeneralExpanded) {
                            infoValue("Kind", value: kindDescription(for: entry))
                            if let size = attributes.size, !isDir {
                                infoValue(
                                    "Size",
                                    value: "\(size.formatted()) bytes (\(formattedFileSize(size)))"
                                )
                            }
                            infoValue("Where", value: currentPath)
                            infoValue("Created", value: "Not provided by SFTP v3")
                            if let times = attributes.accessModificationTime {
                                infoValue("Modified", value: formattedFullDate(times.modificationTime))
                                infoValue("Last accessed", value: formattedFullDate(times.accessTime))
                            }
                        }

                        fileInfoDisclosure("Network", isExpanded: $fileInfoNetworkExpanded) {
                            if let server = session?.server {
                                let remoteURL = Self.remoteClipboardURL(
                                    username: server.username,
                                    host: server.host,
                                    port: server.port,
                                    path: itemPath
                                )
                                infoValue("Server", value: "\(server.host):\(server.port)")
                                infoValue("Protocol", value: "SFTP over SSH")
                                infoValue("User", value: server.username)
                                infoValue("Status", value: sftpClient == nil ? "Disconnected" : "Connected")
                                infoValue(
                                    "Route",
                                    value: session?.jumpHostChain.isEmpty == false
                                        ? session!.jumpHostChain.map(\.name).joined(separator: " → ")
                                        : "Direct connection"
                                )
                                if let remoteURL {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Address")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 108, alignment: .trailing)
                                        Text(remoteURL.absoluteString)
                                            .font(.callout.monospaced())
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button {
                                            copyRemoteReferences([entry])
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Copy SFTP address")
                                    }
                                }
                            }
                        }

                        fileInfoDisclosure("Name & Extension", isExpanded: $fileInfoNameExpanded) {
                            infoValue("Name", value: entry.filename)
                            Button("Rename…") {
                                showingFileInfo = nil
                                beginRename(entry)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        if !isDir {
                            fileInfoDisclosure("Editor", isExpanded: $fileInfoEditorExpanded) {
                                if let document = remoteEditorDocument,
                                   document.remotePath == itemPath {
                                    infoValue(
                                        "Conflict",
                                        value: remoteEditorConflictDescription(document.model.conflictState)
                                    )
                                } else {
                                    infoValue("Conflict", value: "None")
                                }
                                Button("Edit Remote File") {
                                    showingFileInfo = nil
                                    beginRemoteEdit(entry)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }

                        fileInfoDisclosure(
                            "Sharing & Permissions",
                            isExpanded: $fileInfoPermissionsExpanded
                        ) {
                            if let permissions = attributes.permissions {
                                infoValue("Permissions", value: formattedPermissions(permissions))
                                infoValue(
                                    "Mode",
                                    value: String(format: "%04o", permissions & 0o7777)
                                )
                            }
                            if let uidGid = attributes.uidgid {
                                infoValue("Owner", value: "UID \(uidGid.userId)")
                                infoValue("Group", value: "GID \(uidGid.groupId)")
                            }
                            Text("Permissions are reported by the remote server and are read-only here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !entry.longname.isEmpty {
                            fileInfoDisclosure("Raw Listing", isExpanded: $fileInfoRawExpanded) {
                                Text(entry.longname)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Done") { showingFileInfo = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .navigationTitle("\(entry.filename) Info")
        }
        #if os(macOS)
        .frame(width: 520, height: 700)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func fileInfoDisclosure<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 8)
            .padding(.leading, 6)
        } label: {
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func infoValue(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func kindDescription(for entry: SFTPPathComponent) -> String {
        if isDirectory(entry) { return "Folder" }
        let pathExtension = (entry.filename as NSString).pathExtension
        guard !pathExtension.isEmpty else { return "Document" }
        return "\(pathExtension.uppercased()) document"
    }

    private func formattedFullDate(_ date: Date) -> String {
        date.formatted(date: .complete, time: .shortened)
    }
}
