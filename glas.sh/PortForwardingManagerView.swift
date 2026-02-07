//
//  PortForwardingManagerView.swift
//  glas.sh
//
//  Manage SSH port forwarding
//

import SwiftUI

struct PortForwardingManagerView: View {
    @Environment(SessionManager.self) private var sessionManager
    @State private var portForwardManager = PortForwardManager()
    
    @State private var selectedSession: TerminalSession?
    @State private var showingAddForward = false
    
    var body: some View {
        NavigationSplitView {
            // Session list
            List(sessionManager.sessions) { session in
                Button {
                    selectedSession = session
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.server.name)
                            .font(.headline)
                        
                        Text("\(session.server.username)@\(session.server.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: session.state.icon)
                                .font(.caption2)
                            Text(session.state.displayName)
                                .font(.caption2)
                        }
                        .foregroundStyle(session.state.color)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Sessions")
        } detail: {
            if let session = selectedSession {
                forwardsList(for: session)
            } else {
                emptyState
            }
        }
    }
    
    // MARK: - Forwards List
    
    private func forwardsList(for session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port Forwards")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Manage port forwarding for \(session.server.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    showingAddForward = true
                } label: {
                    Label("Add Forward", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            // Forwards list
            if portForwardManager.forwards(for: session.id).isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.forward.square")
                } description: {
                    Text("Create a port forward to access remote services")
                } actions: {
                    Button {
                        showingAddForward = true
                    } label: {
                        Text("Add Port Forward")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(portForwardManager.forwards(for: session.id)) { forward in
                        PortForwardRow(
                            forward: forward,
                            onToggle: {
                                portForwardManager.toggleForward(forward, in: session.id)
                            },
                            onDelete: {
                                portForwardManager.removeForward(forward, from: session.id)
                            }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showingAddForward) {
            AddPortForwardView(
                sessionID: session.id,
                portForwardManager: portForwardManager
            )
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session Selected", systemImage: "arrow.left")
        } description: {
            Text("Select a session to manage port forwards")
        }
    }
}

// MARK: - Port Forward Row

struct PortForwardRow: View {
    let forward: PortForward
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Type indicator
            VStack(alignment: .leading, spacing: 4) {
                Text(forward.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(forward.displayString)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Status and toggle
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(forward.isActive ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(forward.isActive ? "Active" : "Inactive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Toggle("", isOn: Binding(
                    get: { forward.isActive },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - Add Port Forward View

struct AddPortForwardView: View {
    let sessionID: UUID
    @Bindable var portForwardManager: PortForwardManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var forwardType: PortForward.ForwardType = .local
    @State private var localPort: String = ""
    @State private var remoteHost: String = "localhost"
    @State private var remotePort: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Forward Type") {
                    Picker("Type", selection: $forwardType) {
                        ForEach([PortForward.ForwardType.local, .remote, .dynamic], id: \.self) { type in
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                                    .font(.headline)
                                Text(type.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                }
                
                Section("Configuration") {
                    TextField("Local Port", text: $localPort)
                        .keyboardType(.numberPad)
                    
                    if forwardType != .dynamic {
                        TextField("Remote Host", text: $remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        
                        TextField("Remote Port", text: $remotePort)
                            .keyboardType(.numberPad)
                    }
                }
                
                Section {
                    Text(previewString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle("Add Port Forward")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addForward()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
    
    private var previewString: String {
        guard let local = Int(localPort) else {
            return "Enter valid port numbers"
        }
        
        switch forwardType {
        case .local:
            guard let remote = Int(remotePort) else {
                return "Enter valid port numbers"
            }
            return "localhost:\(local) → \(remoteHost):\(remote)"
            
        case .remote:
            guard let remote = Int(remotePort) else {
                return "Enter valid port numbers"
            }
            return "\(remoteHost):\(remote) → localhost:\(local)"
            
        case .dynamic:
            return "SOCKS proxy on localhost:\(local)"
        }
    }
    
    private var isValid: Bool {
        guard let local = Int(localPort), local > 0 && local <= 65535 else {
            return false
        }
        
        if forwardType != .dynamic {
            guard let remote = Int(remotePort), remote > 0 && remote <= 65535 else {
                return false
            }
        }
        
        return true
    }
    
    private func addForward() {
        let forward = PortForward(
            type: forwardType,
            localPort: Int(localPort)!,
            remoteHost: forwardType == .dynamic ? "localhost" : remoteHost,
            remotePort: forwardType == .dynamic ? 0 : Int(remotePort)!
        )
        
        portForwardManager.addForward(forward, to: sessionID)
        dismiss()
    }
}

#Preview {
    PortForwardingManagerView()
        .environment(SessionManager())
}
