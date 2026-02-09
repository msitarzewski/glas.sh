//
//  ServerFormViews.swift
//  glas.sh
//
//  Views for adding and editing server configurations
//

import SwiftUI

// MARK: - Add Server View

struct AddServerView: View {
    @Bindable var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: AuthenticationMethod = .password
    @State private var password: String = ""
    @State private var sshKeyPath: String = ""
    @State private var colorTag: ServerColorTag = .blue
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var isFavorite: Bool = false
    
    @State private var currentStep = 0
    @State private var showingValidation = false
    
    private let steps = ["Connection", "Authentication", "Options"]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                
                // Step content
                stepContent
                    .padding()
                
                Spacer()
                
                // Navigation buttons
                navigationButtons
            }
            .background(.regularMaterial)
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 0) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    // Step circle
                    ZStack {
                        Circle()
                            .fill(index <= currentStep ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(width: 32, height: 32)
                        
                        if index < currentStep {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(index == currentStep ? .white : .secondary)
                        }
                    }
                    
                    // Connecting line
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(index < currentStep ? Color.blue : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Step Content
    
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            connectionStep
        case 1:
            authenticationStep
        case 2:
            optionsStep
        default:
            EmptyView()
        }
    }
    
    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection Details")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Enter the basic connection information for your server")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Display Name", icon: "tag.fill") {
                    TextField("My Development Server", text: $name)
                }
                
                FormField(label: "Host", icon: "network") {
                    TextField("server.example.com or 192.168.1.100", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                FormField(label: "Port", icon: "number") {
                    TextField("22", text: $port)
                        .frame(width: 100)
                }
                
                FormField(label: "Username", icon: "person.fill") {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }
    
    private var authenticationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Authentication")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Choose how you'll authenticate with the server")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                Picker("Method", selection: $authMethod) {
                    ForEach(AuthenticationMethod.allCases, id: \.self) { method in
                        Label {
                            Text(method.displayName)
                        } icon: {
                            Image(systemName: method.icon)
                        }
                        .tag(method)
                    }
                }
                .pickerStyle(.segmented)
                
                switch authMethod {
                case .password:
                    FormField(label: "Password", icon: "key.fill") {
                        SecureField("Enter password", text: $password)
                    }
                    
                    Text("Your password will be securely stored in the Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    
                case .sshKey:
                    FormField(label: "SSH Key Path", icon: "key.radiowaves.forward.fill") {
                        TextField("~/.ssh/id_rsa", text: $sshKeyPath)
                            .textInputAutocapitalization(.never)
                    }
                    
                    Button {
                        // TODO: Show file picker
                    } label: {
                        Label("Browse...", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    
                case .agent:
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Will use SSH agent for authentication")
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                }
            }
        }
    }
    
    private var optionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Options")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Customize the appearance and behavior")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                // Color tag
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
                
                // Tags
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
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)
                    }
                }
                
                // Favorite toggle
                Toggle(isOn: $isFavorite) {
                    Label {
                        Text("Add to Favorites")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
    
    // MARK: - Navigation Buttons
    
    private var navigationButtons: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    withAnimation {
                        currentStep -= 1
                        showingValidation = false
                    }
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
            
            Button(currentStep == steps.count - 1 ? "Add Server" : "Continue") {
                if currentStep == steps.count - 1 {
                    saveServer()
                } else {
                    if validateCurrentStep() {
                        withAnimation {
                            currentStep += 1
                            showingValidation = false
                        }
                    } else {
                        showingValidation = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!validateCurrentStep())
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Validation
    
    private func validateCurrentStep() -> Bool {
        switch currentStep {
        case 0:
            return !name.isEmpty && !host.isEmpty && !username.isEmpty && Int(port) != nil
        case 1:
            switch authMethod {
            case .password:
                return !password.isEmpty
            case .sshKey:
                return !sshKeyPath.isEmpty
            case .agent:
                return true
            }
        case 2:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Save
    
    private func saveServer() {
        let server = ServerConfiguration(
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            sshKeyPath: authMethod == .sshKey ? sshKeyPath : nil,
            isFavorite: isFavorite,
            colorTag: colorTag,
            tags: tags
        )
        
        serverManager.addServer(server)
        
        // Save password to keychain if using password auth
        if authMethod == .password {
            try? KeychainManager.savePassword(password, for: server)
        }
        
        dismiss()
    }
}

// MARK: - Edit Server View

struct EditServerView: View {
    let server: ServerConfiguration
    @Bindable var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var colorTag: ServerColorTag
    @State private var tags: [String]
    @State private var isFavorite: Bool
    @State private var newTag: String = ""
    
    init(server: ServerConfiguration, serverManager: ServerManager) {
        self.server = server
        self.serverManager = serverManager
        
        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _username = State(initialValue: server.username)
        _colorTag = State(initialValue: server.colorTag)
        _tags = State(initialValue: server.tags)
        _isFavorite = State(initialValue: server.isFavorite)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    FormField(label: "Name", icon: "tag.fill") {
                        TextField("Server name", text: $name)
                    }
                    
                    FormField(label: "Host", icon: "network") {
                        TextField("Hostname", text: $host)
                    }
                    
                    FormField(label: "Port", icon: "number") {
                        TextField("Port", text: $port)
                    }
                    
                    FormField(label: "Username", icon: "person.fill") {
                        TextField("Username", text: $username)
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
        }
    }
    
    private func saveChanges() {
        var updatedServer = server
        updatedServer.name = name
        updatedServer.host = host
        updatedServer.port = Int(port) ?? 22
        updatedServer.username = username
        updatedServer.colorTag = colorTag
        updatedServer.tags = tags
        updatedServer.isFavorite = isFavorite
        
        serverManager.updateServer(updatedServer)
        dismiss()
    }
}

// MARK: - Supporting Views

struct FormField<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(label)
                    .font(.headline)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
            }
            
            content()
                .textFieldStyle(.roundedBorder)
        }
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
