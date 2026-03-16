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

struct SFTPBrowserView: View {
    let sessionID: UUID
    @Environment(SessionManager.self) private var sessionManager
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
    @State private var showingRenameAlert = false
    @State private var entryToRename: SFTPPathComponent?
    @State private var renameNewName = ""
    @State private var operationInProgress: String?

    // Selection
    @State private var selectedFilenames: Set<String> = []
    @State private var showingFileInfo: SFTPPathComponent?
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
            Task { await handleFileImport(result) }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFolderSelection(result) }
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
        .alert("Rename", isPresented: $showingRenameAlert) {
            TextField("New name", text: $renameNewName)
            Button("Rename") {
                if let entry = entryToRename {
                    Task { await renameEntry(entry, to: renameNewName) }
                }
            }
            Button("Cancel", role: .cancel) {
                renameNewName = ""
                entryToRename = nil
            }
        } message: {
            if let entry = entryToRename {
                Text("Enter a new name for \"\(entry.filename)\".")
            }
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

                        Button {
                            entryToRename = entry
                            renameNewName = entry.filename
                            showingRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.orange)
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
                    try? await sftpClient?.close()
                    dismiss()
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
            selectedFilenames.removeAll()
            let newPath: String
            if currentPath.hasSuffix("/") {
                newPath = currentPath + entry.filename
            } else {
                newPath = currentPath + "/" + entry.filename
            }
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
        guard case .success(let urls) = result,
              let folderURL = urls.first else { return }

        guard folderURL.startAccessingSecurityScopedResource() else {
            error = "Cannot access the selected folder."
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let downloads = pendingDownloads
        pendingDownloads = []

        for (index, entry) in downloads.enumerated() {
            await downloadFileToFolder(entry, folder: folderURL, current: index + 1, total: downloads.count)
        }

        selectedFilenames.removeAll()
    }

    private func downloadFileToFolder(_ entry: SFTPPathComponent, folder: URL, current: Int, total: Int) async {
        guard let client = sftpClient else { return }

        let filePath: String
        if currentPath.hasSuffix("/") {
            filePath = currentPath + entry.filename
        } else {
            filePath = currentPath + "/" + entry.filename
        }

        let fileSize = entry.attributes.size ?? 0
        let fileSizeText = fileSize > 0 ? " (\(formattedFileSize(fileSize)))" : ""
        let prefix = total > 1 ? "[\(current)/\(total)] " : ""
        operationInProgress = "\(prefix)Downloading \(entry.filename)\(fileSizeText)..."
        downloadProgress = 0
        downloadTotal = formattedFileSize(fileSize)

        do {
            let file = try await client.openFile(filePath: filePath, flags: .read)

            let chunkSize: UInt32 = 32768
            var offset: UInt64 = 0
            var allData = Data()

            if fileSize > 0 {
                allData.reserveCapacity(Int(fileSize))
            }

            while true {
                let chunk = try await file.read(from: offset, length: chunkSize)
                let bytes = chunk.readableBytes
                if bytes == 0 { break }

                allData.append(Data(buffer: chunk))
                offset += UInt64(bytes)

                if fileSize > 0 {
                    downloadProgress = Double(offset) / Double(fileSize)
                    operationInProgress = "\(prefix)Downloading \(entry.filename) — \(Int(downloadProgress * 100))%"
                }
            }

            try await file.close()

            let destinationURL = folder.appendingPathComponent(entry.filename)
            try allData.write(to: destinationURL)

        } catch {
            self.error = "Download of \(entry.filename) failed: \(error.localizedDescription)"
        }

        operationInProgress = nil
        downloadProgress = 0
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        guard let client = sftpClient else { return }

        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                let filename = url.lastPathComponent
                let remotePath: String
                if currentPath.hasSuffix("/") {
                    remotePath = currentPath + filename
                } else {
                    remotePath = currentPath + "/" + filename
                }

                operationInProgress = "Uploading \(filename)..."

                do {
                    let data = try Data(contentsOf: url)
                    var buffer = ByteBuffer()
                    buffer.writeBytes(data)

                    let file = try await client.openFile(
                        filePath: remotePath,
                        flags: [.write, .create, .truncate]
                    )
                    try await file.write(buffer)
                    try await file.close()
                } catch {
                    self.error = "Upload of \(filename) failed: \(error.localizedDescription)"
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
        guard let client = sftpClient, !name.isEmpty else { return }

        let folderPath: String
        if currentPath.hasSuffix("/") {
            folderPath = currentPath + name
        } else {
            folderPath = currentPath + "/" + name
        }

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

        let itemPath: String
        if currentPath.hasSuffix("/") {
            itemPath = currentPath + entry.filename
        } else {
            itemPath = currentPath + "/" + entry.filename
        }

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

    private func renameEntry(_ entry: SFTPPathComponent, to newName: String) async {
        guard let client = sftpClient, !newName.isEmpty else { return }

        let oldPath: String
        if currentPath.hasSuffix("/") {
            oldPath = currentPath + entry.filename
        } else {
            oldPath = currentPath + "/" + entry.filename
        }

        let newPath: String
        if currentPath.hasSuffix("/") {
            newPath = currentPath + newName
        } else {
            newPath = currentPath + "/" + newName
        }

        operationInProgress = "Renaming..."
        defer {
            operationInProgress = nil
            entryToRename = nil
            renameNewName = ""
        }

        do {
            try await client.rename(at: oldPath, to: newPath)
            await loadDirectory()
        } catch {
            self.error = "Failed to rename: \(error.localizedDescription)"
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

    private func navigateToSearchResult(_ path: String) {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty else { return }
        showingSearchResults = false
        searchResults = []
        filterText = ""
        Task { await navigateTo(parentPath) }
    }

    // MARK: - Helpers

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

