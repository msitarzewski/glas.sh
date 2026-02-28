//
//  ServerFormViews.swift
//  glas.sh
//
//  Views for adding and editing server configurations
//

import SwiftUI
import GlasSecretStore
import os

// MARK: - Add Server View

struct AddServerView: View {
    @Bindable var serverManager: ServerManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

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

    @State private var showingAddSSHKey = false
    @State private var keychainSaveError: String?

    private var isFormValid: Bool {
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty, Int(port) != nil else {
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
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthenticationMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .textContentType(.init(rawValue: ""))
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
                        }
                        Button {
                            showingAddSSHKey = true
                        } label: {
                            Label("Add SSH Key", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Appearance") {
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
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            if colorTag == tag {
                                                Circle()
                                                    .strokeBorder(.white, lineWidth: 3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.headline)

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
                                        commitPendingTag()
                                    }

                                if !newTag.isEmpty {
                                    Button {
                                        commitPendingTag()
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: .capsule)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $isFavorite) {
                        Label("Favorite", systemImage: "heart.fill")
                    }
                }
            }
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Server") {
                        saveServer()
                    }
                    .disabled(!isFormValid)
                }
            }
            .sheet(isPresented: $showingAddSSHKey) {
                AddSSHKeyView()
                    .environment(settingsManager)
            }
            .alert("Keychain Error", isPresented: Binding(
                get: { keychainSaveError != nil },
                set: { if !$0 { keychainSaveError = nil } }
            )) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Could not save password: \(keychainSaveError ?? "")")
            }
        }
        .onAppear {
            normalizeSelectedSSHKey()
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
            tags: tags
        )

        serverManager.addServer(server)

        // Save password to keychain if using password auth
        if authMethod == .password {
            do {
                try KeychainManager.savePassword(password, for: server)
            } catch {
                Logger.keychain.error("Failed to save password: \(error.localizedDescription)")
                keychainSaveError = error.localizedDescription
                return
            }
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
    @State private var newTag: String = ""
    @State private var showingAddSSHKey = false
    @State private var keychainSaveError: String?

    init(server: ServerConfiguration, serverManager: ServerManager) {
        self.server = server
        self.serverManager = serverManager

        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _username = State(initialValue: server.username)
        _authMethod = State(initialValue: server.authMethod)
        _sshKeyID = State(initialValue: server.sshKeyID)
        _colorTag = State(initialValue: server.colorTag)
        _tags = State(initialValue: server.tags)
        _isFavorite = State(initialValue: server.isFavorite)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    TextField("Username", text: $username)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthenticationMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                            .textContentType(.init(rawValue: ""))
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
                        }
                        Button {
                            showingAddSSHKey = true
                        } label: {
                            Label("Add SSH Key", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Appearance") {
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
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            if colorTag == tag {
                                                Circle()
                                                    .strokeBorder(.white, lineWidth: 3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.headline)

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
                                        commitPendingTag()
                                    }

                                if !newTag.isEmpty {
                                    Button {
                                        commitPendingTag()
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: .capsule)
                        }
                    }
                }

                Section("Preferences") {
                    Toggle(isOn: $isFavorite) {
                        Label("Favorite", systemImage: "heart.fill")
                    }
                }
            }
            .navigationTitle("Edit Server")
            .sheet(isPresented: $showingAddSSHKey) {
                AddSSHKeyView()
                    .environment(settingsManager)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                }
            }
            .alert("Keychain Error", isPresented: Binding(
                get: { keychainSaveError != nil },
                set: { if !$0 { keychainSaveError = nil } }
            )) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Could not save password: \(keychainSaveError ?? "")")
            }
        }
        .onAppear {
            normalizeSelectedSSHKey()
            if authMethod == .password {
                if let saved = try? KeychainManager.retrievePassword(for: server) {
                    password = saved
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

        let originalAuthMethod = server.authMethod

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

        serverManager.updateServer(updatedServer)

        if authMethod == .password, !password.isEmpty {
            do {
                try KeychainManager.savePassword(password, for: updatedServer)
            } catch {
                Logger.keychain.error("Failed to save password: \(error.localizedDescription)")
                keychainSaveError = error.localizedDescription
                return
            }

            // Clean up orphaned keychain entry if connection details changed
            let keyChanged = server.host != host
                || server.port != (Int(port) ?? 22)
                || server.username != username
            if keyChanged {
                try? KeychainManager.deletePassword(for: server)
            }
        } else if originalAuthMethod == .password && authMethod != .password {
            // Auth method changed away from password — remove old entry
            try? KeychainManager.deletePassword(for: server)
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .capsule)
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
