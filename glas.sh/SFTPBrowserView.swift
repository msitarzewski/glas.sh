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

nonisolated private struct SFTPUploadWorkerFailure: Error, Sendable {
    enum Kind: Sendable {
        case general
        case remoteTargetChanged
        case commitOutcomeUnknown
    }

    let message: String
    let kind: Kind

    init(message: String, kind: Kind = .general) {
        self.message = message
        self.kind = kind
    }
}

nonisolated private enum SFTPUploadCommitPolicy: Sendable {
    case createNoClobber
    case replaceExisting(expectedStat: RemoteStat, expectedDigest: ContentDigest)
}

nonisolated private struct SFTPRemoteCommitGuardFailure: Error, Sendable {}

nonisolated private struct SFTPUploadResult: Sendable {
    let cleanupWarning: Bool
    let committedStat: RemoteStat?
    let committedDigest: ContentDigest
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
    @State private var downloadProgress: Double = 0
    @State private var downloadTotal: String = ""
    @State private var showingDeleteConfirmation = false
    @State private var entryToDelete: SFTPPathComponent?
    @State private var operationInProgress: String?
    @State private var transferTask: Task<Void, Never>?

    // Selection
    @State private var selectedFilenames: Set<String> = []
    @State private var showingFileInfo: SFTPPathComponent?
    @State private var remoteEditorDocument: SFTPRemoteEditorDocument?
    @State private var showingBatchDeleteConfirmation = false

    // Filtering
    @State private var showHiddenFiles = false
    @State private var filterText = ""
    @State private var isSearchingRemote = false
    @State private var searchResults: [String] = []
    @State private var showingSearchResults = false

    private var session: TerminalSession? {
        sessionManager.session(for: sessionID)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(currentPath)
                .searchable(text: $filterText, prompt: "Filter files...")
                .terminalTextInputDefaults()
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
        .sheet(isPresented: fileInfoBinding) {
            if let entry = showingFileInfo {
                fileInfoSheet(for: entry)
            }
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

    private var fileList: some View {
        List {
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
                fileRow(for: entry)
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
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if !selectedFilenames.isEmpty {
                    selectionBar
                }
                if let op = operationInProgress {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(op)
                                .font(.caption)
                            Button("Cancel", role: .cancel) {
                                transferTask?.cancel()
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        if downloadProgress > 0 {
                            ProgressView(value: downloadProgress)
                                .frame(maxWidth: 240)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.bottom, 12)
        }
        .refreshable {
            await loadDirectory()
        }
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
        .background(.ultraThinMaterial, in: Capsule())
    }

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

    // MARK: - File Row

    private func fileRow(for entry: SFTPPathComponent) -> some View {
        let isDir = isDirectory(entry)
        let isSelected = selectedFilenames.contains(entry.filename)

        return HStack(spacing: 12) {
            if !isDir {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.blue : Color.gray.opacity(0.4))
                    .frame(width: 24)
            }

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
        .onTapGesture {
            if isDir {
                Task { await handleEntryTap(entry) }
            } else {
                toggleSelection(entry.filename)
            }
        }
    }

    @MainActor
    @discardableResult
    private func shutdownTransferAndConnection() async -> Bool {
        let activeTransfer = transferTask
        transferTask = nil
        activeTransfer?.cancel()
        await activeTransfer?.value

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
                let selectableFiles = sortedEntries.filter { !isDirectory($0) }

                if !selectableFiles.isEmpty {
                    Button {
                        selectedFilenames = Set(selectableFiles.map(\.filename))
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }

                    if !selectedFilenames.isEmpty {
                        Button {
                            selectedFilenames.removeAll()
                        } label: {
                            Label("Deselect All", systemImage: "circle")
                        }
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

        for (index, entry) in downloads.enumerated() {
            await downloadFileToFolder(
                entry,
                destinationDirectory: openedDestinationDirectory.directory,
                destinationDirectoryIdentity: openedDestinationDirectory.identity,
                current: index + 1,
                total: downloads.count
            )
        }

        selectedFilenames.removeAll()
    }

    private func downloadFileToFolder(
        _ entry: SFTPPathComponent,
        destinationDirectory: FileHandle,
        destinationDirectoryIdentity: SFTPLocalDirectoryIdentity,
        current: Int,
        total: Int
    ) async {
        guard let client = sftpClient else { return }
        guard Self.isSafeBasename(entry.filename) else {
            error = SFTPTransferError.unsafeName.localizedDescription
            return
        }

        let filePath = remotePath(for: entry.filename)

        let listedFileSize = entry.attributes.size
        let fileSize = listedFileSize ?? 0
        let fileSizeText = fileSize > 0 ? " (\(formattedFileSize(fileSize)))" : ""
        let prefix = total > 1 ? "[\(current)/\(total)] " : ""
        operationInProgress = "\(prefix)Downloading \(entry.filename)\(fileSizeText)..."
        downloadProgress = 0
        downloadTotal = formattedFileSize(fileSize)

        var retainedPartialName: String?
        var retainedPartialIdentity: SFTPLocalFileIdentity?
        var openedRemoteFile: SFTPFile?
        do {
            guard try Self.localDirectoryIdentity(for: destinationDirectory)
                    == destinationDirectoryIdentity else {
                throw SFTPTransferError.cannotCreateTemporaryFile
            }
            // FSTAT binds the source identity to the same opaque handle used for every
            // byte. A path-level STAT could instead describe a replacement inode.
            let remoteFile = try await client.openFile(filePath: filePath, flags: .read)
            openedRemoteFile = remoteFile
            let sourceAttributes = try await remoteFile.readAttributes()
            guard sourceAttributes.isRegularFile else {
                throw SFTPTransferError.remoteFileIsNotRegular
            }
            guard let expectedFileSize = sourceAttributes.size else {
                throw SFTPTransferError.missingRemoteSize
            }
            let sourceModificationTime = sourceAttributes.accessModificationTime?.modificationTime
            let destinationName = try collisionSafeDestinationName(
                for: entry.filename,
                in: destinationDirectory
            )
            let resumeIdentity = Self.downloadResumeIdentity(
                serverID: session?.server.id ?? sessionID,
                remotePath: filePath,
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

            let chunkSize: UInt32 = 262144
            var offset: UInt64 = 0
            var remoteHasher = SHA256()
            do {
                // Re-establish trust in every retained byte using the same open remote
                // handle that will supply the remainder. Only then seek to the append point.
                while offset < resumeOffset {
                    try Task.checkCancellation()
                    let requested = UInt32(min(UInt64(chunkSize), resumeOffset - offset))
                    let chunk = try await remoteFile.read(from: offset, length: requested)
                    let data = Data(buffer: chunk)
                    guard let localData = try localFile.read(upToCount: data.count),
                          Self.resumeChunksMatch(source: data, retained: localData) else {
                        keepPartial = false
                        throw SFTPTransferError.invalidResumePartial
                    }
                    remoteHasher.update(data: data)
                    offset += UInt64(data.count)
                }
                try localFile.seek(toOffset: resumeOffset)

                while true {
                    try Task.checkCancellation()
                    let chunk = try await remoteFile.read(from: offset, length: chunkSize)
                    let bytes = chunk.readableBytes
                    if bytes == 0 { break }

                    let incomingBytes = UInt64(bytes)
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

                    if fileSize > 0 {
                        downloadProgress = min(1, Double(offset) / Double(fileSize))
                        operationInProgress = "\(prefix)Downloading \(entry.filename) — \(Int(downloadProgress * 100))%"
                    }
                }
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
            let retention = partialWasRetained
                ? " A protected partial was retained and will be validated before any future resume."
                : " No partial file was kept."
            self.error = error is CancellationError
                ? "Download cancelled.\(retention)"
                : "Download of \(entry.filename) failed: \(error.localizedDescription)\(retention)"
        }

        operationInProgress = nil
        downloadProgress = 0
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        defer { transferTask = nil }
        guard let client = sftpClient else { return }

        switch result {
        case .success(let urls):
            // Reserve names for the whole selection. The visible directory listing is only a
            // snapshot, so without a batch reservation two local URLs with the same basename
            // could select the same remote target before the directory is refreshed.
            var reservedRemoteNames = Set(entries.map { Self.normalizedCollisionName($0.filename) })

            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                do {
                    defer { url.stopAccessingSecurityScopedResource() }
                    let sourceName = url.lastPathComponent
                    guard Self.isSafeBasename(sourceName) else {
                        throw SFTPTransferError.unsafeName
                    }
                    let filename = collisionSafeRemoteName(
                        for: sourceName,
                        reservingIn: &reservedRemoteNames
                    )
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
                    )
                    if cleanupWarning {
                        self.error = "Upload completed, but a tracked hidden cleanup file remains on the server."
                    }
                } catch let failure as SFTPUploadWorkerFailure {
                    self.error = failure.message
                    operationInProgress = nil
                    return
                } catch {
                    self.error = error is CancellationError
                        ? "Upload cancelled. No partial file was kept."
                        : "Upload failed: \(error.localizedDescription)"
                    operationInProgress = nil
                    return
                }
            }

            operationInProgress = nil
            await loadDirectory()

        case .failure(let err):
            self.error = "File selection failed: \(err.localizedDescription)"
        }
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
        maximumUploadBytes: UInt64
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
            commitPolicy: .createNoClobber
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
        commitPolicy: SFTPUploadCommitPolicy
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

            while let data = try localFile.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                localHasher.update(data: data)
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
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
                throw SFTPUploadWorkerFailure(message: message)

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

    nonisolated private static let uploadMetadataMaximumRecordCount = 128
    nonisolated private static let uploadMetadataMaximumRecordBytes = 64 * 1024

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
    private func collisionSafeDestinationName(
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
            set: { if !$0 { showingFileInfo = nil } }
        )
    }

    private func fileInfoSheet(for entry: SFTPPathComponent) -> some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Name", value: entry.filename)
                    if let size = entry.attributes.size {
                        LabeledContent("Size", value: formattedFileSize(size))
                    }
                    let ext = (entry.filename as NSString).pathExtension
                    if !ext.isEmpty {
                        LabeledContent("Type", value: ext.uppercased())
                    }
                }

                Section("Editor") {
                    if let document = remoteEditorDocument,
                       document.remotePath == remotePath(for: entry.filename) {
                        LabeledContent(
                            "Conflict",
                            value: remoteEditorConflictDescription(document.model.conflictState)
                        )
                    }
                    Button {
                        showingFileInfo = nil
                        beginRemoteEdit(entry)
                    } label: {
                        Label("Edit Remote File", systemImage: "pencil")
                    }
                }

                Section("Attributes") {
                    if let permissions = entry.attributes.permissions {
                        LabeledContent("Permissions", value: formattedPermissions(permissions))
                    }
                    if let uidGid = entry.attributes.uidgid {
                        LabeledContent("Owner (UID)", value: "\(uidGid.userId)")
                        LabeledContent("Group (GID)", value: "\(uidGid.groupId)")
                    }
                }

                Section("Timestamps") {
                    if let time = entry.attributes.accessModificationTime {
                        LabeledContent("Modified", value: formattedDate(time.modificationTime))
                        LabeledContent("Accessed", value: formattedDate(time.accessTime))
                    }
                }

                if !entry.longname.isEmpty {
                    Section("Raw Listing") {
                        Text(entry.longname)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("File Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFileInfo = nil }
                }
            }
        }
        .frame(width: 420, height: 400)
    }
}
