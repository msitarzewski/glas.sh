//
//  SettingsView.swift
//  glas.sh
//
//  Application settings
//

import SwiftUI
import GlasSecretStore
#if os(macOS)
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environment(settingsManager)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            TerminalSettingsView()
                .environment(settingsManager)
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
            
            AppearanceSettingsView()
                .environment(settingsManager)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
            
            SnippetsSettingsView()
                .environment(settingsManager)
                .tabItem {
                    Label("Snippets", systemImage: "text.badge.star")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .terminalPlatformGlassBackground(cornerRadius: 28)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(SessionManager.self) private var sessionManager
    private var serverManager: ServerManager { sessionManager.serverManager }
    @State private var showingAddSSHKey = false
    @State private var showingGenerateSecureEnclaveKey = false
    @State private var editingSSHKey: StoredSSHKey?
    @State private var keyPendingDeletion: StoredSSHKey?
    @State private var keyCopyMessage: String?
    @State private var sshConfigText: String = ""
    @State private var importResultMessage: String?
    @State private var tailscaleAuthMethod: TailscaleAuthMethod = .apiKey
    @State private var tailscaleAPIKey: String = ""
    @State private var tailscaleOAuthClientID: String = ""
    @State private var tailscaleOAuthClientSecret: String = ""
    @State private var tailscaleTestResult: String?
    @State private var tailscaleTestInProgress = false
    
    var body: some View {
        @Bindable var settings = settingsManager
        
        Form {
            Section("Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $settings.autoReconnect)
                    .onChange(of: settings.autoReconnect) { _, _ in
                        settings.saveSettings()
                    }
                
                Toggle("Confirm before closing active sessions", isOn: $settings.confirmBeforeClosing)
                    .onChange(of: settings.confirmBeforeClosing) { _, _ in
                        settings.saveSettings()
                    }
            }
            
            Section("Terminal Behavior") {
                Toggle("Keep scrollback during session", isOn: $settings.saveScrollback)
                    .onChange(of: settings.saveScrollback) { _, _ in
                        settings.saveSettings()
                    }

                Text("Scrollback stays in memory and is cleared when the terminal session ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Stepper("Max scrollback lines: \(settings.maxScrollbackLines)",
                       value: $settings.maxScrollbackLines,
                       in: 1000...100000,
                       step: 1000)
                    .onChange(of: settings.maxScrollbackLines) { _, _ in
                        settings.saveSettings()
                    }
            }
            
            Section("Session Recording") {
                let recordings = SessionRecorder.loadRecordings()
                let totalSize = Self.recordingStorageSize()
                LabeledContent("Recordings", value: "\(recordings.count)")
                LabeledContent("Storage", value: Self.formatBytes(totalSize))
            }

            Section("Notifications") {
                Toggle("Bell enabled", isOn: $settings.bellEnabled)
                    .onChange(of: settings.bellEnabled) { _, _ in
                        settings.saveSettings()
                    }
                
                Toggle("Visual bell", isOn: $settings.visualBell)
                    .disabled(!settings.bellEnabled)
                    .onChange(of: settings.visualBell) { _, _ in
                        settings.saveSettings()
                    }
            }

            Section("Security") {
                Picker("Host key verification", selection: $settings.hostKeyVerificationMode) {
                    ForEach([HostKeyVerificationMode.ask, .strict], id: \.rawValue) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .onChange(of: settings.hostKeyVerificationMode) { _, _ in
                    settings.saveSettings()
                }
            }

            Section("Tailscale") {
                TextField("Tailnet name", text: $settings.tailscaleTailnet)
                    .terminalTextInputDefaults()
                    .onChange(of: settings.tailscaleTailnet) { _, _ in
                        settings.saveSettings()
                    }

                Picker("Auth method", selection: $tailscaleAuthMethod) {
                    Text("API Key").tag(TailscaleAuthMethod.apiKey)
                    Text("OAuth Client").tag(TailscaleAuthMethod.oauthClient)
                }
                .onChange(of: tailscaleAuthMethod) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.tailscaleAuthMethod)
                    tailscaleTestResult = nil
                }

                if tailscaleAuthMethod == .apiKey {
                    SecureField("API Key", text: $tailscaleAPIKey)
                        .textContentType(.init(rawValue: ""))
                    Text("Generate at admin console → Settings → Keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("OAuth Client ID", text: $tailscaleOAuthClientID)
                        .terminalTextInputDefaults()
                    SecureField("OAuth Client Secret", text: $tailscaleOAuthClientSecret)
                        .textContentType(.init(rawValue: ""))
                    Text("Create at admin console → Settings → OAuth clients")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    saveTailscaleCredentialsAndTest()
                } label: {
                    HStack {
                        if tailscaleTestInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Text("Save & Test")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tailscaleTestInProgress || !tailscaleCredentialsValid)

                if let tailscaleTestResult {
                    Text(tailscaleTestResult)
                        .font(.caption)
                        .foregroundStyle(tailscaleTestResult.hasPrefix("Connected") ? .green : .red)
                }

                Text("Earlier-build Tailscale credentials are not imported from unnamespaced entries in the shared Keychain service. If a field is empty after updating, re-enter it once to store it in glas.sh's terminal namespace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Keys") {
                if settings.sshKeys.isEmpty {
                    Text("No SSH keys added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.sshKeys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                Text(key.keyTypeBadge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy Public Key") {
                                copyPublicKey(for: key)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Copy public key for \(key.name)")

                            Menu {
                                Button {
                                    editingSSHKey = key
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    keyPendingDeletion = key
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("More actions for \(key.name)")
                        }
                    }
                }

                Button {
                    showingAddSSHKey = true
                } label: {
                    Label("Add SSH Key", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingGenerateSecureEnclaveKey = true
                } label: {
                    Label("Generate Secure Enclave Key", systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
            }

            Section("Import SSH Config") {
                TextEditor(text: $sshConfigText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)

                Button("Import into Server Configs") {
                    let result = settings.importSSHConfig(sshConfigText, serverManager: serverManager)
                    let warnings = result.warnings.prefix(3).joined(separator: "\n")
                    importResultMessage =
                        "Imported: \(result.imported), Updated: \(result.updated), Skipped: \(result.skipped)"
                        + (warnings.isEmpty ? "" : "\n\nWarnings:\n\(warnings)")
                }
                .buttonStyle(.borderedProminent)
                .disabled(sshConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let importResultMessage, !importResultMessage.isEmpty {
                    Text(importResultMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            serverManager.loadServersIfNeeded()
            loadTailscaleCredentials()
        }
        .sheet(isPresented: $showingAddSSHKey) {
            AddSSHKeyView()
                .environment(settingsManager)
        }
        .sheet(isPresented: $showingGenerateSecureEnclaveKey) {
            GenerateSecureEnclaveSSHKeyView()
                .environment(settingsManager)
        }
        .sheet(item: $editingSSHKey) { key in
            RenameSSHKeyView(key: key)
                .environment(settingsManager)
        }
        .alert(
            "SSH Public Key",
            isPresented: Binding(
                get: { keyCopyMessage != nil },
                set: { isPresented in
                    if !isPresented { keyCopyMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                keyCopyMessage = nil
            }
        } message: {
            Text(keyCopyMessage ?? "")
        }
        .confirmationDialog(
            "Delete SSH Key?",
            isPresented: Binding(
                get: { keyPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { keyPendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: keyPendingDeletion
        ) { key in
            Button("Delete \(key.name)", role: .destructive) {
                do {
                    try settingsManager.deleteSSHKey(key.id, serverManager: serverManager)
                } catch {
                    keyCopyMessage = "The key was not deleted because secure storage could not be updated: \(error.localizedDescription)"
                }
                keyPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                keyPendingDeletion = nil
            }
        } message: { key in
            Text("This removes '\(key.name)' from secure storage and unassigns it from any servers currently using it.")
        }
    }

    private func copyPublicKey(for key: StoredSSHKey) {
        do {
            let value = try settingsManager.openSSHPublicKey(for: key.id)
            copyToClipboard(value)
            keyCopyMessage = "Copied public key for '\(key.name)'."
        } catch {
            keyCopyMessage = "Failed to export public key for '\(key.name)': \(error.localizedDescription)"
        }
    }

    private func copyToClipboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    private func loadTailscaleCredentials() {
        tailscaleAuthMethod = TailscaleAuthMethod(rawValue:
            UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        ) ?? .apiKey

        if let key = try? KeychainManager.retrieveTailscaleAPIKey() {
            tailscaleAPIKey = key
        }
        if let creds = try? KeychainManager.retrieveTailscaleOAuthCredentials() {
            tailscaleOAuthClientID = creds.clientID
            tailscaleOAuthClientSecret = creds.clientSecret
        }
    }

    private var tailscaleCredentialsValid: Bool {
        switch tailscaleAuthMethod {
        case .apiKey:
            return !tailscaleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .oauthClient:
            return !tailscaleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !tailscaleOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func recordingStorageSize() -> Int64 {
        let directory = SessionRecorder.recordingsDirectory
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func saveTailscaleCredentialsAndTest() {
        tailscaleTestInProgress = true
        tailscaleTestResult = nil

        do {
            switch tailscaleAuthMethod {
            case .apiKey:
                try KeychainManager.saveTailscaleAPIKey(
                    tailscaleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            case .oauthClient:
                try KeychainManager.saveTailscaleOAuthCredentials(
                    clientID: tailscaleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                    clientSecret: tailscaleOAuthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            // Switch the active method only after its credential write succeeds.
            UserDefaults.standard.set(tailscaleAuthMethod.rawValue, forKey: UserDefaultsKeys.tailscaleAuthMethod)
        } catch {
            tailscaleTestResult = "Failed to save: \(error.localizedDescription)"
            tailscaleTestInProgress = false
            return
        }

        Task {
            let client = TailscaleClient()
            do {
                let success = try await client.testConnection()
                tailscaleTestResult = success ? "Connected to Tailscale." : "Connection test failed."
            } catch {
                tailscaleTestResult = "Error: \(error.localizedDescription)"
            }
            tailscaleTestInProgress = false
        }
    }
}

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @State private var showingThemeEditor = false
    
    var body: some View {
        @Bindable var settings = settingsManager
        
        Form {
            Section("Theme") {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(settingsManager.currentTheme.name)
                            .font(.headline)
                        
                        Text("Font: \(settingsManager.currentTheme.fontName) \(Int(settingsManager.currentTheme.fontSize))pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Edit Theme") {
                        showingThemeEditor = true
                    }
                }
                
                // Color preview
                HStack(spacing: 8) {
                    ForEach([
                        ("Background", settingsManager.currentTheme.background.color),
                        ("Foreground", settingsManager.currentTheme.foreground.color),
                        ("Red", settingsManager.currentTheme.red.color),
                        ("Green", settingsManager.currentTheme.green.color),
                        ("Blue", settingsManager.currentTheme.blue.color),
                        ("Yellow", settingsManager.currentTheme.yellow.color)
                    ], id: \.0) { name, color in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Circle()
                                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                                }

                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(name) color preview")
                    }
                }
            }
            
            Section("Font") {
                Picker("Font Family", selection: fontFamilyBinding) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Monaco").tag("Monaco")
                    Text("Menlo").tag("Menlo")
                    Text("Courier New").tag("Courier New")
                }
                
                Slider(value: fontSizeBinding, in: 10...24, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("24")
                }
            }
            
            Section("Cursor") {
                Picker("Cursor Style", selection: $settings.cursorStyle) {
                    Text("Block").tag("Block")
                    Text("Underline").tag("Underline")
                    Text("Bar").tag("Bar")
                }
                .onChange(of: settings.cursorStyle) { _, _ in
                    settings.saveSettings()
                }
                
                Toggle("Blinking cursor", isOn: $settings.blinkingCursor)
                    .onChange(of: settings.blinkingCursor) { _, _ in
                        settings.saveSettings()
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingThemeEditor) {
            ThemeEditorView()
                .environment(settingsManager)
        }
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { settingsManager.currentTheme.fontName },
            set: { newValue in
                var theme = settingsManager.currentTheme
                theme.fontName = newValue
                settingsManager.saveTheme(theme)
            }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settingsManager.currentTheme.fontSize) },
            set: { newValue in
                var theme = settingsManager.currentTheme
                theme.fontSize = CGFloat(newValue)
                settingsManager.saveTheme(theme)
            }
        )
    }
}

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    
    var body: some View {
        @Bindable var settings = settingsManager
        
        Form {
            Section("Glass") {
                #if os(visionOS)
                Picker("Frost", selection: $settings.glassFrost) {
                    Text("Light").tag("ultraThin")
                    Text("Medium").tag("thin")
                    Text("Heavy").tag("regular")
                    Text("Max").tag("thick")
                }
                .onChange(of: settings.glassFrost) { _, _ in
                    settings.saveSettings()
                }
                #endif

                Slider(value: $settings.windowOpacity, in: 0.0...1.0) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Text("Transparent")
                } maximumValueLabel: {
                    Text("Opaque")
                }
                .onChange(of: settings.windowOpacity) { _, _ in
                    settings.saveSettings()
                }

                Slider(value: $settings.blurBackground, in: 0.0...1.0) {
                    Text("Blur")
                } minimumValueLabel: {
                    Text("None")
                } maximumValueLabel: {
                    Text("Maximum")
                }
                .onChange(of: settings.blurBackground) { _, _ in
                    settings.saveSettings()
                }

                #if os(visionOS)
                Toggle("Interactive glass", isOn: $settings.interactiveGlass)
                    .onChange(of: settings.interactiveGlass) { _, _ in
                        settings.saveSettings()
                    }
                #endif

                #if os(visionOS)
                Text("Opacity paints the theme color; Blur controls passthrough frosting independently. Set both to zero for a completely transparent terminal. Interactive glass changes how the selected frost responds to gaze without disabling either slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("Tint, opacity, and blur apply only to the terminal canvas. Set opacity and blur to zero for a completely transparent typing surface; window chrome keeps the system Liquid Glass appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                GlassTintPicker(value: $settings.glassTint)
                    .onChange(of: settings.glassTint) { _, _ in
                        settings.saveSettings()
                    }
            }
            
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Snippets Settings

struct SnippetsSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @State private var showingAddSnippet = false
    @State private var editingSnippet: CommandSnippet?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Command Snippets")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showingAddSnippet = true
                } label: {
                    Label("Add Snippet", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            // Snippets list
            if settingsManager.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "text.badge.star")
                } description: {
                    Text("Create command snippets for quick access")
                } actions: {
                    Button {
                        showingAddSnippet = true
                    } label: {
                        Text("Add Snippet")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(settingsManager.snippets) { snippet in
                        SnippetRow(snippet: snippet) {
                            editingSnippet = snippet
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            settingsManager.deleteSnippet(settingsManager.snippets[index])
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSnippet) {
            AddSnippetView(settingsManager: settingsManager)
        }
        .sheet(item: $editingSnippet) { snippet in
            EditSnippetView(snippet: snippet, settingsManager: settingsManager)
        }
    }
}

// MARK: - Snippet Row

struct SnippetRow: View {
    let snippet: CommandSnippet
    let onEdit: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.name)
                    .font(.headline)
                
                Text(snippet.command)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if !snippet.description.isEmpty {
                    Text(snippet.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                if let lastUsed = snippet.lastUsed {
                    HStack(spacing: 4) {
                        Text("Used \(snippet.useCount) times")
                        Text("•")
                        Text("Last: \(lastUsed, formatter: relativeDateFormatter)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                }
            }
            
            Spacer()
            
            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Add/Edit Snippet Views

struct AddSnippetView: View {
    @Bindable var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var command = ""
    @State private var description = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...6)
                    
                    TextField("Description (optional)", text: $description)
                }
                
                Section("Tags") {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                        
                        HStack(spacing: 4) {
                            TextField("Add tag", text: $newTag)
                                .textFieldStyle(.plain)
                                .frame(width: 80)
                                .onSubmit {
                                    if !newTag.isEmpty {
                                        tags.append(newTag)
                                        newTag = ""
                                    }
                                }
                            
                            if !newTag.isEmpty {
                                Button {
                                    tags.append(newTag)
                                    newTag = ""
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add tag")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                    }
                }
            }
            .navigationTitle("Add Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let snippet = CommandSnippet(
                            name: name,
                            command: command,
                            description: description,
                            tags: tags
                        )
                        settingsManager.addSnippet(snippet)
                        dismiss()
                    }
                    .disabled(name.isEmpty || command.isEmpty)
                }
            }
        }
    }
}

struct EditSnippetView: View {
    let snippet: CommandSnippet
    @Bindable var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String
    @State private var command: String
    @State private var description: String
    @State private var tags: [String]
    @State private var newTag = ""
    
    init(snippet: CommandSnippet, settingsManager: SettingsManager) {
        self.snippet = snippet
        self.settingsManager = settingsManager
        
        _name = State(initialValue: snippet.name)
        _command = State(initialValue: snippet.command)
        _description = State(initialValue: snippet.description)
        _tags = State(initialValue: snippet.tags)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...6)
                    
                    TextField("Description (optional)", text: $description)
                }
                
                Section("Tags") {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                        
                        HStack(spacing: 4) {
                            TextField("Add tag", text: $newTag)
                                .textFieldStyle(.plain)
                                .frame(width: 80)
                                .onSubmit {
                                    if !newTag.isEmpty {
                                        tags.append(newTag)
                                        newTag = ""
                                    }
                                }
                            
                            if !newTag.isEmpty {
                                Button {
                                    tags.append(newTag)
                                    newTag = ""
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add tag")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                    }
                }

                Section("Statistics") {
                    LabeledContent("Times used", value: "\(snippet.useCount)")
                    if let lastUsed = snippet.lastUsed {
                        LabeledContent("Last used", value: lastUsed, format: .dateTime)
                    }
                }
            }
            .navigationTitle("Edit Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updatedSnippet = snippet
                        updatedSnippet.name = name
                        updatedSnippet.command = command
                        updatedSnippet.description = description
                        updatedSnippet.tags = tags
                        
                        settingsManager.updateSnippet(updatedSnippet)
                        dismiss()
                    }
                    .disabled(name.isEmpty || command.isEmpty)
                }
            }
        }
    }
}

// MARK: - Theme Editor

struct ThemeEditorView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var theme: TerminalTheme
    @State private var themeLibraryDraft: TerminalThemeLibrary
    @State private var selectedRecordID: UUID?
    @State private var themeImportError: String?
    @State private var themePendingDeletion: TerminalThemeRecord?

    init() {
        _theme = State(initialValue: TerminalTheme.default)
        _themeLibraryDraft = State(initialValue: .initial())
        _selectedRecordID = State(initialValue: nil)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    if let loadError = settingsManager.themeLibraryLoadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    ForEach(themeLibraryDraft.activeRecords) { record in
                        Button {
                            selectDraft(record.id)
                        } label: {
                            themeListRow(
                                theme: record.theme,
                                originDescription: originDescription(record.origin),
                                isActive: record.id == themeLibraryDraft.selectedThemeID,
                                isDraftSelected: record.id == selectedRecordID
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            record.id == selectedRecordID
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                    }
                }
                .accessibilityLabel("Terminal themes")

                Divider()

                managementActions
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                GroupBox("iCloud Sync") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Sync themes", isOn: iCloudSyncBinding)
                        Text(settingsManager.iCloudSyncStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #if os(visionOS)
                        Text("Apple Terminal profiles imported on your Mac appear here after iCloud sync. Profile colors and fonts sync; Mac shell commands and window backgrounds do not.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding([.horizontal, .bottom])
            }
            .navigationTitle("Themes")
        } detail: {
            if selectedRecordID == nil {
                ContentUnavailableView(
                    "Select a Theme",
                    systemImage: "paintpalette",
                    description: Text("Choose a terminal theme to inspect or edit.")
                )
            } else {
                Form {
                    Section("Preview") {
                        livePreview
                    }

                    Section("General") {
                        TextField("Name", text: themeNameBinding)
                            .disabled(selectedThemeIsBuiltIn)
                        Picker("Canvas Material", selection: canvasAppearanceBinding) {
                            ForEach(TerminalThemeAppearance.allCases, id: \.self) { appearance in
                                Text(appearance.displayName).tag(appearance)
                            }
                        }
                        Text("Window chrome remains native. Canvas material controls only the terminal's blur polarity so theme contrast stays stable across bright and dark surroundings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ColorPicker(
                            "Background",
                            selection: colorBinding(for: \.background),
                            supportsOpacity: false
                        )
                        ColorPicker(
                            "Foreground",
                            selection: colorBinding(for: \.foreground),
                            supportsOpacity: false
                        )
                        ColorPicker(
                            "Cursor",
                            selection: colorBinding(for: \.cursor),
                            supportsOpacity: false
                        )
                        ColorPicker("Selection", selection: colorBinding(for: \.selection))

                        Picker("Font Family", selection: $theme.fontName) {
                            if !["SF Mono", "Monaco", "Menlo", "Courier New"].contains(theme.fontName) {
                                Text(theme.fontName).tag(theme.fontName)
                            }
                            Text("SF Mono").tag("SF Mono")
                            Text("Monaco").tag("Monaco")
                            Text("Menlo").tag("Menlo")
                            Text("Courier New").tag("Courier New")
                        }

                        Slider(
                            value: fontSizeBinding,
                            in: Double(TerminalTheme.minimumFontSize)...Double(TerminalTheme.maximumFontSize),
                            step: 1
                        ) {
                            Text("Font Size")
                        } minimumValueLabel: {
                            Text("10")
                        } maximumValueLabel: {
                            Text("24")
                        }

                        Button("Use Apple Clear Dark Colors", systemImage: "paintpalette") {
                            theme.applyAppleClearDarkColors()
                        }
                    }

                    Section("ANSI Colors") {
                        ansiColorGrid
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(theme.name)
            }
        }
        .onAppear(perform: loadInitialSelection)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveSelectedTheme()
                }
                .disabled(
                    settingsManager.themeLibraryLoadError != nil
                        || selectedRecordID == nil
                        || !theme.isValidForPersistence
                        || !themeLibraryDraft.activeRecords.allSatisfy({ $0.theme.isValidForPersistence })
                )
            }
        }
        .alert("Theme Import Failed", isPresented: themeImportErrorPresented) {
            Button("OK", role: .cancel) { themeImportError = nil }
        } message: {
            Text(themeImportError ?? "The selected theme could not be imported.")
        }
        .confirmationDialog(
            "Delete \(themePendingDeletion?.theme.name ?? "Theme")?",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Theme", role: .destructive) {
                confirmDeleteSelectedTheme()
            }
            Button("Cancel", role: .cancel) {
                themePendingDeletion = nil
            }
        } message: {
            Text("This removes the custom theme from the library when you save your changes.")
        }
        #if os(macOS)
        .frame(minWidth: 880, minHeight: 620)
        #endif
    }

    private var managementActions: some View {
        HStack(spacing: 12) {
            Button("New", systemImage: "plus") {
                duplicateSelectedTheme(asNewTheme: true)
            }
            .disabled(selectedRecordID == nil)

            Button("Duplicate", systemImage: "plus.square.on.square") {
                duplicateSelectedTheme(asNewTheme: false)
            }
            .disabled(selectedRecordID == nil)

            Button("Delete", systemImage: "trash", role: .destructive) {
                deleteSelectedTheme()
            }
            .disabled(selectedRecordID == nil || selectedThemeIsBuiltIn)

            Button("Reset", systemImage: "arrow.counterclockwise") {
                resetSelectedTheme()
            }
            .disabled(selectedRecordID == nil || !selectedThemeIsBuiltIn)

            #if os(macOS)
            Menu {
                Button("From .terminal File…") {
                    importThemeFromDisk()
                }
                if !appleTerminalBuiltInProfiles.isEmpty {
                    Menu("Apple Built-in Profiles") {
                        ForEach(appleTerminalBuiltInProfiles, id: \.path) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                importTheme(at: url)
                            }
                        }
                    }
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            #endif
        }
        #if os(macOS)
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .help("Create, duplicate, delete, reset, or import terminal themes")
        #else
        .frame(minHeight: 60)
        #endif
    }

    private func themeListRow(
        theme: TerminalTheme,
        originDescription: String,
        isActive: Bool,
        isDraftSelected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(theme.name)
                        .lineLimit(1)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Active")
                    }
                }
                Text(originDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                ForEach(Array(theme.ansiColors.prefix(4).enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.color)
                        .frame(width: 8, height: 22)
                }
            }
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isDraftSelected ? .isSelected : [])
        .accessibilityValue(isDraftSelected ? "Selected for editing" : originDescription)
        #if os(visionOS)
        .frame(minHeight: 60)
        #else
        .frame(minHeight: 34)
        #endif
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Aa 01")
                    .font(.custom(theme.fontName, size: max(10, theme.fontSize)))
                    .foregroundStyle(theme.foreground.color)
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.cursor.color)
                    .frame(width: 8, height: 20)
            }

            HStack(spacing: 3) {
                ForEach(Array(theme.ansiColors.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.color)
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            livePreviewBackground
                .clipShape(.rect(cornerRadius: 10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview of \(theme.name)")
    }

    @ViewBuilder
    private var livePreviewBackground: some View {
        #if os(macOS)
        TerminalCanvasBackground(
            color: theme.canvasBackgroundColor,
            tint: TerminalGlassTint.color(for: settingsManager.glassTint),
            opacity: settingsManager.windowOpacity,
            blur: settingsManager.blurBackground,
            appearance: theme.resolvedAppearance
        )
        #else
        ZStack {
            Rectangle()
                .fill(theme.canvasBackgroundColor.color)
                .opacity(settingsManager.windowOpacity)
            if let tint = TerminalGlassTint.color(for: settingsManager.glassTint) {
                Rectangle()
                    .fill(tint.opacity(0.12 * settingsManager.windowOpacity))
            }
        }
        .modifier(GlassWindowBackground(
            interactive: false,
            material: .regularMaterial,
            blurAmount: settingsManager.blurBackground,
            appearance: theme.resolvedAppearance
        ))
        #endif
    }

    private var ansiColorGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Normal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Bright")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ansiColorRow("Black", normal: \.black, bright: \.brightBlack)
            ansiColorRow("Red", normal: \.red, bright: \.brightRed)
            ansiColorRow("Green", normal: \.green, bright: \.brightGreen)
            ansiColorRow("Yellow", normal: \.yellow, bright: \.brightYellow)
            ansiColorRow("Blue", normal: \.blue, bright: \.brightBlue)
            ansiColorRow("Magenta", normal: \.magenta, bright: \.brightMagenta)
            ansiColorRow("Cyan", normal: \.cyan, bright: \.brightCyan)
            ansiColorRow("White", normal: \.white, bright: \.brightWhite)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ansiColorRow(
        _ name: String,
        normal: WritableKeyPath<TerminalTheme, CodableColor>,
        bright: WritableKeyPath<TerminalTheme, CodableColor>
    ) -> some View {
        GridRow {
            Text(name)
            ansiColorPicker("\(name), normal", keyPath: normal)
            ansiColorPicker("\(name), bright", keyPath: bright)
        }
    }

    @ViewBuilder
    private func ansiColorPicker(
        _ label: String,
        keyPath: WritableKeyPath<TerminalTheme, CodableColor>
    ) -> some View {
        ColorPicker(
            label,
            selection: colorBinding(for: keyPath),
            supportsOpacity: false
        )
            .labelsHidden()
            .accessibilityLabel(label)
            #if os(visionOS)
            .frame(minWidth: 60, minHeight: 60)
            #endif
    }

    private func colorBinding(for keyPath: WritableKeyPath<TerminalTheme, CodableColor>) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: keyPath].color },
            set: { newColor in
                theme[keyPath: keyPath] = CodableColor(color: newColor)
            }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(theme.fontSize) },
            set: { theme.fontSize = CGFloat($0) }
        )
    }

    private var themeNameBinding: Binding<String> {
        Binding(
            get: { theme.name },
            set: { theme.name = String($0.prefix(TerminalTheme.maximumNameLength)) }
        )
    }

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { settingsManager.iCloudSyncEnabled },
            set: { settingsManager.setICloudSyncEnabled($0) }
        )
    }

    private var canvasAppearanceBinding: Binding<TerminalThemeAppearance> {
        Binding(
            get: { theme.preferredAppearance ?? .automatic },
            set: { theme.preferredAppearance = $0 }
        )
    }

    private var selectedThemeIsBuiltIn: Bool {
        guard let selectedRecordID else { return false }
        return themeLibraryDraft.activeRecords.first {
            $0.id == selectedRecordID
        }?.isBuiltIn == true
    }

    private var themeImportErrorPresented: Binding<Bool> {
        Binding(
            get: { themeImportError != nil },
            set: { if !$0 { themeImportError = nil } }
        )
    }

    private func loadInitialSelection() {
        themeLibraryDraft = settingsManager.themeLibrary
        let selectedID = themeLibraryDraft.selectedThemeID
        let fallbackID = themeLibraryDraft.activeRecords.first?.id
        selectDraft(
            themeLibraryDraft.activeRecords.contains(where: { $0.id == selectedID })
                ? selectedID
                : fallbackID
        )
    }

    private func selectDraft(_ id: UUID?) {
        stageCurrentTheme()
        guard let id,
              let record = themeLibraryDraft.activeRecords.first(where: { $0.id == id }) else {
            selectedRecordID = nil
            return
        }
        selectedRecordID = id
        theme = record.theme
        _ = themeLibraryDraft.select(id)
    }

    private func saveSelectedTheme() {
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        stageCurrentTheme()
        guard settingsManager.replaceThemeLibrary(themeLibraryDraft) else {
            themeImportError = "The theme library contains an invalid theme and was not saved."
            return
        }
        dismiss()
    }

    private func duplicateSelectedTheme(asNewTheme: Bool) {
        stageCurrentTheme()
        guard themeLibraryDraft.activeRecords.count < TerminalThemeLibrary.maximumThemeCount,
              themeLibraryDraft.records.count < TerminalThemeLibrary.maximumRecordCount,
              let selectedRecordID,
              let source = themeLibraryDraft.activeRecords.first(where: { $0.id == selectedRecordID }) else {
            return
        }
        let copy = source.theme.reidentified(
            name: asNewTheme ? "New Theme" : "\(source.theme.name) Copy"
        )
        themeLibraryDraft.upsert(copy, origin: .custom)
        _ = themeLibraryDraft.select(copy.id)
        selectDraft(copy.id)
    }

    private func deleteSelectedTheme() {
        guard let selectedRecordID,
              !selectedThemeIsBuiltIn,
              let record = themeLibraryDraft.activeRecords.first(where: { $0.id == selectedRecordID }) else {
            return
        }
        themePendingDeletion = record
    }

    private func confirmDeleteSelectedTheme() {
        guard let record = themePendingDeletion else { return }
        themePendingDeletion = nil
        _ = themeLibraryDraft.delete(record.id)
        selectDraft(themeLibraryDraft.selectedThemeID)
    }

    private func resetSelectedTheme() {
        guard let selectedRecordID, selectedThemeIsBuiltIn else { return }
        let reset = TerminalTheme.default.reidentified(id: selectedRecordID, name: theme.name)
        themeLibraryDraft.upsert(reset, origin: .builtIn)
        selectDraft(selectedRecordID)
    }

    private func stageCurrentTheme() {
        guard let selectedRecordID,
              theme.id == selectedRecordID,
              let record = themeLibraryDraft.activeRecords.first(where: { $0.id == selectedRecordID }) else {
            return
        }
        themeLibraryDraft.upsert(theme, origin: record.origin)
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { themePendingDeletion != nil },
            set: { if !$0 { themePendingDeletion = nil } }
        )
    }

    private func originDescription(_ origin: TerminalThemeOrigin) -> String {
        switch origin {
        case .builtIn: "Built-in"
        case .custom: "Custom"
        case .appleTerminal: "Apple Terminal"
        }
    }

    #if os(macOS)
    private var appleTerminalBuiltInProfiles: [URL] {
        let directory = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings",
            isDirectory: true
        )
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "terminal" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        ?? []
    }

    private func importThemeFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Import Apple Terminal Profile"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "terminal") ?? .propertyList
        ]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            importTheme(at: url)
        }
    }

    private func importTheme(at url: URL) {
        do {
            stageCurrentTheme()
            let importedTheme = try TerminalThemeImportService.importTheme(
                from: url,
                fallback: theme
            )
            guard themeLibraryDraft.activeRecords.count < TerminalThemeLibrary.maximumThemeCount,
                  themeLibraryDraft.records.count < TerminalThemeLibrary.maximumRecordCount else {
                throw ThemeImportError.libraryFull
            }
            let imported = importedTheme.reidentified()
            themeLibraryDraft.upsert(imported, origin: .appleTerminal)
            _ = themeLibraryDraft.select(imported.id)
            let importedID = imported.id
            selectDraft(importedID)
        } catch {
            themeImportError = error.localizedDescription
        }
    }

    private enum ThemeImportError: LocalizedError {
        case libraryFull

        var errorDescription: String? {
            switch self {
            case .libraryFull:
                "The theme library is full. Delete a custom theme before importing another."
            }
        }
    }
    #endif
}

struct AddSSHKeyView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var privateKey: String = ""
    @State private var passphrase: String = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Details") {
                    TextField("Key name", text: $name)
                        .focused($isNameFocused)
                    SecureField("Passphrase (optional)", text: $passphrase)
                    Text("RSA and ED25519 private keys are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Private Key") {
                    TextEditor(text: $privateKey)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add SSH Key")
            .onAppear { isNameFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            _ = try settingsManager.addSSHKey(
                                name: name,
                                privateKey: privateKey,
                                passphrase: passphrase.isEmpty ? nil : passphrase
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

struct GenerateSecureEnclaveSSHKeyView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Details") {
                    TextField("Key name", text: $name)
                        .focused($isNameFocused)
                    Text("Generates a hardware-bound ECDSA P-256 signing key. The private key never leaves the Secure Enclave, and each use requires user presence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Generate Key")
            .onAppear { isNameFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        do {
                            _ = try settingsManager.generateSecureEnclaveP256Key(name: name)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct RenameSSHKeyView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    let key: StoredSSHKey
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(key: StoredSSHKey) {
        self.key = key
        _name = State(initialValue: key.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rename") {
                    TextField("Key name", text: $name)
                        .focused($isNameFocused)
                }
            }
            .navigationTitle("Rename SSH Key")
            .onAppear { isNameFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settingsManager.renameSSHKey(key.id, name: name)
                        dismiss()
                    }
                }
            }
        }
    }
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

#Preview {
    SettingsView()
        .environment(SettingsManager())
        .environment(SessionManager(loadImmediately: false))
}
