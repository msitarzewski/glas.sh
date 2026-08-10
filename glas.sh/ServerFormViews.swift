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

    @ViewBuilder
    func terminalServerFormStyle() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalServerFormControlWidth() -> some View {
        #if os(macOS)
        self.frame(width: 340, alignment: .leading)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalServerFormSheetSize() -> some View {
        #if os(macOS)
        self.frame(
            minWidth: 600,
            idealWidth: 640,
            maxWidth: 680,
            minHeight: 620,
            idealHeight: 720,
            maxHeight: 820
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalServerFormCancelShortcut() -> some View {
        #if os(macOS)
        self.keyboardShortcut(.cancelAction)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalServerFormDefaultShortcut() -> some View {
        #if os(macOS)
        self.keyboardShortcut(.defaultAction)
        #else
        self
        #endif
    }

    @ViewBuilder
    func terminalTagDeleteTarget() -> some View {
        #if os(macOS)
        self.frame(minWidth: 20, minHeight: 20)
        #else
        self.frame(minWidth: 44, minHeight: 44)
        #endif
    }
}

private let supportedAuthenticationMethods: [AuthenticationMethod] = [.password, .sshKey]

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
    }

    private var isFormValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let parsedPort = Int(port), (1...65_535).contains(parsedPort) else {
            return false
        }
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
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .terminalServerFormControlWidth()
                        .accessibilityIdentifier("add-server-display-name")
                    TextField("Host", text: $host)
                        .terminalTextInputDefaults()
                        .focused($focusedField, equals: .host)
                        .terminalServerFormControlWidth()
                        .accessibilityIdentifier("add-server-host")
                    TextField("Port", text: $port)
                        .terminalNumericInput()
                        .focused($focusedField, equals: .port)
                        .terminalServerFormControlWidth()
                        .accessibilityIdentifier("add-server-port")
                    TextField("Username", text: $username)
                        .terminalTextInputDefaults()
                        .focused($focusedField, equals: .username)
                        .terminalServerFormControlWidth()
                        .accessibilityIdentifier("add-server-username")
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(supportedAuthenticationMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .terminalServerFormControlWidth()

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .textContentType(.init(rawValue: ""))
                            .focused($focusedField, equals: .password)
                            .terminalServerFormControlWidth()
                            .accessibilityIdentifier("add-server-password")
                    } else if authMethod == .sshKey {
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
                            .terminalServerFormControlWidth()
                        }
                        Button {
                            showingAddSSHKey = true
                        } label: {
                            Label("Add SSH Key", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Routing") {
                    if jumpHostIDs.isEmpty {
                        Text("Direct connection")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(jumpHostIDs.enumerated()), id: \.offset) { index, hopID in
                            if let hop = serverManager.servers.first(where: { $0.id == hopID }) {
                                HStack {
                                    Label {
                                        Text("Hop \(index + 1): \(hop.name)")
                                    } icon: {
                                        Image(systemName: "\(index + 1).circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                    Spacer()
                                    Button {
                                        jumpHostIDs.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove hop \(index + 1)")
                                }
                            }
                        }
                        .onMove { from, to in
                            jumpHostIDs.move(fromOffsets: from, toOffset: to)
                        }
                    }

                    Button {
                        showingJumpHostPicker = true
                    } label: {
                        Label("Add Jump Host", systemImage: "plus.circle")
                    }
                }

                Section("Appearance") {
                    ServerColorTagSelector(selection: $colorTag)
                    ServerTagsEditor(
                        tags: $tags,
                        newTag: $newTag,
                        textFieldIdentifier: "add-server-tag",
                        onCommit: commitPendingTag
                    )
                }

                Section("Preferences") {
                    Toggle(isOn: $isFavorite) {
                        Label("Favorite", systemImage: "heart.fill")
                    }
                }
            }
            .terminalServerFormStyle()
            .navigationTitle(isPrefilledDraft ? "Import Connection" : "Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .terminalServerFormCancelShortcut()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPrefilledDraft ? "Save Connection" : "Add Server") {
                        saveServer()
                    }
                    .disabled(!isFormValid)
                    .terminalServerFormDefaultShortcut()
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
        .terminalServerFormSheetSize()
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
            jumpHostIDs: jumpHostIDs.isEmpty ? nil : jumpHostIDs
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

// MARK: - Edit Server View

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
        _requiresPasswordUpgrade = State(initialValue: false)
    }

    private var isFormValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let parsedPort = Int(port), (1...65_535).contains(parsedPort) else {
            return false
        }
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
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .terminalServerFormControlWidth()
                    TextField("Host", text: $host)
                        .terminalTextInputDefaults()
                        .focused($focusedField, equals: .host)
                        .terminalServerFormControlWidth()
                    TextField("Port", text: $port)
                        .terminalNumericInput()
                        .focused($focusedField, equals: .port)
                        .terminalServerFormControlWidth()
                    TextField("Username", text: $username)
                        .terminalTextInputDefaults()
                        .focused($focusedField, equals: .username)
                        .terminalServerFormControlWidth()
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(supportedAuthenticationMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .terminalServerFormControlWidth()

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .textContentType(.init(rawValue: ""))
                            .focused($focusedField, equals: .password)
                            .terminalServerFormControlWidth()
                        if requiresPasswordUpgrade {
                            Label {
                                Text("Re-enter this password once to upgrade it. Earlier releases used an address-based Keychain account shared with glassdb; glas.sh will not import that ambiguous credential.")
                            } icon: {
                                Image(systemName: "key.horizontal")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .terminalServerFormControlWidth()
                        }
                    } else if authMethod == .sshKey {
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
                            .terminalServerFormControlWidth()
                        }
                        Button {
                            showingAddSSHKey = true
                        } label: {
                            Label("Add SSH Key", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Routing") {
                    if jumpHostIDs.isEmpty {
                        Text("Direct connection")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(jumpHostIDs.enumerated()), id: \.offset) { index, hopID in
                            if let hop = serverManager.servers.first(where: { $0.id == hopID }) {
                                HStack {
                                    Label {
                                        Text("Hop \(index + 1): \(hop.name)")
                                    } icon: {
                                        Image(systemName: "\(index + 1).circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                    Spacer()
                                    Button {
                                        jumpHostIDs.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove hop \(index + 1)")
                                }
                            }
                        }
                        .onMove { from, to in
                            jumpHostIDs.move(fromOffsets: from, toOffset: to)
                        }
                    }

                    Button {
                        showingJumpHostPicker = true
                    } label: {
                        Label("Add Jump Host", systemImage: "plus.circle")
                    }
                }

                Section("Appearance") {
                    ServerColorTagSelector(selection: $colorTag)
                    ServerTagsEditor(
                        tags: $tags,
                        newTag: $newTag,
                        textFieldIdentifier: "edit-server-tag",
                        onCommit: commitPendingTag
                    )
                }

                Section("Preferences") {
                    Toggle(isOn: $isFavorite) {
                        Label("Favorite", systemImage: "heart.fill")
                    }
                }
            }
            .terminalServerFormStyle()
            .navigationTitle("Edit Server")
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
                    .terminalServerFormCancelShortcut()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(!isFormValid)
                    .terminalServerFormDefaultShortcut()
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
        .terminalServerFormSheetSize()
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

// MARK: - Supporting Views

private struct ServerColorTagSelector: View {
    @Binding var selection: ServerColorTag

    var body: some View {
        #if os(macOS)
        LabeledContent("Color tag") {
            HStack(spacing: 8) {
                colorButtons
            }
            .frame(width: 340, alignment: .leading)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text("Color tag")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 60), spacing: 12)],
                alignment: .leading,
                spacing: 8
            ) {
                colorButtons
            }
        }
        #endif
    }

    @ViewBuilder
    private var colorButtons: some View {
        ForEach(ServerColorTag.allCases, id: \.self) { tag in
            Button {
                selection = tag
            } label: {
                Circle()
                    .fill(tag.color)
                    .frame(width: swatchSize, height: swatchSize)
                    .overlay {
                        if selection == tag {
                            Circle()
                                .strokeBorder(.primary, lineWidth: 2)
                                .padding(2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(minWidth: targetSize, minHeight: targetSize)
            .contentShape(Circle())
            .accessibilityLabel("\(tag.rawValue) color")
            .accessibilityAddTraits(selection == tag ? .isSelected : [])
        }
    }

    private var swatchSize: CGFloat {
        #if os(macOS)
        26
        #else
        44
        #endif
    }

    private var targetSize: CGFloat {
        #if os(macOS)
        32
        #else
        60
        #endif
    }
}

private struct ServerTagsEditor: View {
    @Binding var tags: [String]
    @Binding var newTag: String
    let textFieldIdentifier: String
    let onCommit: () -> Void

    var body: some View {
        #if os(macOS)
        LabeledContent("Tags") {
            editor
                .frame(width: 340, alignment: .leading)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.subheadline.weight(.semibold))
            editor
        }
        #endif
    }

    private var editor: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag) {
                    tags.removeAll { $0 == tag }
                }
            }

            HStack(spacing: 4) {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .frame(width: tagEntryWidth)
                    .accessibilityIdentifier(textFieldIdentifier)
                    .onSubmit(onCommit)

                if !newTag.isEmpty {
                    Button(action: onCommit) {
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

    private var tagEntryWidth: CGFloat {
        #if os(macOS)
        120
        #else
        100
        #endif
    }
}

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
            .terminalTagDeleteTarget()
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
