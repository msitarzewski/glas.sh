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

// MARK: - Server Form Entry Points

struct AddServerView: View {
    @Bindable var serverManager: ServerManager
    private let draft: ServerConfiguration?

    init(serverManager: ServerManager, draft: ServerConfiguration? = nil) {
        self.serverManager = serverManager
        self.draft = draft
    }

    var body: some View {
        ServerFormView(mode: .add(draft), serverManager: serverManager)
    }
}

struct EditServerView: View {
    let server: ServerConfiguration
    @Bindable var serverManager: ServerManager

    var body: some View {
        ServerFormView(mode: .edit(server), serverManager: serverManager)
    }
}

// MARK: - Shared Server Form

struct ServerFormView: View {
    enum Mode {
        case add(ServerConfiguration?)
        case edit(ServerConfiguration)

        var sourceConfiguration: ServerConfiguration? {
            switch self {
            case .add(let draft): draft
            case .edit(let server): server
            }
        }

        var editingServer: ServerConfiguration? {
            guard case .edit(let server) = self else { return nil }
            return server
        }

        var isEditing: Bool {
            editingServer != nil
        }

        var isImporting: Bool {
            guard case .add(.some) = self else { return false }
            return true
        }

        var navigationTitle: String {
            if isEditing { return "Edit Connection" }
            return isImporting ? "Import Connection" : "Add Server"
        }

        var confirmationTitle: String {
            if isEditing { return "Save Changes" }
            return isImporting ? "Save Connection" : "Add Server"
        }
    }

    enum FormField: Hashable {
        case name
        case host
        case port
        case username
        case authentication
        case password
        case sshKey
        case terminalSize
    }

    struct ValidationInput {
        let name: String
        let host: String
        let port: String
        let username: String
        let authMethod: AuthenticationMethod
        let password: String
        let sshKeyID: UUID?
        let availableSSHKeyIDs: Set<UUID>
        let usesAppDefaultTerminalSize: Bool
        let initialTerminalColumns: Int
        let initialTerminalRows: Int
    }

    static let orderedFormFields: [FormField] = [
        .name,
        .host,
        .port,
        .username,
        .authentication,
        .password,
        .sshKey,
        .terminalSize
    ]

    static func normalizedEndpointValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    static func validationIssues(for input: ValidationInput) -> [FormField: String] {
        var issues: [FormField: String] = [:]

        if normalizedEndpointValue(input.name).isEmpty {
            issues[.name] = "Enter a name for this connection."
        }
        if normalizedEndpointValue(input.host).isEmpty {
            issues[.host] = "Enter the SSH server hostname or IP address."
        }
        if normalizedEndpointValue(input.username).isEmpty {
            issues[.username] = "Enter the SSH username."
        }
        if Int(input.port).map({ (1...65_535).contains($0) }) != true {
            issues[.port] = "Enter a port from 1 through 65535."
        }

        switch input.authMethod {
        case .password:
            if input.password.isEmpty {
                issues[.password] = "Enter the SSH password."
            }
        case .sshKey:
            guard let sshKeyID = input.sshKeyID,
                  input.availableSSHKeyIDs.contains(sshKeyID) else {
                issues[.sshKey] = "Choose an SSH key that is available to glas.sh."
                break
            }
        case .agent:
            issues[.authentication] = "Choose Password or SSH Key."
        }

        if !input.usesAppDefaultTerminalSize,
           !TerminalGeometry.contains(
               rows: input.initialTerminalRows,
               columns: input.initialTerminalColumns
           ) {
            issues[.terminalSize] = "Choose terminal dimensions within 20 through 500 columns and 8 through 300 rows."
        }

        return issues
    }

    static func nextField(after field: FormField, in authMethod: AuthenticationMethod) -> FormField? {
        switch field {
        case .name: .host
        case .host: .port
        case .port: .username
        case .username:
            authMethod == .sshKey ? .sshKey : .password
        case .authentication, .password, .sshKey, .terminalSize:
            nil
        }
    }

    private let mode: Mode
    @Bindable private var serverManager: ServerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthenticationMethod
    @State private var password: String = ""
    @State private var sshKeyID: UUID?
    @State private var colorTag: ServerColorTag
    @State private var tags: [String]
    @State private var newTag: String = ""
    @State private var isFavorite: Bool
    @State private var jumpHostIDs: [UUID]
    @State private var usesAppDefaultTerminalSize: Bool
    @State private var initialTerminalColumns: Int
    @State private var initialTerminalRows: Int

    @State private var attemptedSave = false
    @State private var touchedFields: Set<FormField> = []
    @State private var showingAddSSHKey = false
    @State private var showingJumpHostPicker = false
    @State private var saveError: String?
    @State private var requiresPasswordUpgrade = false
    @State private var didLoadStoredPassword = false

    @FocusState private var focusedField: FormField?

    init(mode: Mode, serverManager: ServerManager) {
        self.mode = mode
        self.serverManager = serverManager

        let source = mode.sourceConfiguration
        _name = State(initialValue: source?.name ?? "")
        _host = State(initialValue: source?.host ?? "")
        _port = State(initialValue: source.map { String($0.port) } ?? "22")
        _username = State(initialValue: source?.username ?? "")
        _authMethod = State(initialValue: source?.authMethod == .sshKey ? .sshKey : .password)
        _sshKeyID = State(initialValue: source?.sshKeyID)
        _colorTag = State(initialValue: source?.colorTag ?? .blue)
        _tags = State(initialValue: source?.tags ?? [])
        _isFavorite = State(initialValue: source?.isFavorite ?? false)
        _jumpHostIDs = State(initialValue: source?.resolvedJumpHostIDs ?? [])

        let hasTerminalSize = source?.initialTerminalColumns != nil
            && source?.initialTerminalRows != nil
        _usesAppDefaultTerminalSize = State(initialValue: !hasTerminalSize)
        _initialTerminalColumns = State(
            initialValue: source?.initialTerminalColumns ?? TerminalGeometry.default.columns
        )
        _initialTerminalRows = State(
            initialValue: source?.initialTerminalRows ?? TerminalGeometry.default.rows
        )
    }

    private var validationInput: ValidationInput {
        ValidationInput(
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            password: password,
            sshKeyID: sshKeyID,
            availableSSHKeyIDs: Set(settingsManager.sshKeys.map(\.id)),
            usesAppDefaultTerminalSize: usesAppDefaultTerminalSize,
            initialTerminalColumns: initialTerminalColumns,
            initialTerminalRows: initialTerminalRows
        )
    }

    private var validationIssues: [FormField: String] {
        Self.validationIssues(for: validationInput)
    }

    private var isFormValid: Bool {
        validationIssues.isEmpty
    }

    private var identifierPrefix: String {
        mode.isEditing ? "edit-server" : "add-server"
    }

    private var availableJumpHosts: [ServerConfiguration] {
        guard let editingID = mode.editingServer?.id else {
            return serverManager.servers
        }
        return serverManager.servers.filter { $0.id != editingID }
    }

    var body: some View {
        platformEditor
            .onAppear {
                normalizeSelectedSSHKey()
                focusedField = mode.isImporting ? .username : .name
                loadStoredPasswordIfNeeded()
            }
            .onChange(of: name) { _, _ in markTouched(.name) }
            .onChange(of: host) { _, _ in markTouched(.host) }
            .onChange(of: port) { _, _ in markTouched(.port) }
            .onChange(of: username) { _, _ in markTouched(.username) }
            .onChange(of: password) { _, _ in markTouched(.password) }
            .onChange(of: sshKeyID) { _, _ in markTouched(.sshKey) }
            .onChange(of: authMethod) { _, _ in
                markTouched(.authentication)
                markTouched(authMethod == .sshKey ? .sshKey : .password)
                normalizeSelectedSSHKey()
            }
            .onChange(of: settingsManager.sshKeys.map(\.id)) { _, _ in
                normalizeSelectedSSHKey()
            }
            .onChange(of: usesAppDefaultTerminalSize) { _, usesDefault in
                markTouched(.terminalSize)
                guard !usesDefault else { return }
                initialTerminalColumns = settingsManager.initialTerminalColumns
                initialTerminalRows = settingsManager.initialTerminalRows
            }
            .onChange(of: initialTerminalColumns) { _, _ in markTouched(.terminalSize) }
            .onChange(of: initialTerminalRows) { _, _ in markTouched(.terminalSize) }
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
                .navigationTitle(mode.navigationTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(mode.confirmationTitle) {
                            save()
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
                        servers: availableJumpHosts,
                        excludedIDs: Set(jumpHostIDs)
                    ) { selectedID in
                        jumpHostIDs.append(selectedID)
                    }
                }
                .alert("Save Failed", isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(saveError ?? "The server could not be saved.")
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
            formTextField(
                "Name",
                text: $name,
                field: .name,
                identifier: "\(identifierPrefix)-display-name",
                isRequired: true
            )
            formTextField(
                "Host",
                text: $host,
                field: .host,
                identifier: "\(identifierPrefix)-host",
                isRequired: true
            )
            portField
            formTextField(
                "Username",
                text: $username,
                field: .username,
                identifier: "\(identifierPrefix)-username",
                isRequired: true
            )
        }

        Section("Authentication") {
            serverFormLabeledContent("Method") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Method", selection: $authMethod) {
                        ForEach(supportedAuthenticationMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .serverFormControlPresentation()
                    validationMessage(for: .authentication)
                }
            }

            if authMethod == .password {
                passwordField
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
                sshKeyEditor
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
            validationMessage(for: .terminalSize)
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
    private func formTextField(
        _ label: String,
        text: Binding<String>,
        field: FormField,
        identifier: String,
        isRequired: Bool
    ) -> some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                TextField(label, text: text)
                    .terminalTextInputDefaults()
                    .focused($focusedField, equals: field)
                    .serverFormTextFieldPresentation()
                    .accessibilityIdentifier(identifier)
                    .onSubmit { advanceFocus(after: field) }
                validationMessage(for: field)
            }
        } label: {
            requiredFieldLabel(label, isRequired: isRequired)
        }
    }

    private var portField: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Port", text: $port)
                    .terminalNumericInput()
                    .focused($focusedField, equals: .port)
                    .serverFormTextFieldPresentation()
                    .accessibilityIdentifier("\(identifierPrefix)-port")
                    .onSubmit { advanceFocus(after: .port) }
                validationMessage(for: .port)
            }
        } label: {
            requiredFieldLabel("Port", isRequired: false)
        }
    }

    private var passwordField: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                SecureField("Password", text: $password)
                    .textContentType(.init(rawValue: ""))
                    .focused($focusedField, equals: .password)
                    .serverFormTextFieldPresentation()
                    .accessibilityIdentifier("\(identifierPrefix)-password")
                    .onSubmit { advanceFocus(after: .password) }
                validationMessage(for: .password)
            }
        } label: {
            requiredFieldLabel("Password", isRequired: true)
        }
    }

    @ViewBuilder
    private var sshKeyEditor: some View {
        #if os(macOS)
        LabeledContent {
            sshKeyEditorContent
                .serverFormControlPresentation()
        } label: {
            requiredFieldLabel("SSH Key", isRequired: true)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            requiredFieldLabel("SSH Key", isRequired: true)
            sshKeyEditorContent
        }
        #endif
    }

    private var sshKeyEditorContent: some View {
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
            validationMessage(for: .sshKey)
            Button("Add SSH Key", systemImage: "plus.circle") {
                showingAddSSHKey = true
            }
            .buttonStyle(.bordered)
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
                    .accessibilityIdentifier("\(identifierPrefix)-tag")
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
    private func requiredFieldLabel(_ title: String, isRequired: Bool) -> some View {
        if isRequired {
            HStack(spacing: 6) {
                Text(title)
                Text("Required")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), required")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func validationMessage(for field: FormField) -> some View {
        if (attemptedSave || touchedFields.contains(field)),
           let message = validationIssues[field] {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifierPrefix)-\(field)-validation")
                .accessibilityLabel("Error: \(message)")
        }
    }

    private func markTouched(_ field: FormField) {
        touchedFields.insert(field)
    }

    private func advanceFocus(after field: FormField) {
        focusedField = Self.nextField(after: field, in: authMethod)
    }

    private func validateForSave() -> Bool {
        attemptedSave = true
        let issues = validationIssues
        touchedFields.formUnion(issues.keys)
        if let firstInvalidField = Self.orderedFormFields.first(where: { issues[$0] != nil }) {
            switch firstInvalidField {
            case .name, .host, .port, .username, .password:
                focusedField = firstInvalidField
            case .authentication, .sshKey, .terminalSize:
                focusedField = nil
            }
        }
        return issues.isEmpty
    }

    private func save() {
        guard validateForSave(), let parsedPort = Int(port) else { return }
        commitPendingTag()

        let normalizedName = Self.normalizedEndpointValue(name)
        let normalizedHost = Self.normalizedEndpointValue(host)
        let normalizedUsername = Self.normalizedEndpointValue(username)

        do {
            switch mode {
            case .add(let draft):
                let server = ServerConfiguration(
                    name: normalizedName,
                    host: normalizedHost,
                    port: parsedPort,
                    username: normalizedUsername,
                    authMethod: authMethod,
                    sshKeyPath: nil,
                    sshKeyID: authMethod == .sshKey ? sshKeyID : nil,
                    isFavorite: isFavorite,
                    colorTag: colorTag,
                    tags: tags,
                    provenance: draft?.provenance,
                    jumpHostID: jumpHostIDs.first,
                    jumpHostIDs: jumpHostIDs.isEmpty ? nil : jumpHostIDs,
                    initialTerminalColumns: usesAppDefaultTerminalSize ? nil : initialTerminalColumns,
                    initialTerminalRows: usesAppDefaultTerminalSize ? nil : initialTerminalRows
                )
                try serverManager.addServerOrThrow(
                    server,
                    password: authMethod == .password ? password : nil
                )
            case .edit(let original):
                var updatedServer = original
                updatedServer.name = normalizedName
                updatedServer.host = normalizedHost
                updatedServer.port = parsedPort
                updatedServer.username = normalizedUsername
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
                try serverManager.updateServerOrThrow(
                    updatedServer,
                    password: authMethod == .password ? password : nil
                )
                requiresPasswordUpgrade = false
            }
        } catch {
            Logger.servers.error("Failed to save server transactionally: \(error.localizedDescription)")
            if mode.isEditing {
                saveError = "The server changes were not saved: \(error.localizedDescription)"
            } else {
                saveError = "The server was not added: \(error.localizedDescription)"
            }
            return
        }

        dismiss()
    }

    private func loadStoredPasswordIfNeeded() {
        guard !didLoadStoredPassword,
              authMethod == .password,
              let server = mode.editingServer else { return }
        didLoadStoredPassword = true

        do {
            password = try serverManager.password(for: server)
            requiresPasswordUpgrade = false
        } catch SecretStoreError.notFound {
            requiresPasswordUpgrade = true
        } catch {
            saveError = "The saved password could not be read: \(error.localizedDescription)"
        }
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
