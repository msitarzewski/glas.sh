//
//  TerminalWindowView.swift
//  glas.sh
//
//  Main terminal window with visionOS glass design and ornaments
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import RealityKitContent

struct TerminalWindowView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager
    @Environment(SettingsManager.self) private var settingsManager
    
    @State private var searchQuery: String = ""
    @State private var terminalSearchFound: Bool?
    @State private var showingSearchOverlay = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showingTerminalSettings = false
    @State private var showingCloseConfirmation = false
    @State private var showVisualBell = false
    @State private var showingSnippetPicker = false
    @State private var showingAIAssistant = false
    @State private var showingErrorCard = false
    @State private var aiAssistant = AIAssistant()
    @State private var terminalSettingsTab: TerminalSettingsModalTab = .terminal
    @StateObject private var terminalHostModel = SwiftTermHostModel()
    @State private var errorCheckTask: Task<Void, Never>?
    @State private var terminalAudioManager = TerminalAudioManager()
    @State private var notificationManager = NotificationManager()
    @State private var isImmersiveFocusActive = false
    @State private var showingRecordings = false
    @State private var recordings: [SessionRecording] = []
    @State private var recordingPendingDeletion: SessionRecording?
    @State private var recordingDeletionError: String?
    @State private var showingRecordingConsent = false
    @State private var terminalColumns = 120
    @State private var terminalRows = 40
    @State private var previousSessionState: SessionState?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        terminalFocusTracking
            .sheet(isPresented: $showingRecordings) {
                recordingsListSheet
            }
            .confirmationDialog(
                "Start Session Recording",
                isPresented: $showingRecordingConsent,
                titleVisibility: .visible
            ) {
                Button("Record Output Only") {
                    startRecording(capturesInput: false)
                }
                Button("Record Output and Keyboard Input", role: .destructive) {
                    startRecording(capturesInput: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Output-only is the safest default. Keyboard input may include passwords, tokens, and other secrets because remote password prompts cannot be detected reliably. This choice applies only to this recording.")
            }
    }

    private var terminalLifecycle: some View {
        terminalPresentation
            .onAppear {
                handleTerminalAppear()
            }
            .onChange(of: settingsManager.hostKeyVerificationMode) { _, _ in
                rejectPendingHostKeyChallengeInStrictMode()
            }
            .onChange(of: session.pendingHostKeyChallenge?.fingerprintSHA256) { _, _ in
                rejectPendingHostKeyChallengeInStrictMode()
                updateTerminalFocusOwnership(
                    competingControlPresented: session.pendingHostKeyChallenge != nil
                )
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && terminalCanOwnFocus {
                    terminalHostModel.focus()
                }
            }
            .onChange(of: session.closeWindowNonce) { _, _ in
                sessionManager.closeSession(session)
                dismiss()
            }
            .onDisappear {
                handleTerminalDisappear()
            }
            .onChange(of: showingSearchOverlay) { oldValue, showing in
                handleSearchPresentationChange(oldValue, showing)
            }
    }

    private var terminalFocusTracking: some View {
        terminalLifecycle
            .onChange(of: showingTerminalSettings) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: showingSnippetPicker) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: showingAIAssistant) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: showingRecordings) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: showingRecordingConsent) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: terminalHostModel.pendingPasteReview?.id) { _, requestID in
                updateTerminalFocusOwnership(competingControlPresented: requestID != nil)
            }
            .onChange(of: terminalHostModel.pendingExternalLink?.id) { _, requestID in
                updateTerminalFocusOwnership(competingControlPresented: requestID != nil)
            }
            .onChange(of: showingCloseConfirmation) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: showingErrorCard) { _, showing in
                updateTerminalFocusOwnership(competingControlPresented: showing)
            }
            .onChange(of: session.state) { oldState, newState in
                handleSessionStateNotification(from: oldState, to: newState)
            }
    }

    private var terminalSurface: some View {
        VStack(spacing: 0) {
            terminalContent
                .padding(10)
        }
        .modifier(GlassWindowBackground(
            interactive: effectiveInteractiveGlass,
            material: resolvedMaterial,
            blurAmount: effectiveBlurBackground
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .ornament(attachmentAnchor: .scene(.top)) {
            connectionLabel
                .glassBackgroundEffect(in: .capsule)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            bottomStatusBar
                .glassBackgroundEffect(in: .capsule)
        }
    }

    private var terminalPresentation: some View {
        terminalSurface
        .sheet(isPresented: $showingTerminalSettings) {
            terminalSettingsModal
        }
        .sheet(isPresented: $showingSnippetPicker) {
            snippetPicker
        }
        .sheet(isPresented: $showingAIAssistant) {
            AIAssistantView(
                aiAssistant: aiAssistant,
                host: session.server.host,
                username: session.server.username,
                currentDirectory: terminalHostModel.currentDirectory,
                onRunCommand: { command in
                    session.sendCommand(command)
                }
            )
        }
        .sheet(item: pendingPasteReviewBinding) { request in
            TerminalPasteReviewSheet(
                request: request,
                onCancel: { terminalHostModel.resolvePendingPaste(approvedText: nil) },
                onPaste: { text in terminalHostModel.resolvePendingPaste(approvedText: text) }
            )
        }
        .alert("Close Connection?", isPresented: $showingCloseConfirmation) {
            Button("Disconnect", role: .destructive) {
                closeTerminalSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have an active SSH connection to \(session.server.name).")
        }
        .alert(
            session.pendingHostKeyChallenge?.reason == .changed ? "SSH Host Key Changed" : "Trust SSH Host Key?",
            isPresented: hostTrustBinding,
            presenting: session.pendingHostKeyChallenge
        ) { challenge in
            Button(
                challenge.reason == .changed ? "Trust Changed Key & Reconnect" : "Trust & Reconnect",
                role: challenge.reason == .changed ? .destructive : nil
            ) {
                guard interactiveHostKeyTrustIsAllowed else {
                    rejectPendingHostKeyChallengeInStrictMode()
                    return
                }
                trustAndReconnect(challenge)
            }
            Button("Cancel", role: .cancel) {
                session.pendingHostKeyChallenge = nil
            }
        } message: { challenge in
            Text("\(challenge.summary)\n\nAlgorithm: \(challenge.algorithm)\nFingerprint (SHA-256): \(challenge.fingerprintSHA256)")
        }
        .alert(
            "Open External Link?",
            isPresented: externalLinkConfirmationBinding,
            presenting: terminalHostModel.pendingExternalLink
        ) { request in
            Button("Open") {
                #if canImport(UIKit)
                if let url = terminalHostModel.resolvePendingExternalLink(approved: true) {
                    UIApplication.shared.open(url)
                }
                #else
                _ = terminalHostModel.resolvePendingExternalLink(approved: false)
                #endif
            }
            Button("Cancel", role: .cancel) {
                _ = terminalHostModel.resolvePendingExternalLink(approved: false)
            }
        } message: { request in
            let authority = request.port.map { "\(request.normalizedHost):\($0)" }
                ?? request.normalizedHost
            Text("A remote terminal link wants to open this address.\n\nHost: \(authority)\n\nExact URL:\n\(request.exactURL)")
        }
    }

    private func handleTerminalAppear() {
        rejectPendingHostKeyChallengeInStrictMode()
        updateTerminalFocusOwnership(
            competingControlPresented: session.pendingHostKeyChallenge != nil || showingErrorCard
        )
    }

    private func handleTerminalDisappear() {
        terminalHostModel.stopFocusMaintenance()
        sessionManager.closeSession(session)
        if isImmersiveFocusActive {
            Task { await dismissImmersiveSpace() }
            isImmersiveFocusActive = false
        }
    }

    private func handleSearchPresentationChange(_ oldValue: Bool, _ showing: Bool) {
        if showing {
            updateTerminalFocusOwnership(competingControlPresented: true)
            isSearchFieldFocused = true
        } else {
            terminalHostModel.clearSearch()
            terminalSearchFound = nil
            updateTerminalFocusOwnership(competingControlPresented: false)
        }
    }
    
    // MARK: - Connection Label (top ornament)

    private var connectionLabel: some View {
        HStack(spacing: 8) {
            if session.state == .reconnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting... (\(session.reconnectAttemptCount)/5)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
                Button {
                    session.cancelReconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel reconnect")
            } else {
                recordingIndicator

                Text(session.server.name)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("\(session.server.username)@\(session.server.host):\(session.server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.state == .reconnecting
            ? "Reconnecting, attempt \(session.reconnectAttemptCount) of 5"
            : "\(session.server.name), \(session.server.username) at \(session.server.host) port \(session.server.port)")
    }

    // MARK: - Terminal Content

    private var terminalContent: some View {
        ZStack {
            terminalDisplayBackground
            if let tintColor = tintColor {
                Rectangle()
                    .fill(tintColor.opacity(0.12 * effectiveWindowOpacity))
                    .allowsHitTesting(false)
            }
            SwiftTermHostView(
                model: terminalHostModel,
                theme: swiftTermTheme,
                runtimeSettings: SwiftTermRuntimeSettings(
                    cursorStyle: settingsManager.cursorStyle,
                    blinkingCursor: settingsManager.blinkingCursor,
                    scrollbackLines: settingsManager.saveScrollback
                        ? settingsManager.maxScrollbackLines
                        : 0
                ),
                onSendData: { data in
                    session.sendTerminalData(data)
                },
                onResize: { cols, rows in
                    terminalColumns = max(20, cols)
                    terminalRows = max(8, rows)
                    session.updateTerminalGeometry(rows: rows, columns: cols)
                },
                onBell: {
                    guard settingsManager.bellEnabled else { return }
                    terminalAudioManager.playBell()
                    if settingsManager.visualBell {
                        withAnimation(.easeInOut(duration: 0.1)) { showVisualBell = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.1)) { showVisualBell = false }
                        }
                    }
                }
            )
            .background(Color.clear)
            .overlay(Color.white.opacity(showVisualBell ? 0.3 : 0).allowsHitTesting(false))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(.rect)
        .onTapGesture {
            if terminalCanOwnFocus {
                terminalHostModel.focus()
            }
        }
        .onAppear {
            if terminalCanOwnFocus {
                terminalHostModel.focus()
            } else {
                terminalHostModel.stopFocusMaintenance()
            }
            if session.terminalInputNonce > 0 {
                let chunks = session.drainTerminalInputChunks()
                if !chunks.isEmpty {
                    let data = chunks.reduce(into: Data()) { $0.append($1) }
                    terminalHostModel.ingest(data: data, nonce: session.terminalInputNonce)
                }
            }
        }
        .onChange(of: session.terminalInputNonce) { _, nonce in
            let chunks = session.drainTerminalInputChunks()
            if !chunks.isEmpty {
                let data = chunks.reduce(into: Data()) { $0.append($1) }
                terminalHostModel.ingest(data: data, nonce: nonce)
            }

            // Debounced error detection for AI explainer
            if aiAssistant.isAvailable {
                errorCheckTask?.cancel()
                errorCheckTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    let lines = terminalHostModel.getVisibleText(lastNLines: 10)
                    if detectErrorInTerminalOutput(lines) {
                        await aiAssistant.explainError(
                            terminalContext: lines,
                            host: session.server.host,
                            username: session.server.username
                        )
                        if aiAssistant.lastError != nil {
                            withAnimation { showingErrorCard = true }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showingSearchOverlay {
                terminalSearchOverlay
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showingErrorCard, let errorInfo = aiAssistant.lastError {
                AIErrorCard(
                    error: errorInfo,
                    onRunFix: { fix in
                        session.sendCommand(fix)
                    },
                    onDismiss: {
                        withAnimation { showingErrorCard = false }
                    }
                )
                .padding(.bottom, 14)
                .padding(.horizontal, 14)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 6) {
                ForEach(notificationManager.active) { notification in
                    NotificationBanner(notification: notification) {
                        notificationManager.dismiss(notification.id)
                    }
                }
            }
            .padding(14)
            .animation(.spring(), value: notificationManager.active.count)
        }
        .onAppear {
            aiAssistant.checkAvailability()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var swiftTermTheme: SwiftTermTheme {
        let theme = settingsManager.currentTheme
        let fg = rgbaComponents(theme.foreground.color)
        let bg = rgbaComponents(theme.background.color)
        let cursor = rgbaComponents(theme.cursor.color)
        let selection = rgbaComponents(theme.selection.color)
        let ansiColors = [
            theme.black, theme.red, theme.green, theme.yellow,
            theme.blue, theme.magenta, theme.cyan, theme.white,
            theme.brightBlack, theme.brightRed, theme.brightGreen, theme.brightYellow,
            theme.brightBlue, theme.brightMagenta, theme.brightCyan, theme.brightWhite,
        ].map { color in
            let components = rgbaComponents(color.color)
            return SwiftTermThemeColor(
                red: components.red,
                green: components.green,
                blue: components.blue
            )
        }

        return SwiftTermTheme(
            fontSize: max(10, theme.fontSize),
            foreground: (fg.red, fg.green, fg.blue),
            background: (bg.red, bg.green, bg.blue, 0),
            cursor: (cursor.red, cursor.green, cursor.blue),
            fontName: theme.fontName,
            selection: (selection.red, selection.green, selection.blue, selection.alpha),
            ansiColors: ansiColors
        )
    }

    private var terminalCanOwnFocus: Bool {
        !showingSearchOverlay
            && !showingTerminalSettings
            && !showingCloseConfirmation
            && !showingSnippetPicker
            && !showingAIAssistant
            && !showingRecordings
            && !showingRecordingConsent
            && session.pendingHostKeyChallenge == nil
            && !showingErrorCard
            && terminalHostModel.pendingPasteReview == nil
            && terminalHostModel.pendingExternalLink == nil
    }

    private var pendingPasteReviewBinding: Binding<SwiftTermPasteReview?> {
        Binding(
            get: { terminalHostModel.pendingPasteReview },
            set: { value in
                if value == nil {
                    terminalHostModel.resolvePendingPaste(approvedText: nil)
                }
            }
        )
    }

    private var externalLinkConfirmationBinding: Binding<Bool> {
        Binding(
            get: { terminalHostModel.pendingExternalLink != nil },
            set: { isPresented in
                if !isPresented {
                    _ = terminalHostModel.resolvePendingExternalLink(approved: false)
                }
            }
        )
    }

    private func updateTerminalFocusOwnership(competingControlPresented: Bool) {
        terminalHostModel.setFocusOwnershipAllowed(
            !competingControlPresented && terminalCanOwnFocus
        )
    }

    @ViewBuilder
    private var recordingIndicator: some View {
        if let recorder = session.recorder, recorder.isRecording {
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

    private func startRecording(capturesInput: Bool) {
        if session.recorder == nil {
            session.recorder = SessionRecorder()
        }
        session.recorder?.start(
            sessionID: session.id,
            serverName: session.server.name,
            host: session.server.host,
            width: terminalColumns,
            height: terminalRows,
            capturesInput: capturesInput
        )

        guard session.recorder?.isRecording == true else {
            notificationManager.post(
                icon: "exclamationmark.triangle.fill",
                title: "Recording failed",
                message: session.recorder?.lastError,
                style: .error
            )
            return
        }
        notificationManager.post(
            icon: capturesInput ? "keyboard.fill" : "record.circle",
            title: capturesInput ? "Recording input and output" : "Recording output only",
            message: capturesInput ? "Keyboard input may contain secrets." : nil,
            style: capturesInput ? .warning : .info
        )
    }

    private func rgbaComponents(_ color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return (Double(red), Double(green), Double(blue), Double(alpha))
        }
        #endif
        return (1, 1, 1, 1)
    }

    @ViewBuilder
    private var terminalDisplayBackground: some View {
        // Opacity is deliberately separate from the window's blur layer.
        // Zero leaves the terminal canvas completely unpainted.
        let bg = rgbaComponents(settingsManager.currentTheme.background.color)

        Rectangle()
            .fill(Color(red: bg.red, green: bg.green, blue: bg.blue))
            .opacity(effectiveWindowOpacity)
    }

    private var tintColor: Color? {
        let tint = effectiveGlassTint
        if tint == "None" || tint.isEmpty { return nil }
        // Legacy named colors
        switch tint {
        case "Blue": return .blue
        case "Purple": return .purple
        case "Green": return .green
        default: break
        }
        // Hex color
        return Color(hex: tint)
    }

    private var effectiveGlassFrost: String {
        settingsManager.sessionOverride(for: session.id)?.glassFrost ?? settingsManager.glassFrost
    }

    private var effectiveGlassAppearance: TerminalGlassAppearance {
        TerminalGlassAppearance.resolved(
            globalOpacity: settingsManager.windowOpacity,
            globalBlur: settingsManager.blurBackground,
            sessionOverride: settingsManager.sessionOverride(for: session.id)
        )
    }

    private var effectiveWindowOpacity: Double {
        effectiveGlassAppearance.opacity
    }

    private var effectiveBlurBackground: Double {
        effectiveGlassAppearance.blur
    }

    private var effectiveInteractiveGlass: Bool {
        settingsManager.sessionOverride(for: session.id)?.interactiveGlass ?? settingsManager.interactiveGlass
    }

    private var effectiveGlassTint: String {
        settingsManager.sessionOverride(for: session.id)?.glassTint ?? settingsManager.glassTint
    }

    private var resolvedMaterial: Material {
        switch effectiveGlassFrost {
        case "thin": return .thinMaterial
        case "regular": return .regularMaterial
        case "thick": return .thickMaterial
        default: return .ultraThinMaterial
        }
    }

    private func duplicateSession() {
        Task {
            do {
                let launch = try await sessionManager.duplicateAuthorizedSession(
                    from: session,
                    settingsManager: settingsManager
                )
                if launch.session.state == .connected {
                    openWindow(id: "terminal", value: launch.session.id)
                } else if let challenge = launch.session.pendingHostKeyChallenge {
                    if interactiveHostKeyTrustIsAllowed {
                        // The new window owns the exact trust prompt and reconnect
                        // lifecycle for its per-connection challenge.
                        openWindow(id: "terminal", value: launch.session.id)
                    } else {
                        notificationManager.post(
                            icon: "lock.shield",
                            title: "Duplicate Blocked",
                            message: strictHostKeyFailureMessage(for: challenge),
                            style: .error
                        )
                        launch.session.pendingHostKeyChallenge = nil
                        sessionManager.closeSession(launch.session)
                    }
                } else if case .error(let message) = launch.session.state {
                    notificationManager.post(
                        icon: "exclamationmark.triangle",
                        title: "Duplicate Failed",
                        message: message,
                        style: .error
                    )
                    sessionManager.closeSession(launch.session)
                }
            } catch {
                notificationManager.post(
                    icon: "exclamationmark.triangle",
                    title: "Duplicate Failed",
                    message: error.localizedDescription,
                    style: .error
                )
            }
        }
    }

    private var hostTrustBinding: Binding<Bool> {
        Binding(
            get: { interactiveHostKeyTrustIsAllowed && session.pendingHostKeyChallenge != nil },
            set: { isPresented in
                if !isPresented {
                    if interactiveHostKeyTrustIsAllowed {
                        session.pendingHostKeyChallenge = nil
                    } else {
                        rejectPendingHostKeyChallengeInStrictMode()
                    }
                }
            }
        )
    }

    private var interactiveHostKeyTrustIsAllowed: Bool {
        settingsManager.hostKeyVerificationMode == HostKeyVerificationMode.ask.rawValue
    }

    private func strictHostKeyFailureMessage(for challenge: HostKeyTrustChallenge) -> String {
        let reason = challenge.reason == .changed
            ? "the presented key does not match the saved key"
            : "the presented key has not been saved"
        return "Strict host-key verification blocked the connection to \(challenge.host):\(challenge.port) because \(reason). No trust decision was recorded."
    }

    private func rejectPendingHostKeyChallengeInStrictMode() {
        guard !interactiveHostKeyTrustIsAllowed,
              let challenge = session.pendingHostKeyChallenge else { return }
        session.pendingHostKeyChallenge = nil
        notificationManager.post(
            icon: "lock.shield",
            title: "Host Key Rejected",
            message: strictHostKeyFailureMessage(for: challenge),
            style: .error
        )
    }

    private func trustAndReconnect(_ challenge: HostKeyTrustChallenge) {
        guard interactiveHostKeyTrustIsAllowed else {
            rejectPendingHostKeyChallengeInStrictMode()
            return
        }
        do {
            try sessionManager.trustHostKey(challenge, for: session)
            session.pendingHostKeyChallenge = nil
            reconnectSession()
        } catch {
            notificationManager.post(
                icon: "exclamationmark.triangle",
                title: "Trust Failed",
                message: error.localizedDescription,
                style: .error
            )
        }
    }

    private func closeTerminalSession() {
        sessionManager.closeSession(session)
        dismiss()
    }

    private func reconnectSession() {
        session.cancelReconnect()
        Task {
            do {
                try await sessionManager.reconnect(session, settingsManager: settingsManager)
            } catch {
                notificationManager.post(
                    icon: "exclamationmark.triangle",
                    title: "Reconnect Failed",
                    message: error.localizedDescription,
                    style: .error
                )
            }
        }
    }

    private func openTerminalSettings() {
        terminalSettingsTab = .terminal
        showingTerminalSettings = true
    }

    // MARK: - Bottom Status

    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 8, height: 8)
                Text(session.state.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection status: \(session.state.displayName)")

            Button {
                openWindow(id: "main")
            } label: {
                Image(systemName: "server.rack")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Connections")
            .help("Connections")

            if aiAssistant.isAvailable {
                Button {
                    showingAIAssistant = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("AI Assistant")
                .help("AI Assistant")
            }

            Button {
                let context = SFTPBrowserContext(sessionID: session.id)
                openWindow(id: "sftp", value: context)
            } label: {
                Image(systemName: "folder.fill")
            }
            .buttonStyle(.borderless)
            .disabled(session.state != .connected)
            .accessibilityLabel("SFTP Browser")
            .help("SFTP Browser")

            Button {
                Task {
                    if isImmersiveFocusActive {
                        await dismissImmersiveSpace()
                        isImmersiveFocusActive = false
                    } else {
                        let result = await openImmersiveSpace(id: "focus-environment")
                        isImmersiveFocusActive = (result == .opened)
                    }
                }
            } label: {
                Image(systemName: isImmersiveFocusActive ? "moon.fill" : "moon")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isImmersiveFocusActive ? "Exit Focus Mode" : "Focus Mode")
            .help(isImmersiveFocusActive ? "Exit Focus Mode" : "Focus Mode")

            recordingIndicator

            Menu {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSearchOverlay.toggle()
                    }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }

                Button {
                    session.clearScreen()
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                #if DEBUG
                Button {
                    let context = HTMLPreviewContext(
                        sessionID: session.id,
                        url: "http://localhost:8080"
                    )
                    openWindow(id: "html-preview", value: context)
                } label: {
                    Label("HTML Preview", systemImage: "safari")
                }
                #endif

                Button {
                    showingSnippetPicker = true
                } label: {
                    Label("Snippets", systemImage: "text.page")
                }
                .disabled(session.state != .connected || settingsManager.snippets.isEmpty)

                Divider()

                if session.recorder?.isRecording == true {
                    Button {
                        let recording = session.recorder?.stop()
                        if recording?.isComplete == true {
                            notificationManager.post(icon: "stop.circle", title: "Recording saved", style: .info)
                        } else {
                            notificationManager.post(
                                icon: "exclamationmark.triangle.fill",
                                title: "Recording was not saved",
                                message: session.recorder?.lastError,
                                style: .error
                            )
                        }
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        showingRecordingConsent = true
                    } label: {
                        Label("Start Recording…", systemImage: "record.circle")
                    }
                    .disabled(session.state != .connected)
                }

                Button {
                    showingRecordings = true
                } label: {
                    Label("Recordings", systemImage: "list.bullet.rectangle")
                }

                Divider()

                Button {
                    duplicateSession()
                } label: {
                    Label("Duplicate Session", systemImage: "doc.on.doc")
                }

                Button {
                    reconnectSession()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(session.state == .connecting || session.state == .reconnecting)

                if session.state == .reconnecting {
                    Button(role: .destructive) {
                        session.cancelReconnect()
                    } label: {
                        Label("Cancel Reconnect", systemImage: "stop.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        if settingsManager.confirmBeforeClosing && session.state == .connected {
                            showingCloseConfirmation = true
                        } else {
                            closeTerminalSession()
                        }
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(session.state == .disconnected)
                }

                Divider()

                Button {
                    openTerminalSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .help("Tools")
            .accessibilityLabel("Tools menu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var terminalSearchOverlay: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search terminal output", text: $searchQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    terminalSearchFound = terminalHostModel.findNext(searchQuery)
                }
                .onChange(of: searchQuery) { _, _ in
                    terminalHostModel.clearSearch()
                    terminalSearchFound = nil
                }
                .accessibilityLabel("Search terminal output")

            if terminalSearchFound == false {
                Text("No match")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                terminalSearchFound = terminalHostModel.findPrevious(searchQuery)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(searchQuery.isEmpty)
            .accessibilityLabel("Previous match")

            Button {
                terminalSearchFound = terminalHostModel.findNext(searchQuery)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(searchQuery.isEmpty)
            .accessibilityLabel("Next match")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSearchOverlay = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 280, maxWidth: 420)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private var snippetPicker: some View {
        NavigationStack {
            List(settingsManager.snippets) { snippet in
                Button {
                    session.sendCommand(snippet.command)
                    settingsManager.useSnippet(snippet.id)
                    showingSnippetPicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.name).font(.headline)
                        Text(snippet.command)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if !snippet.description.isEmpty {
                            Text(snippet.description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSnippetPicker = false }
                }
            }
        }
    }

    private var terminalSettingsModal: some View {
        NavigationStack {
            Group {
                switch terminalSettingsTab {
                case .terminal:
                    TerminalSettingsView()
                        .environment(settingsManager)
                case .overrides:
                    TerminalOverridesSettingsView(session: session)
                        .environment(settingsManager)
                case .portForwarding:
                    TerminalPortForwardingSettingsView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Terminal Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingTerminalSettings = false
                    }
                }

                ToolbarItem(placement: .principal) {
                    Picker("Settings Tab", selection: $terminalSettingsTab) {
                        Text("Terminal").tag(TerminalSettingsModalTab.terminal)
                        Text("Overrides").tag(TerminalSettingsModalTab.overrides)
                        Text("Port Forwarding").tag(TerminalSettingsModalTab.portForwarding)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
            }
        }
        .frame(width: 760, height: 560)
    }
}

private struct TerminalPasteReviewSheet: View {
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

    private var editedByteCount: Int { editedText.utf8.count }
    private var canPaste: Bool {
        !request.exceedsMaximumSize && SwiftTermPastePolicy.isAllowed(editedText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(request.bracketedPasteMode
                    ? "The remote program requested bracketed paste. Review the content before it is sent."
                    : "Multiline or large pasted content can execute multiple shell commands. Review it before sending.")
                    .foregroundStyle(.secondary)

                LabeledContent("Original size", value: "\(request.byteCount) bytes, \(request.lineCount) lines")

                if request.exceedsMaximumSize {
                    ContentUnavailableView(
                        "Paste Too Large",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("The clipboard exceeds the \(SwiftTermPastePolicy.maximumPayloadBytes)-byte terminal paste limit. Nothing was sent.")
                    )
                } else {
                    TextEditor(text: $editedText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Editable terminal paste content")
                    Text("\(editedByteCount) of \(SwiftTermPastePolicy.maximumPayloadBytes) bytes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(editedByteCount > SwiftTermPastePolicy.maximumPayloadBytes ? .red : .secondary)
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


private enum TerminalSettingsModalTab: Hashable {
    case terminal
    case overrides
    case portForwarding
}

struct TerminalOverridesSettingsView: View {
    @Bindable var session: TerminalSession
    @Environment(SettingsManager.self) private var settingsManager

    private var sessionOverride: TerminalSessionOverride {
        settingsManager.sessionOverride(for: session.id) ?? TerminalSessionOverride()
    }

    var body: some View {
        @Bindable var settings = settingsManager

        Form {
            Section("Session") {
                LabeledContent("Name", value: session.server.name)
                LabeledContent("Host", value: "\(session.server.username)@\(session.server.host)")
                LabeledContent("Status", value: session.state.displayName)
            }

            Section("Glass (this session)") {
                Picker("Frost", selection: Binding(
                    get: { sessionOverride.glassFrost ?? settings.glassFrost },
                    set: { newValue in
                        settings.updateSessionOverride(for: session.id) { override in
                            override.glassFrost = newValue
                        }
                    }
                )) {
                    Text("Light").tag("ultraThin")
                    Text("Medium").tag("thin")
                    Text("Heavy").tag("regular")
                    Text("Max").tag("thick")
                }

                Slider(
                    value: Binding(
                        get: { sessionOverride.windowOpacity ?? settings.windowOpacity },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.windowOpacity = newValue
                            }
                        }
                    ),
                    in: 0.0...1.0
                ) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Text("Transparent")
                } maximumValueLabel: {
                    Text("Opaque")
                }

                Slider(
                    value: Binding(
                        get: { sessionOverride.blurBackground ?? settings.blurBackground },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.blurBackground = newValue
                            }
                        }
                    ),
                    in: 0.0...1.0
                ) {
                    Text("Blur")
                } minimumValueLabel: {
                    Text("None")
                } maximumValueLabel: {
                    Text("Maximum")
                }

                Toggle(
                    "Interactive glass",
                    isOn: Binding(
                        get: { sessionOverride.interactiveGlass ?? settings.interactiveGlass },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.interactiveGlass = newValue
                            }
                        }
                    )
                )

                Text("Opacity and blur remain independent. Set both to zero for a completely transparent terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GlassTintPicker(
                    value: Binding(
                        get: { sessionOverride.glassTint ?? settings.glassTint },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.glassTint = newValue
                            }
                        }
                    )
                )

                Button("Reset Overrides", role: .destructive) {
                    settings.updateSessionOverride(for: session.id) { override in
                        override.glassFrost = nil
                        override.windowOpacity = nil
                        override.blurBackground = nil
                        override.interactiveGlass = nil
                        override.glassTint = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TerminalPortForwardingSettingsView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Bindable var session: TerminalSession
    @State private var showingAddForward = false

    private var portForwards: [PortForward] {
        sessionManager.portForwardManager.forwards(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Port Forwards")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddForward = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if portForwards.isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.forward.square")
                } description: {
                    Text("Add a local, remote, or dynamic forward for this session.")
                }
            } else {
                List {
                    ForEach(portForwards) { forward in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(forward.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(forward.displayString)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let errorMessage = forward.errorMessage {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }

                            Spacer()

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { forward.isActive },
                                    set: { newValue in
                                        setForwardActive(forward.id, isActive: newValue)
                                    }
                                )
                            )
                            .labelsHidden()
                            .disabled(forward.status == .starting || forward.status == .stopping)

                            Button(role: .destructive) {
                                removeForward(forward.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showingAddForward) {
            AddSessionPortForwardView { forward, socks5Username, socks5Password in
                if forward.type == .dynamic,
                   let socks5Username,
                   let socks5Password {
                    sessionManager.portForwardManager.addForward(
                        forward,
                        to: session.id,
                        socks5Username: socks5Username,
                        socks5Password: socks5Password
                    )
                } else {
                    sessionManager.portForwardManager.addForward(forward, to: session.id)
                }
            }
        }
    }

    private func setForwardActive(_ id: UUID, isActive: Bool) {
        guard let forward = portForwards.first(where: { $0.id == id }),
              forward.isActive != isActive else {
            return
        }
        sessionManager.portForwardManager.toggleForward(
            forward,
            in: session.id,
            session: session
        )
    }

    private func removeForward(_ id: UUID) {
        guard let forward = portForwards.first(where: { $0.id == id }) else { return }
        sessionManager.portForwardManager.removeForward(forward, from: session.id)
    }
}

struct AddSessionPortForwardView: View {
    let onAdd: (PortForward, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var forwardType: PortForward.ForwardType = .local
    @State private var localPort = ""
    @State private var remoteHost = "localhost"
    @State private var remotePort = ""
    @State private var socks5Username = ""
    @State private var socks5Password = ""
    @FocusState private var isLocalPortFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Forward Type") {
                    Picker("Type", selection: $forwardType) {
                        Text("Local").tag(PortForward.ForwardType.local)
                        Text("Remote").tag(PortForward.ForwardType.remote)
                        Text("Dynamic (SOCKS)").tag(PortForward.ForwardType.dynamic)
                    }
                }

                Section("Configuration") {
                    TextField("Local Port", text: $localPort)
                        .keyboardType(.numberPad)
                        .focused($isLocalPortFocused)

                    if forwardType != .dynamic {
                        TextField("Remote Host", text: $remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Remote Port", text: $remotePort)
                            .keyboardType(.numberPad)
                    }
                }

                if forwardType == .dynamic {
                    Section("SOCKS5 Authentication") {
                        TextField("Username", text: $socks5Username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $socks5Password)

                        Text("Required for every local SOCKS5 client. These credentials remain only in app memory for this session and are never saved with the forward.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if forwardType == .remote {
                    Section("Remote Bind Safety") {
                        Text("Remote listeners are limited to localhost, 127.0.0.1, or ::1 so the tunnel cannot expose a local service to the server's network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Port Forward")
            .onAppear { isLocalPortFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let local = Int(localPort) else { return }
                        let remote = Int(remotePort) ?? 0
                        let forward = PortForward(
                            type: forwardType,
                            localPort: local,
                            remoteHost: forwardType == .dynamic ? "localhost" : remoteHost,
                            remotePort: forwardType == .dynamic ? 0 : remote
                        )
                        onAdd(
                            forward,
                            forwardType == .dynamic ? socks5Username : nil,
                            forwardType == .dynamic ? socks5Password : nil
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let local = Int(localPort), local > 0 && local <= 65535 else { return false }
        if forwardType == .dynamic {
            return PortForwardManager.socks5Credentials(
                username: socks5Username,
                password: socks5Password
            ) != nil
        }
        guard !remoteHost.isEmpty else { return false }
        guard let remote = Int(remotePort), remote > 0 && remote <= 65535 else { return false }
        if forwardType == .remote {
            let normalizedHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["localhost", "127.0.0.1", "::1"].contains(normalizedHost) else { return false }
        }
        return true
    }
}

// MARK: - Session State Notifications

extension TerminalWindowView {
    func handleSessionStateNotification(from oldState: SessionState, to newState: SessionState) {
        switch newState {
        case .connected where oldState == .reconnecting:
            notificationManager.post(icon: "checkmark.circle.fill", title: "Reconnected", style: .success)
        case .error(let message):
            notificationManager.post(icon: "exclamationmark.triangle.fill", title: "Connection Error", message: message, style: .error)
        case .disconnected where oldState == .connected:
            notificationManager.post(icon: "xmark.circle", title: "Disconnected", style: .warning)
        default:
            break
        }
    }

    var recordingsListSheet: some View {
        NavigationStack {
            List {
                if recordings.isEmpty {
                    ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Session recordings will appear here."))
                } else {
                    ForEach(recordings) { recording in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(recording.serverName)
                                    .font(.headline)
                                if !recording.isComplete {
                                    Label("Interrupted", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.15), in: Capsule())
                                        .accessibilityLabel("Interrupted recording")
                                }
                                Spacer()
                                Text("\(recording.eventCount) events")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Text(recording.host)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(recording.startTime, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if let endTime = recording.endTime {
                                let duration = endTime.timeIntervalSince(recording.startTime)
                                Text("Duration: \(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                recordingPendingDeletion = recording
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .onAppear {
                recordings = SessionRecorder.loadRecordings()
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingRecordings = false }
                }
            }
        }
        .alert(
            "Delete Recording?",
            isPresented: recordingDeletionBinding,
            presenting: recordingPendingDeletion
        ) { recording in
            Button("Delete", role: .destructive) {
                do {
                    try SessionRecorder.deleteRecording(recording)
                    recordings = SessionRecorder.loadRecordings()
                } catch {
                    recordingDeletionError = error.localizedDescription
                }
                recordingPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                recordingPendingDeletion = nil
            }
        } message: { recording in
            Text("Permanently delete the recording of \(recording.serverName)? This cannot be undone.")
        }
        .alert(
            "Recording Deletion Failed",
            isPresented: Binding(
                get: { recordingDeletionError != nil },
                set: { if !$0 { recordingDeletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { recordingDeletionError = nil }
        } message: {
            Text(recordingDeletionError ?? "The recording could not be deleted.")
        }
        .frame(width: 520, height: 440)
    }

    private var recordingDeletionBinding: Binding<Bool> {
        Binding(
            get: { recordingPendingDeletion != nil },
            set: { if !$0 { recordingPendingDeletion = nil } }
        )
    }
}

// MARK: - Glass Window Background

/// Composites blur independently behind the terminal's theme-color opacity.
/// A zero blur amount emits no backing at all, preserving true transparency.
private struct GlassWindowBackground: ViewModifier {
    let interactive: Bool
    let material: Material
    let blurAmount: Double

    func body(content: Content) -> some View {
        content.background {
            if blurAmount > 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(material)

                    if interactive {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.clear)
                            .glassBackgroundEffect(in: .rect(cornerRadius: 24))
                    }
                }
                .opacity(blurAmount)
            }
        }
    }
}

// MARK: - Glass Tint Picker

struct GlassTintPicker: View {
    @Binding var value: String

    private static let presets: [(String, Color)] = [
        ("None", .clear),
        ("#007AFF", .blue),
        ("#AF52DE", .purple),
        ("#34C759", .green),
        ("#FF9500", .orange),
        ("#FF2D55", .pink),
        ("#5AC8FA", .cyan),
        ("#FFD60A", .yellow),
    ]

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                if value == "None" || value.isEmpty { return .blue }
                return Color(hex: value) ?? .blue
            },
            set: { newColor in
                value = newColor.hexString
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Glass Tint")
                Spacer()
                if value != "None" && !value.isEmpty {
                    Button("Clear") { value = "None" }
                        .font(.caption)
                }
            }

            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.0) { hex, color in
                    Button {
                        value = hex
                    } label: {
                        if hex == "None" {
                            Circle()
                                .strokeBorder(.secondary, lineWidth: 1.5)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                        } else {
                            Circle()
                                .fill(color)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if value == hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex == "None" ? "No tint" : hex)
                }

                Divider().frame(height: 24)

                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Custom tint color")
            }
        }
    }
}

// MARK: - Color Hex Helpers

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let int = UInt64(h, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(r * 255))
        let gi = Int(round(g * 255))
        let bi = Int(round(b * 255))
        return String(format: "#%02X%02X%02X", ri, gi, bi)
        #else
        return "#007AFF"
        #endif
    }
}

#Preview {
    let session = TerminalSession(server: ServerConfiguration(
        name: "Development Server",
        host: "dev.example.com",
        username: "developer"
    ))

    return TerminalWindowView(session: session)
        .environment(SessionManager())
        .environment(SettingsManager())
}
