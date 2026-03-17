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
    @State private var didRunCloseGooseCall = false
    @State private var errorCheckTask: Task<Void, Never>?
    @State private var terminalAudioManager = TerminalAudioManager()
    @State private var notificationManager = NotificationManager()
    @State private var isImmersiveFocusActive = false
    @State private var showingRecordings = false
    @State private var sharePlayManager = SharePlayManager()
    @State private var previousSessionState: SessionState?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 0) {
            terminalContent
                .padding(10)
        }
        .background(resolvedMaterial, in: .rect(cornerRadius: 24))
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
                onRunCommand: { command in
                    session.sendCommand(command)
                }
            )
        }
        .alert("Close Connection?", isPresented: $showingCloseConfirmation) {
            Button("Disconnect", role: .destructive) {
                session.disconnect()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have an active SSH connection to \(session.server.name).")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                terminalHostModel.focus()
            }
        }
        .onChange(of: session.closeWindowNonce) { _, _ in
            runCloseGooseCallIfNeeded()
            dismiss()
        }
        .onDisappear {
            terminalHostModel.stopFocusMaintenance()
            runCloseGooseCallIfNeeded()
            if isImmersiveFocusActive {
                Task { await dismissImmersiveSpace() }
                isImmersiveFocusActive = false
            }
            sharePlayManager.stopSharing()
        }
        .onChange(of: showingSearchOverlay) { _, showing in
            if showing { isSearchFieldFocused = true }
        }
        .onChange(of: session.state) { oldState, newState in
            handleSessionStateNotification(from: oldState, to: newState)
        }
        .sheet(isPresented: $showingRecordings) {
            recordingsListSheet
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
                if session.recorder?.isRecording == true {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Recording")
                }

                Text(session.server.name)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("\(session.server.username)@\(session.server.host):\(session.server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if sharePlayManager.isActive {
                    HStack(spacing: 3) {
                        Image(systemName: "shareplay")
                            .font(.caption2)
                        Text("\(sharePlayManager.participantCount)")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.green)
                }
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
                    .fill(
                        tintColor.opacity(
                            (effectiveInteractiveGlassEffects ? 0.08 : 0.14) * effectiveWindowOpacity
                        )
                    )
                    .allowsHitTesting(false)
            }
            SwiftTermHostView(
                model: terminalHostModel,
                theme: swiftTermTheme,
                onSendData: { data in
                    session.sendTerminalData(data)
                },
                onResize: { cols, rows in
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
            terminalHostModel.focus()
        }
        .onAppear {
            terminalHostModel.focus()
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
        let fg = rgbaComponents(settingsManager.currentTheme.foreground.color)
        let bg = rgbaComponents(settingsManager.currentTheme.background.color)
        let cursor = rgbaComponents(settingsManager.currentTheme.cursor.color)

        return SwiftTermTheme(
            fontSize: max(10, settingsManager.currentTheme.fontSize),
            foreground: (fg.red, fg.green, fg.blue),
            background: (bg.red, bg.green, bg.blue, 0),
            cursor: (cursor.red, cursor.green, cursor.blue)
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
        // The window-level .ultraThinMaterial (line 42) blurs the passthrough.
        // This background just provides the theme color overlay.
        // Lower glassAmount = more solid color. Higher = more see-through to the
        // window's frosted glass blur underneath.
        let bg = rgbaComponents(settingsManager.currentTheme.background.color)
        let glassAmount = effectiveBlurBackground

        Rectangle()
            .fill(Color(red: bg.red, green: bg.green, blue: bg.blue))
            .opacity(effectiveWindowOpacity * (1.0 - glassAmount))
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

    private var effectiveWindowOpacity: Double {
        settingsManager.sessionOverride(for: session.id)?.windowOpacity ?? settingsManager.windowOpacity
    }

    private var effectiveBlurBackground: Double {
        settingsManager.sessionOverride(for: session.id)?.blurBackground ?? settingsManager.blurBackground
    }

    private var effectiveInteractiveGlassEffects: Bool {
        settingsManager.sessionOverride(for: session.id)?.interactiveGlassEffects ?? settingsManager.interactiveGlassEffects
    }

    private var effectiveGlassTint: String {
        settingsManager.sessionOverride(for: session.id)?.glassTint ?? settingsManager.glassTint
    }

    private var effectiveGlassMaterialStyle: String {
        settingsManager.sessionOverride(for: session.id)?.glassMaterialStyle ?? settingsManager.glassMaterialStyle
    }

    private var resolvedMaterial: Material {
        switch effectiveGlassMaterialStyle {
        case "thin": return .thinMaterial
        case "regular": return .regularMaterial
        case "thick": return .thickMaterial
        default: return .ultraThinMaterial
        }
    }

    private func runCloseGooseCallIfNeeded() {
        guard !didRunCloseGooseCall else { return }
        didRunCloseGooseCall = true
    }

    private func duplicateSession() {
        Task {
            let _ = await sessionManager.createSession(for: session.server)
        }
    }

    private func reconnectSession() {
        session.cancelReconnect()
        Task {
            session.disconnect()
            try? await Task.sleep(for: .seconds(1))
            await session.connect()
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

            Button {
                Task {
                    if sharePlayManager.isActive {
                        sharePlayManager.stopSharing()
                    } else {
                        await sharePlayManager.startSharing(
                            serverName: session.server.name,
                            sessionID: session.id
                        )
                    }
                }
            } label: {
                Image(systemName: "shareplay")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(sharePlayManager.isActive ? .green : .primary)
            .disabled(session.state != .connected)
            .accessibilityLabel(sharePlayManager.isActive ? "Stop Sharing" : "Share Terminal")
            .help(sharePlayManager.isActive ? "Stop Sharing" : "Share Terminal")

            if session.recorder?.isRecording == true {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("Recording in progress")
            }

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

                Button {
                    let context = HTMLPreviewContext(
                        sessionID: session.id,
                        url: "http://localhost:8080"
                    )
                    openWindow(id: "html-preview", value: context)
                } label: {
                    Label("HTML Preview", systemImage: "safari")
                }

                Button {
                    showingSnippetPicker = true
                } label: {
                    Label("Snippets", systemImage: "text.page")
                }
                .disabled(session.state != .connected || settingsManager.snippets.isEmpty)

                Divider()

                if session.recorder?.isRecording == true {
                    Button {
                        let _ = session.recorder?.stop()
                        notificationManager.post(icon: "stop.circle", title: "Recording saved", style: .info)
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        if session.recorder == nil {
                            session.recorder = SessionRecorder()
                        }
                        session.recorder?.start(
                            sessionID: session.id,
                            serverName: session.server.name,
                            host: session.server.host,
                            width: 140, height: 40
                        )
                        notificationManager.post(icon: "record.circle", title: "Recording started", style: .info)
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
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
                            session.disconnect()
                            dismiss()
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
                .accessibilityLabel("Search terminal output")

            if !searchQuery.isEmpty {
                Text("\(session.searchOutput(searchQuery).count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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

            Section("Window Overrides") {
                HStack {
                    Text("Window opacity")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { sessionOverride.windowOpacity ?? settings.windowOpacity },
                            set: { newValue in
                                settings.updateSessionOverride(for: session.id) { override in
                                    override.windowOpacity = newValue
                                }
                            }
                        ),
                        in: 0.5...1.0
                    )
                    .frame(maxWidth: 220)
                    Text("\(Int((sessionOverride.windowOpacity ?? settings.windowOpacity) * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Glass material")
                    Spacer()
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
                    )
                    .frame(maxWidth: 220)
                    Text("\(Int((sessionOverride.blurBackground ?? settings.blurBackground) * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle(
                    "Interactive glass effects",
                    isOn: Binding(
                        get: { sessionOverride.interactiveGlassEffects ?? settings.interactiveGlassEffects },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.interactiveGlassEffects = newValue
                            }
                        }
                    )
                )

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

                Picker("Glass material", selection: Binding(
                    get: { sessionOverride.glassMaterialStyle ?? settings.glassMaterialStyle },
                    set: { newValue in
                        settings.updateSessionOverride(for: session.id) { override in
                            override.glassMaterialStyle = newValue
                        }
                    }
                )) {
                    Text("Ultra Thin").tag("ultraThin")
                    Text("Thin").tag("thin")
                    Text("Regular").tag("regular")
                    Text("Thick").tag("thick")
                }

                Button("Reset Overrides", role: .destructive) {
                    settings.updateSessionOverride(for: session.id) { override in
                        override.windowOpacity = nil
                        override.blurBackground = nil
                        override.interactiveGlassEffects = nil
                        override.glassTint = nil
                        override.glassMaterialStyle = nil
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TerminalPortForwardingSettingsView: View {
    @Bindable var session: TerminalSession
    @State private var showingAddForward = false

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

            if session.portForwards.isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.forward.square")
                } description: {
                    Text("Add a local, remote, or dynamic forward for this session.")
                }
            } else {
                List {
                    ForEach(session.portForwards) { forward in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(forward.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(forward.displayString)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
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
            AddSessionPortForwardView { forward in
                session.portForwards.append(forward)
            }
        }
    }

    private func setForwardActive(_ id: UUID, isActive: Bool) {
        guard let index = session.portForwards.firstIndex(where: { $0.id == id }) else { return }
        session.portForwards[index].status = isActive ? .active : .inactive
    }

    private func removeForward(_ id: UUID) {
        session.portForwards.removeAll { $0.id == id }
    }
}

struct AddSessionPortForwardView: View {
    let onAdd: (PortForward) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var forwardType: PortForward.ForwardType = .local
    @State private var localPort = ""
    @State private var remoteHost = "localhost"
    @State private var remotePort = ""
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
                        onAdd(forward)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let local = Int(localPort), local > 0 && local <= 65535 else { return false }
        if forwardType == .dynamic { return true }
        guard !remoteHost.isEmpty else { return false }
        guard let remote = Int(remotePort), remote > 0 && remote <= 65535 else { return false }
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
                let recordings = SessionRecorder.loadRecordings()
                if recordings.isEmpty {
                    ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Session recordings will appear here."))
                } else {
                    ForEach(recordings) { recording in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(recording.serverName)
                                    .font(.headline)
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
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                SessionRecorder.deleteRecording(recording)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingRecordings = false }
                }
            }
        }
        .frame(width: 520, height: 440)
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
