//
//  ServerFormViews.swift
//  glas.sh
//
//  Views for adding and editing server configurations
//

import SwiftUI
import GlasSecretStore
import os

extension View {
    @ViewBuilder
    func terminalTextInputDefaults() -> some View {
        #if canImport(UIKit)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalNumericInput() -> some View {
        #if canImport(UIKit)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalHoverHighlight() -> some View {
        #if os(visionOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalPlatformGlassBackground(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        self.glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
        #else
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

}

private let supportedAuthenticationMethods: [AuthenticationMethod] = [.password, .sshKey]

@ViewBuilder
private func serverFormLabeledContent<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    #if os(macOS)
    LabeledContent(label) {
        content()
    }
    #else
    content()
    #endif
}

private struct TerminalInitialSizeEditor: View {
    @Binding var usesAppDefault: Bool
    @Binding var columns: Int
    @Binding var rows: Int
    let appDefault: TerminalGeometry

    var body: some View {
        Toggle("Use App Default Size", isOn: $usesAppDefault)

        if usesAppDefault {
            LabeledContent(
                "Initial Size",
                value: "\(appDefault.columns) × \(appDefault.rows)"
            )
            .foregroundStyle(.secondary)
        } else {
            Stepper(
                value: $columns,
                in: TerminalGeometry.columnRange,
                step: 5
            ) {
                LabeledContent("Columns", value: "\(columns)")
            }
            Stepper(value: $rows, in: TerminalGeometry.rowRange) {
                LabeledContent("Rows", value: "\(rows)")
            }
        }

        Text("This is the fallback for a new PTY. The visible terminal's measured size takes precedence before the shell starts.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Add Server View

struct AddServerView: View {
    @Bindable var serverManager: ServerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    private let provenance: ServerConnectionProvenance?
    private let isPrefilledDraft: Bool

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: AuthenticationMethod = .password
    @State private var password: String = ""
    @State private var sshKeyID: UUID?
    @State private var colorTag: ServerColorTag = .blue
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var isFavorite: Bool = false
    @State private var jumpHostIDs: [UUID] = []
    @State private var showingJumpHostPicker: Bool = false
    @State private var usesAppDefaultTerminalSize: Bool = true
    @State private var initialTerminalColumns: Int = TerminalGeometry.default.columns
    @State private var initialTerminalRows: Int = TerminalGeometry.default.rows

    @State private var showingAddSSHKey = false
    @State private var keychainSaveError: String?

    private enum Field: Hashable { case name, host, port, username, password }
    @FocusState private var focusedField: Field?

    init(serverManager: ServerManager, draft: ServerConfiguration? = nil) {
        self.serverManager = serverManager
        provenance = draft?.provenance
        isPrefilledDraft = draft != nil

        _name = State(initialValue: draft?.name ?? "")
        _host = State(initialValue: draft?.host ?? "")
        _port = State(initialValue: draft.map { String($0.port) } ?? "22")
        _username = State(initialValue: draft?.username ?? "")
        _authMethod = State(initialValue: draft?.authMethod == .sshKey ? .sshKey : .password)
        _sshKeyID = State(initialValue: draft?.sshKeyID)
        _colorTag = State(initialValue: draft?.colorTag ?? .blue)
        _tags = State(initialValue: draft?.tags ?? [])
        _isFavorite = State(initialValue: draft?.isFavorite ?? false)
        _jumpHostIDs = State(initialValue: draft?.resolvedJumpHostIDs ?? [])
        let draftHasTerminalSize = draft?.initialTerminalColumns != nil
            && draft?.initialTerminalRows != nil
        _usesAppDefaultTerminalSize = State(initialValue: !draftHasTerminalSize)
        _initialTerminalColumns = State(
            initialValue: draft?.initialTerminalColumns ?? TerminalGeometry.default.columns
        )
        _initialTerminalRows = State(
            initialValue: draft?.initialTerminalRows ?? TerminalGeometry.default.rows
        )
    }

    private var isFormValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let parsedPort = Int(port), (1...65_535).contains(parsedPort) else {
            return false
        }
        guard usesAppDefaultTerminalSize || TerminalGeometry.contains(
            rows: initialTerminalRows,
            columns: initialTerminalColumns
        ) else { return false }
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return sshKeyID != nil
        case .agent:
            return true
        }
    }

    var body: some View {
        platformEditor
            .onAppear {
                normalizeSelectedSSHKey()
                focusedField = isPrefilledDraft ? .username : .name
            }
            .onChange(of: authMethod) { _, _ in
                normalizeSelectedSSHKey()
            }
            .onChange(of: settingsManager.sshKeys.map(\.id)) { _, _ in
                normalizeSelectedSSHKey()
            }
            .onChange(of: usesAppDefaultTerminalSize) { _, usesDefault in
                guard !usesDefault else { return }
                initialTerminalColumns = settingsManager.initialTerminalColumns
                initialTerminalRows = settingsManager.initialTerminalRows
            }
    }

    @ViewBuilder
    private var platformEditor: some View {
        #if os(macOS)
        editor
            .frame(
                minWidth: 600,
                idealWidth: 640,
                maxWidth: 680,
                minHeight: 620,
                idealHeight: 720,
                maxHeight: 820
            )
        #else
        editor
        #endif
    }

    private var editor: some View {
        NavigationStack {
            platformForm
            .navigationTitle(isPrefilledDraft ? "Import Connection" : "Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPrefilledDraft ? "Save Connection" : "Add Server") {
                        saveServer()
                    }
                    .disabled(!isFormValid)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                }
            }
            .sheet(isPresented: $showingAddSSHKey) {
                AddSSHKeyView()
                    .environment(settingsManager)
            }
            .sheet(isPresented: $showingJumpHostPicker) {
                JumpHostPickerView(
                    servers: serverManager.servers,
                    excludedIDs: Set(jumpHostIDs)
                ) { selectedID in
                    jumpHostIDs.append(selectedID)
                }
            }
            .alert("Save Failed", isPresented: Binding(
                get: { keychainSaveError != nil },
                set: { if !$0 { keychainSaveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(keychainSaveError ?? "The server could not be saved.")
            }
        }
    }

    @ViewBuilder
    private var platformForm: some View {
        #if os(macOS)
        Form { formSections }
            .formStyle(.grouped)
        #else
        Form { formSections }
        #endif
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Connection") {
            addTextField("Name", text: $name, field: .name, identifier: "add-server-display-name")
            addTextField("Host", text: $host, field: .host, identifier: "add-server-host")
            serverFormLabeledContent("Port") {
                TextField("Port", text: $port)
                    .terminalNumericInput()
                    .focused($focusedField, equals: .port)
                    .serverFormTextFieldPresentation()
                    .accessibilityIdentifier("add-server-port")
            }
            addTextField("Username", text: $username, field: .username, identifier: "add-server-username")
        }

        Section("Authentication") {
            serverFormLabeledContent("Method") {
                Picker("Method", selection: $authMethod) {
                    ForEach(supportedAuthenticationMethods, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .serverFormControlPresentation()
            }

            if authMethod == .password {
                serverFormLabeledContent("Password") {
                    SecureField("Password", text: $password)
                        .textContentType(.init(rawValue: ""))
                        .focused($focusedField, equals: .password)
                        .serverFormTextFieldPresentation()
                        .accessibilityIdentifier("add-server-password")
                }
            } else if authMethod == .sshKey {
                #if os(macOS)
                serverFormLabeledContent("SSH Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        addSSHKeySelection
                        Button("Add SSH Key", systemImage: "plus.circle") {
                            showingAddSSHKey = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .serverFormControlPresentation()
                }
                #else
                addSSHKeySelection
                Button("Add SSH Key", systemImage: "plus.circle") {
                    showingAddSSHKey = true
                }
                .buttonStyle(.bordered)
                #endif
            }
        }

        Section("Routing") {
            #if os(macOS)
            serverFormLabeledContent("Route") {
                routingEditor.serverFormControlPresentation()
            }
            #else
            routingEditor
            #endif
        }

        Section("Terminal") {
            TerminalInitialSizeEditor(
                usesAppDefault: $usesAppDefaultTerminalSize,
                columns: $initialTerminalColumns,
                rows: $initialTerminalRows,
                appDefault: TerminalGeometry(
                    rows: settingsManager.initialTerminalRows,
                    columns: settingsManager.initialTerminalColumns
                )
            )
        }

        Section("Appearance") {
            #if os(macOS)
            serverFormLabeledContent("Color tag") {
                colorTagPicker.serverFormControlPresentation()
            }
            serverFormLabeledContent("Collections") {
                collectionEditor.serverFormControlPresentation()
            }
            #else
            mobileColorTagEditor
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.headline)
                collectionEditor
            }
            #endif
        }

        Section("Preferences") {
            Toggle("Favorite", systemImage: "heart.fill", isOn: $isFavorite)
        }
    }

    @ViewBuilder
    private var addSSHKeySelection: some View {
        if settingsManager.sshKeys.isEmpty {
            Text("No SSH keys available. Add one to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("SSH Key", selection: $sshKeyID) {
                Text("Select a key").tag(nil as UUID?)
                ForEach(settingsManager.sshKeys) { key in
                    Text("\(key.name) (\(key.keyTypeBadge))").tag(key.id as UUID?)
                }
            }
            .serverFormControlPresentation()
        }
    }

    private var routingEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if jumpHostIDs.isEmpty {
                Text("Direct connection")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(jumpHostIDs.enumerated()), id: \.offset) { index, hopID in
                    if let hop = serverManager.servers.first(where: { $0.id == hopID }) {
                        HStack {
                            Label("Hop \(index + 1): \(hop.name)", systemImage: "\(index + 1).circle.fill")
                            Spacer()
                            Button("Remove hop \(index + 1)", systemImage: "minus.circle.fill") {
                                jumpHostIDs.remove(at: index)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .onMove { from, to in
                    jumpHostIDs.move(fromOffsets: from, toOffset: to)
                }
            }

            Button("Add Jump Host", systemImage: "plus.circle") {
                showingJumpHostPicker = true
            }
        }
    }

    private var colorTagPicker: some View {
        Picker("Color tag", selection: $colorTag) {
            ForEach(ServerColorTag.allCases, id: \.self) { tag in
                Label(tag.rawValue.capitalized, systemImage: "circle.fill")
                    .foregroundStyle(tag.color)
                    .tag(tag)
            }
        }
    }

    private var mobileColorTagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color Tag")
                .font(.headline)
            HStack(spacing: 12) {
                ForEach(ServerColorTag.allCases, id: \.self) { tag in
                    Button {
                        colorTag = tag
                    } label: {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 44, height: 44)
                            .overlay {
                                if colorTag == tag {
                                    Circle().strokeBorder(.white, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 60, minHeight: 60)
                    .contentShape(Circle())
                    .accessibilityLabel("\(tag.rawValue) color")
                    .accessibilityAddTraits(colorTag == tag ? .isSelected : [])
                }
            }
        }
    }

    private var collectionEditor: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag) {
                    tags.removeAll { $0 == tag }
                }
            }

            HStack(spacing: 4) {
                TextField("Add collection", text: $newTag)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .accessibilityIdentifier("add-server-tag")
                    .onSubmit { commitPendingTag() }

                if !newTag.isEmpty {
                    Button("Add collection", systemImage: "plus.circle.fill") {
                        commitPendingTag()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add collection")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
        }
    }

    @ViewBuilder
    private func addTextField(
        _ label: String,
        text: Binding<String>,
        field: Field,
        identifier: String
    ) -> some View {
        serverFormLabeledContent(label) {
            TextField(label, text: text)
                .terminalTextInputDefaults()
                .focused($focusedField, equals: field)
                .serverFormTextFieldPresentation()
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - Save

    private func saveServer() {
        commitPendingTag()

        let server = ServerConfiguration(
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            sshKeyPath: nil,
            sshKeyID: authMethod == .sshKey ? sshKeyID : nil,
            isFavorite: isFavorite,
            colorTag: colorTag,
            tags: tags,
            provenance: provenance,
            jumpHostID: jumpHostIDs.first,
            jumpHostIDs: jumpHostIDs.isEmpty ? nil : jumpHostIDs,
            initialTerminalColumns: usesAppDefaultTerminalSize ? nil : initialTerminalColumns,
            initialTerminalRows: usesAppDefaultTerminalSize ? nil : initialTerminalRows
        )

        do {
            try serverManager.addServerOrThrow(
                server,
                password: authMethod == .password ? password : nil
            )
        } catch {
            Logger.servers.error("Failed to add server transactionally: \(error.localizedDescription)")
            keychainSaveError = "The server was not added: \(error.localizedDescription)"
            return
        }
        dismiss()
    }

    private func commitPendingTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newTag = ""
            return
        }
        if !tags.contains(trimmed) {
            tags.append(trimmed)
        }
        newTag = ""
    }

    private func normalizeSelectedSSHKey() {
        guard authMethod == .sshKey else { return }
        let availableIDs = Set(settingsManager.sshKeys.map(\.id))
        if let selected = sshKeyID, availableIDs.contains(selected) {
            return
        }
        sshKeyID = settingsManager.sshKeys.first?.id
    }
}

// MARK: - Edit Connection View

struct EditServerView: View {
    let server: ServerConfiguration
    @Bindable var serverManager: ServerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthenticationMethod
    @State private var sshKeyID: UUID?
    @State private var password: String = ""
    @State private var colorTag: ServerColorTag
    @State private var tags: [String]
    @State private var isFavorite: Bool
    @State private var jumpHostIDs: [UUID]
    @State private var showingJumpHostPicker: Bool = false
    @State private var usesAppDefaultTerminalSize: Bool
    @State private var initialTerminalColumns: Int
    @State private var initialTerminalRows: Int
    @State private var newTag: String = ""
    @State private var showingAddSSHKey = false
    @State private var keychainSaveError: String?
    @State private var requiresPasswordUpgrade: Bool

    private enum Field: Hashable { case name, host, port, username, password }
    @FocusState private var focusedField: Field?

    init(server: ServerConfiguration, serverManager: ServerManager) {
        self.server = server
        self.serverManager = serverManager

        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _username = State(initialValue: server.username)
        // SSH Agent is not shipped in this release. Existing legacy profiles
        // must choose a supported method before they can be saved again.
        _authMethod = State(initialValue: server.authMethod == .agent ? .password : server.authMethod)
        _sshKeyID = State(initialValue: server.sshKeyID)
        _colorTag = State(initialValue: server.colorTag)
        _tags = State(initialValue: server.tags)
        _isFavorite = State(initialValue: server.isFavorite)
        _jumpHostIDs = State(initialValue: server.resolvedJumpHostIDs)
        let hasTerminalSize = server.initialTerminalColumns != nil
            && server.initialTerminalRows != nil
        _usesAppDefaultTerminalSize = State(initialValue: !hasTerminalSize)
        _initialTerminalColumns = State(
            initialValue: server.initialTerminalColumns ?? TerminalGeometry.default.columns
        )
        _initialTerminalRows = State(
            initialValue: server.initialTerminalRows ?? TerminalGeometry.default.rows
        )
        _requiresPasswordUpgrade = State(initialValue: false)
    }

    private var isFormValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let parsedPort = Int(port), (1...65_535).contains(parsedPort) else {
            return false
        }
        guard usesAppDefaultTerminalSize || TerminalGeometry.contains(
            rows: initialTerminalRows,
            columns: initialTerminalColumns
        ) else { return false }
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return sshKeyID != nil
        case .agent:
            return false
        }
    }

    var body: some View {
        platformEditor
            .onAppear {
                normalizeSelectedSSHKey()
                focusedField = .name
                if authMethod == .password {
                    do {
                        let saved = try serverManager.password(for: server)
                        password = saved
                        requiresPasswordUpgrade = false
                    } catch SecretStoreError.notFound {
                        requiresPasswordUpgrade = true
                    } catch {
                        keychainSaveError = "The saved password could not be read: \(error.localizedDescription)"
                    }
                }
            }
            .onChange(of: authMethod) { _, _ in
                normalizeSelectedSSHKey()
            }
            .onChange(of: settingsManager.sshKeys.map(\.id)) { _, _ in
                normalizeSelectedSSHKey()
            }
            .onChange(of: usesAppDefaultTerminalSize) { _, usesDefault in
                guard !usesDefault else { return }
                initialTerminalColumns = settingsManager.initialTerminalColumns
                initialTerminalRows = settingsManager.initialTerminalRows
            }
    }

    @ViewBuilder
    private var platformEditor: some View {
        #if os(macOS)
        editor
            .frame(
                minWidth: 600,
                idealWidth: 640,
                maxWidth: 680,
                minHeight: 620,
                idealHeight: 720,
                maxHeight: 820
            )
        #else
        editor
        #endif
    }

    private var editor: some View {
        NavigationStack {
            platformForm
            .navigationTitle("Edit Connection")
            .sheet(isPresented: $showingAddSSHKey) {
                AddSSHKeyView()
                    .environment(settingsManager)
            }
            .sheet(isPresented: $showingJumpHostPicker) {
                JumpHostPickerView(
                    servers: serverManager.servers.filter { $0.id != server.id },
                    excludedIDs: Set(jumpHostIDs)
                ) { selectedID in
                    jumpHostIDs.append(selectedID)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .disabled(!isFormValid)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                }
            }
            .alert("Save Failed", isPresented: Binding(
                get: { keychainSaveError != nil },
                set: { if !$0 { keychainSaveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(keychainSaveError ?? "The server changes could not be saved.")
            }
        }
    }

    @ViewBuilder
    private var platformForm: some View {
        #if os(macOS)
        Form { formSections }
            .formStyle(.grouped)
        #else
        Form { formSections }
        #endif
    }

    @ViewBuilder
    private var formSections: some View {
        Section("Connection") {
            editTextField("Name", text: $name, field: .name)
            editTextField("Host", text: $host, field: .host)
            editTextField("Port", text: $port, field: .port)
            editTextField("Username", text: $username, field: .username)
        }

        Section("Authentication") {
            serverFormLabeledContent("Method") {
                Picker("Method", selection: $authMethod) {
                    ForEach(supportedAuthenticationMethods, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .serverFormControlPresentation()
            }

            if authMethod == .password {
                serverFormLabeledContent("Password") {
                    SecureField("Password", text: $password)
                        .textContentType(.init(rawValue: ""))
                        .focused($focusedField, equals: .password)
                        .serverFormTextFieldPresentation()
                }
                if requiresPasswordUpgrade {
                    Label {
                        Text("Re-enter this password once to upgrade it. Earlier releases used an address-based Keychain account shared with glassdb; glas.sh will not import that ambiguous credential.")
                    } icon: {
                        Image(systemName: "key.horizontal")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if authMethod == .sshKey {
                #if os(macOS)
                serverFormLabeledContent("SSH Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        if settingsManager.sshKeys.isEmpty {
                            Text("No SSH keys available. Add one to continue.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("SSH Key", selection: $sshKeyID) {
                                Text("Select a key").tag(nil as UUID?)
                                ForEach(settingsManager.sshKeys) { key in
                                    Text("\(key.name) (\(key.keyTypeBadge))").tag(key.id as UUID?)
                                }
                            }
                            .serverFormControlPresentation()
                        }
                        Button("Add SSH Key", systemImage: "plus.circle") {
                            showingAddSSHKey = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                #else
                if settingsManager.sshKeys.isEmpty {
                    Text("No SSH keys available. Add one to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("SSH Key", selection: $sshKeyID) {
                        Text("Select a key").tag(nil as UUID?)
                        ForEach(settingsManager.sshKeys) { key in
                            Text("\(key.name) (\(key.keyTypeBadge))").tag(key.id as UUID?)
                        }
                    }
                }
                Button("Add SSH Key", systemImage: "plus.circle") {
                    showingAddSSHKey = true
                }
                .buttonStyle(.bordered)
                #endif
            }
        }

        Section("Routing") {
            #if os(macOS)
            serverFormLabeledContent("Route") {
                VStack(alignment: .leading, spacing: 8) {
                    if jumpHostIDs.isEmpty {
                        Text("Direct connection")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(jumpHostIDs.enumerated()), id: \.offset) { index, hopID in
                            if let hop = serverManager.servers.first(where: { $0.id == hopID }) {
                                HStack {
                                    Label("Hop \(index + 1): \(hop.name)", systemImage: "\(index + 1).circle.fill")
                                    Spacer()
                                    Button("Remove hop \(index + 1)", systemImage: "minus.circle.fill") {
                                        jumpHostIDs.remove(at: index)
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.red)
                                }
                            }
                        }
                        .onMove { from, to in
                            jumpHostIDs.move(fromOffsets: from, toOffset: to)
                        }
                    }

                    Button("Add Jump Host", systemImage: "plus.circle") {
                        showingJumpHostPicker = true
                    }
                }
                .serverFormControlPresentation()
            }
            #else
            if jumpHostIDs.isEmpty {
                Text("Direct connection")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(jumpHostIDs.enumerated()), id: \.offset) { index, hopID in
                    if let hop = serverManager.servers.first(where: { $0.id == hopID }) {
                        HStack {
                            Label("Hop \(index + 1): \(hop.name)", systemImage: "\(index + 1).circle.fill")
                            Spacer()
                            Button("Remove hop \(index + 1)", systemImage: "minus.circle.fill") {
                                jumpHostIDs.remove(at: index)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .onMove { from, to in
                    jumpHostIDs.move(fromOffsets: from, toOffset: to)
                }
            }
            Button("Add Jump Host", systemImage: "plus.circle") {
                showingJumpHostPicker = true
            }
            #endif
        }

        Section("Terminal") {
            TerminalInitialSizeEditor(
                usesAppDefault: $usesAppDefaultTerminalSize,
                columns: $initialTerminalColumns,
                rows: $initialTerminalRows,
                appDefault: TerminalGeometry(
                    rows: settingsManager.initialTerminalRows,
                    columns: settingsManager.initialTerminalColumns
                )
            )
        }

        Section("Appearance") {
            #if os(macOS)
            serverFormLabeledContent("Color tag") {
                Picker("Color tag", selection: $colorTag) {
                    ForEach(ServerColorTag.allCases, id: \.self) { tag in
                        Label(tag.rawValue.capitalized, systemImage: "circle.fill")
                            .foregroundStyle(tag.color)
                            .tag(tag)
                    }
                }
                .serverFormControlPresentation()
            }

            serverFormLabeledContent("Collections") {
                collectionEditor.serverFormControlPresentation()
            }
            #else
            VStack(alignment: .leading, spacing: 8) {
                Text("Color Tag")
                    .font(.headline)

                HStack(spacing: 12) {
                    ForEach(ServerColorTag.allCases, id: \.self) { tag in
                        Button {
                            colorTag = tag
                        } label: {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if colorTag == tag {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 60, minHeight: 60)
                        .contentShape(Circle())
                        .accessibilityLabel("\(tag.rawValue) color")
                        .accessibilityAddTraits(colorTag == tag ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.headline)
                collectionEditor
            }
            #endif
        }

        Section("Preferences") {
            Toggle("Favorite", systemImage: "heart.fill", isOn: $isFavorite)
        }
    }

    @ViewBuilder
    private func editTextField(
        _ label: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        serverFormLabeledContent(label) {
            TextField(label, text: text)
                .focused($focusedField, equals: field)
                .serverFormTextFieldPresentation()
        }
    }

    private var collectionEditor: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag) {
                    tags.removeAll { $0 == tag }
                }
            }

            HStack(spacing: 4) {
                TextField("Add collection", text: $newTag)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .onSubmit { commitPendingTag() }

                if !newTag.isEmpty {
                    Button("Add collection", systemImage: "plus.circle.fill") {
                        commitPendingTag()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add collection")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
        }
    }

    private func saveChanges() {
        commitPendingTag()

        var updatedServer = server
        updatedServer.name = name
        updatedServer.host = host
        updatedServer.port = Int(port) ?? 22
        updatedServer.username = username
        updatedServer.authMethod = authMethod
        updatedServer.sshKeyID = authMethod == .sshKey ? sshKeyID : nil
        updatedServer.sshKeyPath = nil
        updatedServer.colorTag = colorTag
        updatedServer.tags = tags
        updatedServer.isFavorite = isFavorite
        updatedServer.jumpHostID = jumpHostIDs.first
        updatedServer.jumpHostIDs = jumpHostIDs.isEmpty ? nil : jumpHostIDs
        updatedServer.initialTerminalColumns = usesAppDefaultTerminalSize ? nil : initialTerminalColumns
        updatedServer.initialTerminalRows = usesAppDefaultTerminalSize ? nil : initialTerminalRows
        do {
            try serverManager.updateServerOrThrow(
                updatedServer,
                password: authMethod == .password ? password : nil
            )
            requiresPasswordUpgrade = false
        } catch {
            Logger.servers.error("Failed to update server transactionally: \(error.localizedDescription)")
            keychainSaveError = "The server changes were not saved: \(error.localizedDescription)"
            return
        }
        dismiss()
    }

    private func commitPendingTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newTag = ""
            return
        }
        if !tags.contains(trimmed) {
            tags.append(trimmed)
        }
        newTag = ""
    }

    private func normalizeSelectedSSHKey() {
        guard authMethod == .sshKey else { return }
        let availableIDs = Set(settingsManager.sshKeys.map(\.id))
        if let selected = sshKeyID, availableIDs.contains(selected) {
            return
        }
        sshKeyID = settingsManager.sshKeys.first?.id
    }
}

private extension View {
    @ViewBuilder
    func serverFormControlPresentation() -> some View {
        #if os(macOS)
        self
            .labelsHidden()
            .frame(width: 340, alignment: .leading)
        #else
        self
        #endif
    }

    @ViewBuilder
    func serverFormTextFieldPresentation() -> some View {
        #if os(macOS)
        self
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 340, alignment: .leading)
        #else
        self
        #endif
    }
}

// MARK: - Supporting Views

struct TagChip: View {
    let tag: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.caption)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
            .accessibilityLabel("Remove \(tag)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag: \(tag)")
    }
}

// Simple flow layout for tags
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                    y: bounds.minY + result.frames[index].minY),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var frames: [CGRect] = []
        var size: CGSize = .zero

        init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > width && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: width, height: y + lineHeight)
        }
    }
}

// MARK: - Jump Host Picker

struct JumpHostPickerView: View {
    let servers: [ServerConfiguration]
    let excludedIDs: Set<UUID>
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var availableServers: [ServerConfiguration] {
        servers.filter { !excludedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if availableServers.isEmpty {
                    Text("No available servers to add as a jump host.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableServers) { server in
                        Button {
                            onSelect(server.id)
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(server.colorTag.color)
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading) {
                                    Text(server.name)
                                    Text("\(server.username)@\(server.host):\(server.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Jump Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
