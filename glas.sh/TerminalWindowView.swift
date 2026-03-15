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
import AudioToolbox
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
    @State private var terminalSettingsTab: TerminalSettingsModalTab = .terminal
    @StateObject private var terminalHostModel = SwiftTermHostModel()
    @State private var didRunCloseGooseCall = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 0) {
            terminalContent
                .padding(10)
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
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
            runCloseGooseCallIfNeeded()
        }
        .onChange(of: showingSearchOverlay) { _, showing in
            if showing { isSearchFieldFocused = true }
        }
    }
    
    // MARK: - Connection Label (top ornament)

    private var connectionLabel: some View {
        HStack(spacing: 8) {
            Text(session.server.name)
                .font(.caption)
                .fontWeight(.semibold)

            Text("\(session.server.username)@\(session.server.host):\(session.server.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.server.name), \(session.server.username) at \(session.server.host) port \(session.server.port)")
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
                    if settingsManager.visualBell {
                        withAnimation(.easeInOut(duration: 0.1)) { showVisualBell = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.1)) { showVisualBell = false }
                        }
                    } else {
                        AudioServicesPlaySystemSound(1007)
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
        }
        .overlay(alignment: .top) {
            if showingSearchOverlay {
                terminalSearchOverlay
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
        if effectiveBlurBackground {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(effectiveWindowOpacity)
        } else {
            let bg = rgbaComponents(settingsManager.currentTheme.background.color)
            Rectangle()
                .fill(Color(red: bg.red, green: bg.green, blue: bg.blue, opacity: effectiveWindowOpacity))
        }
    }

    private var tintColor: Color? {
        switch effectiveGlassTint {
        case "Blue":
            return .blue
        case "Purple":
            return .purple
        case "Green":
            return .green
        default:
            return nil
        }
    }

    private var effectiveWindowOpacity: Double {
        settingsManager.sessionOverride(for: session.id)?.windowOpacity ?? settingsManager.windowOpacity
    }

    private var effectiveBlurBackground: Bool {
        settingsManager.sessionOverride(for: session.id)?.blurBackground ?? settingsManager.blurBackground
    }

    private var effectiveInteractiveGlassEffects: Bool {
        settingsManager.sessionOverride(for: session.id)?.interactiveGlassEffects ?? settingsManager.interactiveGlassEffects
    }

    private var effectiveGlassTint: String {
        settingsManager.sessionOverride(for: session.id)?.glassTint ?? settingsManager.glassTint
    }

    private func runCloseGooseCallIfNeeded() {
        guard !didRunCloseGooseCall else { return }
        didRunCloseGooseCall = true
        Task { @MainActor in
            await Task.yield()
            openWindow(id: "main")
            try? await Task.sleep(for: .milliseconds(150))
            openWindow(id: "main")
        }
    }

    private func duplicateSession() {
        Task {
            let _ = await sessionManager.createSession(for: session.server)
        }
    }

    private func reconnectSession() {
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
                .disabled(session.state != .connected)

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
                .disabled(session.state != .connected)

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

                Toggle(
                    "Blur background",
                    isOn: Binding(
                        get: { sessionOverride.blurBackground ?? settings.blurBackground },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.blurBackground = newValue
                            }
                        }
                    )
                )

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

                Picker(
                    "Glass tint",
                    selection: Binding(
                        get: { sessionOverride.glassTint ?? settings.glassTint },
                        set: { newValue in
                            settings.updateSessionOverride(for: session.id) { override in
                                override.glassTint = newValue
                            }
                        }
                    )
                ) {
                    Text("None").tag("None")
                    Text("Blue").tag("Blue")
                    Text("Purple").tag("Purple")
                    Text("Green").tag("Green")
                }

                Button("Reset Overrides", role: .destructive) {
                    settings.updateSessionOverride(for: session.id) { override in
                        override.windowOpacity = nil
                        override.blurBackground = nil
                        override.interactiveGlassEffects = nil
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
        session.portForwards[index].isActive = isActive
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
