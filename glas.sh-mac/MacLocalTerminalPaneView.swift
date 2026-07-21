import AppKit
import RealityKitContent
import SwiftUI

struct MacLocalTerminalPaneView: View {
    let workspaceID: UUID
    let isFocused: Bool
    let showsPaneChrome: Bool
    let findRequestNonce: UInt64
    let claimStartupCommand: () -> TerminalStartupCommandTicket?
    let onFocus: () -> Void
    let onNewTerminalTab: () -> Void
    let onDisconnect: () -> Void

    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.openWindow) private var openWindow
    @StateObject private var hostModel = SwiftTermHostModel()
    @StateObject private var processState = SwiftTermLocalProcessState()
    @State private var aiAssistant = AIAssistant()
    @State private var recorder = SessionRecorder()
    @State private var localSessionID = UUID()
    @State private var showingSearch = false
    @State private var searchQuery = ""
    @State private var searchFound: Bool?
    @State private var showingAIAssistant = false
    @State private var showingSnippets = false
    @State private var showingRecordings = false
    @State private var showingRecordingConsent = false
    @State private var showingDisconnectConfirmation = false
    @State private var recordingError: String?
    @State private var terminalColumns = 120
    @State private var terminalRows = 40
    @State private var localTerminalWindow: NSWindow?
    @State private var isLocalFullScreen = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showingSearch {
                localSearchBar
                    .background(.regularMaterial)
                Divider()
            }
            SwiftTermLocalProcessHostView(
                model: hostModel,
                processState: processState,
                configuration: localConfiguration,
                theme: terminalTheme,
                runtimeSettings: runtimeSettings,
                onOutputData: { recorder.recordOutput($0) },
                onInputData: { recorder.recordInput($0) },
                onResize: { columns, rows in
                    terminalColumns = max(20, columns)
                    terminalRows = max(8, rows)
                    recorder.recordResize(width: columns, height: rows)
                },
                onBell: {
                    if settingsManager.bellEnabled { NSSound.beep() }
                },
                onProcessReady: {
                    guard let ticket = claimStartupCommand() else { return }
                    _ = processState.sendCommand(ticket.command)
                },
                onProcessTerminated: { exitCode in
                    if recorder.isRecording { _ = recorder.stop() }
                    MacSecureKeyboardEntry.shared.disable(for: workspaceID)
                    if MacLocalTerminalExitPolicy.shouldClose(exitCode: exitCode) {
                        onDisconnect()
                    }
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                TerminalCanvasBackground(
                    color: settingsManager.currentTheme.background,
                    tint: TerminalGlassTint.color(for: settingsManager.glassTint),
                    opacity: settingsManager.windowOpacity,
                    blur: settingsManager.blurBackground,
                    appearance: settingsManager.currentTheme.resolvedAppearance
                )
            }
            .overlay {
                if let launchError = processState.launchError {
                    ContentUnavailableView(
                        "Local Shell Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(launchError)
                    )
                    .background(.regularMaterial)
                }
            }
            localFooter
        }
        .clipShape(.rect(cornerRadius: showsPaneChrome ? 18 : 0, style: .continuous))
        .overlay {
            if showsPaneChrome {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .background {
            MacTerminalWindowAccessor { window in
                if localTerminalWindow !== window {
                    localTerminalWindow = window
                    isLocalFullScreen = window.styleMask.contains(.fullScreen)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            onFocus()
            processState.focus()
        })
        .onAppear {
            aiAssistant.checkAvailability()
            if isFocused { processState.focus() }
        }
        .onDisappear {
            if recorder.isRecording { _ = recorder.stop() }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { processState.focus() }
        }
        .onChange(of: findRequestNonce) { _, nonce in
            guard nonce > 0 else { return }
            showingSearch = true
            hostModel.setFocusOwnershipAllowed(false)
            searchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
            updateLocalFullScreenState(from: $0, isFullScreen: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
            updateLocalFullScreenState(from: $0, isFullScreen: false)
        }
        .sheet(isPresented: $showingAIAssistant, onDismiss: restoreTerminalFocus) {
            AIAssistantView(
                aiAssistant: aiAssistant,
                host: "localhost",
                username: NSUserName(),
                currentDirectory: processState.currentDirectory,
                onRunCommand: { _ = processState.sendCommand($0) }
            )
        }
        .sheet(isPresented: $showingSnippets, onDismiss: restoreTerminalFocus) {
            localSnippetsSheet
        }
        .sheet(isPresented: $showingRecordings, onDismiss: restoreTerminalFocus) {
            MacLocalRecordingHistoryView {
                showingRecordings = false
            }
        }
        .confirmationDialog(
            "Start Local Terminal Recording",
            isPresented: $showingRecordingConsent,
            titleVisibility: .visible
        ) {
            Button("Record Output Only") { startRecording(capturesInput: false) }
            Button("Record Output and Keyboard Input", role: .destructive) {
                startRecording(capturesInput: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Output-only is the safest default. Keyboard input may include passwords, tokens, and other secrets.")
        }
        .confirmationDialog(
            "Disconnect Local Terminal?",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: disconnectLocalTerminal)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The local shell process will end and this terminal pane will close.")
        }
        .alert("Recording Failed", isPresented: recordingErrorPresented) {
            Button("OK", role: .cancel) { recordingError = nil }
        } message: {
            Text(recordingError ?? "The local terminal recording could not be changed.")
        }
        .sheet(item: pendingPasteBinding) { request in
            MacTerminalPasteReviewSheet(
                request: request,
                onCancel: { hostModel.resolvePendingPaste(approvedText: nil) },
                onPaste: { hostModel.resolvePendingPaste(approvedText: $0) }
            )
        }
        .alert(
            "Open External Link?",
            isPresented: externalLinkConfirmationBinding,
            presenting: hostModel.pendingExternalLink
        ) { _ in
            Button("Open") {
                if let url = hostModel.resolvePendingExternalLink(approved: true) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {
                _ = hostModel.resolvePendingExternalLink(approved: false)
            }
        } message: { request in
            let authority = request.port.map { "\(request.normalizedHost):\($0)" }
                ?? request.normalizedHost
            Text("A local terminal link wants to open this address.\n\nHost: \(authority)\n\nExact URL:\n\(request.exactURL)")
        }
    }

    private var localSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in terminal", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { searchFound = hostModel.findNext(searchQuery) }
            if searchFound == false {
                Text("No match")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Previous", systemImage: "chevron.up") {
                searchFound = hostModel.findPrevious(searchQuery)
            }
            .labelStyle(.iconOnly)
            .disabled(searchQuery.isEmpty)
            Button("Next", systemImage: "chevron.down") {
                searchFound = hostModel.findNext(searchQuery)
            }
            .labelStyle(.iconOnly)
            .disabled(searchQuery.isEmpty)
            Button("Close", systemImage: "xmark") {
                showingSearch = false
                searchQuery = ""
                searchFound = nil
                hostModel.clearSearch()
                hostModel.setFocusOwnershipAllowed(true)
                processState.focus()
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var localBottomBar: some View {
        ViewThatFits(in: .horizontal) {
            expandedLocalBottomBar
            compactLocalBottomBar
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var localFooter: some View {
        localBottomBar
            .frame(maxWidth: .infinity)
            .background {
                MacTerminalVisualEffect(
                    amount: 1,
                    material: .titlebar,
                    state: .followsWindowActiveState
                )
            }
    }

    private var expandedLocalBottomBar: some View {
        HStack(spacing: 10) {
            localProcessStatus

            Button("Connections", systemImage: "server.rack") {
                openWindow(id: "main")
            }
            .labelStyle(.iconOnly)
            .help("Connections")

            if aiAssistant.isAvailable {
                Button("AI Assistant", systemImage: "sparkles") {
                    presentAIAssistant()
                }
                .labelStyle(.iconOnly)
                .disabled(!processState.isRunning)
                .help("AI Assistant")
            }

            Button("Reveal Working Directory", systemImage: "folder.fill") {
                revealWorkingDirectory()
            }
            .labelStyle(.iconOnly)
            .help("Reveal Working Directory in Finder")

            Button(
                isLocalFullScreen ? "Exit Focus Mode" : "Focus Mode",
                systemImage: isLocalFullScreen ? "moon.fill" : "moon"
            ) {
                processState.toggleFullScreen()
            }
            .labelStyle(.iconOnly)
            .help(isLocalFullScreen ? "Exit Focus Mode" : "Focus Mode")

            localRecordingIndicator
            Button("New Terminal Tab", systemImage: "plus", action: onNewTerminalTab)
                .labelStyle(.iconOnly)
                .help("New Terminal Tab")
            localToolsMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactLocalBottomBar: some View {
        HStack(spacing: 8) {
            localProcessStatus
            localRecordingIndicator
            Button("New Terminal Tab", systemImage: "plus", action: onNewTerminalTab)
                .labelStyle(.iconOnly)
                .help("New Terminal Tab")
            localToolsMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var localProcessStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(processState.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(localProcessStatusText)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local terminal status: \(localProcessStatusText)")
    }

    private var localProcessStatusText: String {
        if processState.isRunning { return "Connected" }
        if let exitCode = processState.exitCode { return "Exited \(exitCode)" }
        return processState.launchError == nil ? "Starting" : "Failed"
    }

    @ViewBuilder
    private var localRecordingIndicator: some View {
        if recorder.isRecording {
            if recorder.capturesInput {
                Label("INPUT REC", systemImage: "keyboard.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: Capsule())
                    .accessibilityLabel("Recording terminal output and keyboard input")
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("Recording terminal output only")
            }
        }
    }

    private var localToolsMenu: some View {
        Menu {
            Button("Connections", systemImage: "server.rack") {
                openWindow(id: "main")
            }
            if aiAssistant.isAvailable {
                Button("AI Assistant", systemImage: "sparkles") {
                    presentAIAssistant()
                }
                .disabled(!processState.isRunning)
            }
            Button("Reveal Working Directory", systemImage: "folder.fill") {
                revealWorkingDirectory()
            }
            Button(
                isLocalFullScreen ? "Exit Focus Mode" : "Focus Mode",
                systemImage: isLocalFullScreen ? "moon.fill" : "moon"
            ) {
                processState.toggleFullScreen()
            }

            Divider()

            Button("Search", systemImage: "magnifyingglass") { presentSearch() }
            Button("Clear", systemImage: "trash") {
                processState.clearDisplay()
                restoreTerminalFocus()
            }
            #if DEBUG
            Button("HTML Preview", systemImage: "safari") {
                openWindow(
                    id: "html-preview",
                    value: HTMLPreviewContext(
                        sessionID: localSessionID,
                        url: "http://localhost:8080"
                    )
                )
            }
            #endif
            Button("Snippets", systemImage: "text.page") { presentSnippets() }
                .disabled(!processState.isRunning || settingsManager.snippets.isEmpty)

            Divider()

            if recorder.isRecording {
                Button("Stop Recording", systemImage: "stop.circle.fill") { stopRecording() }
            } else {
                Button("Start Recording…", systemImage: "record.circle") {
                    showingRecordingConsent = true
                }
                .disabled(!processState.isRunning)
            }
            Button("Recordings", systemImage: "list.bullet.rectangle") {
                presentRecordings()
            }

            Divider()

            Button("New Local Terminal Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: "workspace", value: MacWorkspaceLaunchRequest())
            }

            if !processState.isRunning {
                Button("Restart", systemImage: "arrow.clockwise") {
                    restartLocalTerminal()
                }
            }

            Button(
                processState.isRunning ? "Disconnect" : "Close Pane",
                systemImage: "xmark.circle",
                role: .destructive
            ) {
                if settingsManager.confirmBeforeClosing && processState.isRunning {
                    showingDisconnectConfirmation = true
                } else {
                    disconnectLocalTerminal()
                }
            }

            Divider()

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuOrder(.fixed)
        .help("Local Terminal Tools")
        .accessibilityLabel("Local terminal tools menu")
    }

    private var localSnippetsSheet: some View {
        NavigationStack {
            List(settingsManager.snippets) { snippet in
                Button {
                    if processState.sendCommand(snippet.command) {
                        settingsManager.useSnippet(snippet.id)
                        showingSnippets = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.name)
                        Text(snippet.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Run Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSnippets = false }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func presentSearch() {
        showingSearch = true
        hostModel.setFocusOwnershipAllowed(false)
        searchFieldFocused = true
    }

    private func presentAIAssistant() {
        hostModel.setFocusOwnershipAllowed(false)
        showingAIAssistant = true
    }

    private func presentSnippets() {
        hostModel.setFocusOwnershipAllowed(false)
        showingSnippets = true
    }

    private func presentRecordings() {
        hostModel.setFocusOwnershipAllowed(false)
        showingRecordings = true
    }

    private func disconnectLocalTerminal() {
        if recorder.isRecording { _ = recorder.stop() }
        processState.terminate()
        onDisconnect()
    }

    private func restartLocalTerminal() {
        localSessionID = UUID()
        if !processState.restart(localConfiguration) {
            recordingError = processState.launchError ?? "The local shell could not be restarted."
        }
        restoreTerminalFocus()
    }

    private func updateLocalFullScreenState(
        from notification: Notification,
        isFullScreen: Bool
    ) {
        guard let window = notification.object as? NSWindow,
              window === localTerminalWindow else { return }
        isLocalFullScreen = isFullScreen
    }

    private func restoreTerminalFocus() {
        hostModel.setFocusOwnershipAllowed(true)
        if isFocused { processState.focus() }
    }

    private func revealWorkingDirectory() {
        let path = processState.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var isDirectory = ObjCBool(false)
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    private func startRecording(capturesInput: Bool) {
        recorder.start(
            sessionID: localSessionID,
            serverName: "Local Terminal",
            host: "localhost",
            width: terminalColumns,
            height: terminalRows,
            capturesInput: capturesInput
        )
        if !recorder.isRecording {
            recordingError = recorder.lastError ?? "The local terminal recording did not start."
        }
        restoreTerminalFocus()
    }

    private func stopRecording() {
        let recording = recorder.stop()
        if recording?.isComplete != true {
            recordingError = recorder.lastError ?? "The local terminal recording was not finalized."
        }
        restoreTerminalFocus()
    }

    private var recordingErrorPresented: Binding<Bool> {
        Binding(
            get: { recordingError != nil },
            set: { if !$0 { recordingError = nil } }
        )
    }

    private var localConfiguration: SwiftTermLocalProcessConfiguration {
        let configuredShell = ProcessInfo.processInfo.environment["SHELL"]
        let executable = configuredShell.flatMap { shell in
            shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell)
                ? shell
                : nil
        } ?? "/bin/zsh"
        return SwiftTermLocalProcessConfiguration(
            executable: executable,
            arguments: ["-l"],
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private var runtimeSettings: SwiftTermRuntimeSettings {
        SwiftTermRuntimeSettings(
            cursorStyle: settingsManager.cursorStyle,
            blinkingCursor: settingsManager.blinkingCursor,
            scrollbackLines: settingsManager.saveScrollback
                ? settingsManager.maxScrollbackLines
                : 0
        )
    }

    private var terminalTheme: SwiftTermTheme {
        settingsManager.currentTheme.swiftTermTheme
    }

    private var pendingPasteBinding: Binding<SwiftTermPasteReview?> {
        Binding(
            get: { hostModel.pendingPasteReview },
            set: { if $0 == nil { hostModel.resolvePendingPaste(approvedText: nil) } }
        )
    }

    private var externalLinkConfirmationBinding: Binding<Bool> {
        Binding(
            get: { hostModel.pendingExternalLink != nil },
            set: { if !$0 { _ = hostModel.resolvePendingExternalLink(approved: false) } }
        )
    }
}

enum MacLocalTerminalExitPolicy {
    static func shouldClose(exitCode: Int32?) -> Bool {
        exitCode == 0
    }
}

private struct MacLocalRecordingHistoryView: View {
    let onDone: () -> Void

    @State private var recordings: [SessionRecording] = []
    @State private var pendingDeletion: SessionRecording?
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            List {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform",
                        description: Text("Local and SSH terminal recordings will appear here.")
                    )
                } else {
                    ForEach(recordings) { recording in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.serverName)
                                    .font(.headline)
                                Text(recording.host)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(recording.startTime, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(recording.eventCount) events")
                                    .font(.caption.monospacedDigit())
                                if let endTime = recording.endTime {
                                    let duration = endTime.timeIntervalSince(recording.startTime)
                                    Text("Duration: \(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                if !recording.isComplete {
                                    Label("Interrupted", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = recording
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }
            .navigationTitle("Recording History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .onAppear { recordings = SessionRecorder.loadRecordings() }
        }
        .confirmationDialog(
            "Delete Recording?",
            isPresented: deletionPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { recording in
            Button("Delete", role: .destructive) { delete(recording) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { recording in
            Text("Permanently delete the recording of \(recording.serverName)? This cannot be undone.")
        }
        .alert("Recording Deletion Failed", isPresented: deletionErrorPresented) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "The recording could not be deleted.")
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private func delete(_ recording: SessionRecording) {
        do {
            try SessionRecorder.deleteRecording(recording)
            recordings = SessionRecorder.loadRecordings()
        } catch {
            deletionError = error.localizedDescription
        }
        pendingDeletion = nil
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }
}

private struct MacTerminalPasteReviewSheet: View {
    let request: SwiftTermPasteReview
    let onCancel: () -> Void
    let onPaste: (String) -> Void
    @State private var editedText: String

    init(
        request: SwiftTermPasteReview,
        onCancel: @escaping () -> Void,
        onPaste: @escaping (String) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onPaste = onPaste
        _editedText = State(initialValue: request.content)
    }

    private var canPaste: Bool {
        !request.exceedsMaximumSize && SwiftTermPastePolicy.isAllowed(editedText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Multiline or large pasted content can execute multiple shell commands. Review it before sending.")
                    .foregroundStyle(.secondary)
                LabeledContent(
                    "Original size",
                    value: "\(request.byteCount) bytes, \(request.lineCount) lines"
                )
                if request.exceedsMaximumSize {
                    ContentUnavailableView(
                        "Paste Too Large",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("Nothing was sent to the local shell.")
                    )
                } else {
                    TextEditor(text: $editedText)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Editable terminal paste content")
                    Text("\(editedText.utf8.count) of \(SwiftTermPastePolicy.maximumPayloadBytes) bytes")
                        .font(.caption.monospacedDigit())
                }
            }
            .padding()
            .navigationTitle("Review Terminal Paste")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                if !request.exceedsMaximumSize {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { onPaste(editedText) }
                            .disabled(!canPaste)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .interactiveDismissDisabled()
    }
}
