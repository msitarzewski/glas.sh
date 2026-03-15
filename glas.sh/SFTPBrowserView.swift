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
    @State private var showingFileExporter = false
    @State private var exportFileData: Data?
    @State private var exportFileName: String?
    @State private var showingDeleteConfirmation = false
    @State private var entryToDelete: SFTPPathComponent?
    @State private var showingRenameAlert = false
    @State private var entryToRename: SFTPPathComponent?
    @State private var renameNewName = ""
    @State private var operationInProgress: String?

    private var session: TerminalSession? {
        sessionManager.session(for: sessionID)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(currentPath)
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
        .fileExporter(
            isPresented: $showingFileExporter,
            document: exportFileData.map { SFTPExportDocument(data: $0) },
            contentType: .data,
            defaultFilename: exportFileName ?? "download"
        ) { result in
            exportFileData = nil
            exportFileName = nil
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
            if let op = operationInProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(op)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
        .refreshable {
            await loadDirectory()
        }
    }

    private var sortedEntries: [SFTPPathComponent] {
        entries
            .filter { $0.filename != "." && $0.filename != ".." }
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
        Button {
            Task { await handleEntryTap(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: entry))
                    .font(.title3)
                    .foregroundStyle(isDirectory(entry) ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.filename)
                        .font(.body)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let size = entry.attributes.size, !isDirectory(entry) {
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

                if isDirectory(entry) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            let newPath: String
            if currentPath.hasSuffix("/") {
                newPath = currentPath + entry.filename
            } else {
                newPath = currentPath + "/" + entry.filename
            }
            await navigateTo(newPath)
        } else {
            await downloadFile(entry)
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
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    private func downloadFile(_ entry: SFTPPathComponent) async {
        guard let client = sftpClient else { return }

        let filePath: String
        if currentPath.hasSuffix("/") {
            filePath = currentPath + entry.filename
        } else {
            filePath = currentPath + "/" + entry.filename
        }

        operationInProgress = "Downloading \(entry.filename)..."
        defer { operationInProgress = nil }

        do {
            let file = try await client.openFile(filePath: filePath, flags: .read)
            let buffer = try await file.readAll()
            try await file.close()

            let data = Data(buffer: buffer)
            exportFileName = entry.filename
            exportFileData = data
            showingFileExporter = true
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
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
}

// MARK: - File Export Document

struct SFTPExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
