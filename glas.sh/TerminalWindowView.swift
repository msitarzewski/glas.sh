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
    
    @State private var showingSearch = false
    @State private var searchQuery: String = ""
    @State private var showingSidebar = true
    @State private var showingInfoPanel = false
    @StateObject private var terminalHostModel = SwiftTermHostModel()
    @State private var toolsExpanded = false
    @State private var sidebarHovered = false
    @State private var sidebarButtonFocusStates: [String: Bool] = [:]
    @State private var sidebarButtonHoverStates: [String: Bool] = [:]
    @State private var sidebarCollapseTask: Task<Void, Never>?
    @FocusState private var sidebarFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                terminalContent
                    .padding(10)

                bottomStatusBar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .padding(.top, 4)
            }
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 62)
            .padding(.trailing, 22)
            .padding(.top, 34)
            .padding(.bottom, 26)
        }
        .ornament(attachmentAnchor: .scene(.leading)) {
            if showingSidebar {
                sidebarOrnament
            }
        }
        .ornament(attachmentAnchor: .scene(.trailing)) {
            if showingInfoPanel {
                infoPanelOrnament
            }
        }
        .ornament(attachmentAnchor: .scene(.top)) {
            toolbarOrnament
        }
        .toolbar {
            toolbarContent
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                terminalHostModel.focus()
            }
        }
        .onChange(of: session.closeWindowNonce) { _, _ in
            dismiss()
        }
    }
    
    // MARK: - Terminal Content
    
    private var terminalContent: some View {
        ZStack {
            settingsManager.currentTheme.background.color
            SwiftTermHostView(
                model: terminalHostModel,
                theme: swiftTermTheme,
                onSendData: { data in
                    session.sendTerminalData(data)
                },
                onResize: { cols, rows in
                    session.updateTerminalGeometry(rows: rows, columns: cols)
                }
            )
            .background(Color.clear)
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
                terminalHostModel.ingest(data: session.terminalInputChunk, nonce: session.terminalInputNonce)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                terminalHostModel.focus()
            }
        }
        .onChange(of: session.terminalInputNonce) { _, nonce in
            terminalHostModel.ingest(data: session.terminalInputChunk, nonce: nonce)
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
    
    // MARK: - Bottom Status

    private var bottomStatusBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.state.color)
                    .frame(width: 8, height: 8)
                Text(session.state.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Divider()
                .frame(height: 12)
            
            Spacer(minLength: 0)

            Text("TERM \(session.server.terminalType)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                showingInfoPanel.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Toolbar Ornament
    
    private var toolbarOrnament: some View {
        HStack(spacing: 20) {
            // Server info
            HStack(spacing: 8) {
                Circle()
                    .fill(session.server.colorTag.color)
                    .frame(width: 8, height: 8)
                
                Text(session.server.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("•")
                    .foregroundStyle(.secondary)
                
                Text("\(session.server.username)@\(session.server.host)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
    }
    
    @Namespace private var toolbarNamespace
    
    // MARK: - Sidebar Ornament
    
    private var sidebarOrnament: some View {
        VStack(spacing: 8) {
            SidebarButton(
                icon: "arrow.forward.square",
                title: "Port Forward",
                compact: !toolsExpanded,
                id: "port-forward",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    openWindow(id: "port-forwarding")
                }
            )
            
            SidebarButton(
                icon: "safari",
                title: "HTML Preview",
                compact: !toolsExpanded,
                id: "html-preview",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    let context = HTMLPreviewContext(
                        sessionID: session.id,
                        url: "http://localhost:8080"
                    )
                    openWindow(id: "html-preview", value: context)
                }
            )
            
            SidebarButton(
                icon: "doc.text",
                title: "SFTP Browser",
                compact: !toolsExpanded,
                id: "sftp-browser",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    // TODO: Open SFTP browser
                }
            )
            
            SidebarButton(
                icon: "terminal",
                title: "Snippets",
                compact: !toolsExpanded,
                id: "snippets",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    // TODO: Show snippets panel
                }
            )
            
            Divider()
                .padding(.vertical, 4)
            
            SidebarButton(
                icon: "magnifyingglass",
                title: "Search",
                compact: !toolsExpanded,
                id: "search",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    showingSearch.toggle()
                }
            )
            
            SidebarButton(
                icon: "trash",
                title: "Clear",
                compact: !toolsExpanded,
                id: "clear",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    session.clearScreen()
                }
            )
            
            Divider()
                .padding(.vertical, 4)
            
            if session.state == .connected {
                SidebarButton(
                    icon: "arrow.clockwise",
                    title: "Reconnect",
                    compact: !toolsExpanded,
                    id: "reconnect",
                    onFocusChange: handleSidebarButtonFocus,
                    onHoverChange: handleSidebarButtonHover,
                    action: {
                        Task {
                            session.disconnect()
                            try? await Task.sleep(for: .seconds(1))
                            await session.connect()
                        }
                    }
                )
            }
            
            SidebarButton(
                icon: "square.split.2x1",
                title: "Split View",
                compact: !toolsExpanded,
                id: "split-view",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    // TODO: Split terminal
                }
            )
            
            SidebarButton(
                icon: "doc.on.doc",
                title: "Duplicate",
                compact: !toolsExpanded,
                id: "duplicate",
                onFocusChange: handleSidebarButtonFocus,
                onHoverChange: handleSidebarButtonHover,
                action: {
                    Task {
                        let _ = await sessionManager.createSession(for: session.server)
                    }
                }
            )
        }
        .frame(width: toolsExpanded ? 214 : 52)
        .padding(toolsExpanded ? 11 : 8)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(
                cornerRadius: toolsExpanded ? 26 : 999,
                style: .continuous
            )
        )
        .focusable()
        .focused($sidebarFocused)
        .onChange(of: sidebarFocused) { _, _ in
            syncToolsExpanded()
        }
        .onHover { hovering in
            sidebarHovered = hovering
            syncToolsExpanded()
        }
    }

    private func handleSidebarButtonFocus(id: String, focused: Bool) {
        if sidebarButtonFocusStates[id] == focused { return }
        sidebarButtonFocusStates[id] = focused
        syncToolsExpanded()
    }

    private func handleSidebarButtonHover(id: String, hovering: Bool) {
        if sidebarButtonHoverStates[id] == hovering { return }
        sidebarButtonHoverStates[id] = hovering
        syncToolsExpanded()
    }

    private var sidebarInteracting: Bool {
        sidebarHovered || sidebarFocused || sidebarButtonFocusStates.values.contains(true) || sidebarButtonHoverStates.values.contains(true)
    }

    private func syncToolsExpanded() {
        sidebarCollapseTask?.cancel()

        if sidebarInteracting {
            withAnimation(.easeInOut(duration: 0.16)) {
                toolsExpanded = true
            }
            return
        }

        sidebarCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !sidebarInteracting else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                toolsExpanded = false
            }
        }
    }

    // MARK: - Info Panel Ornament
    
    private var infoPanelOrnament: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Information")
                .font(.headline)
                .fontWeight(.semibold)
            
            if let systemInfo = session.systemInfo {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Hostname", value: systemInfo.hostname)
                    InfoRow(label: "OS", value: systemInfo.os)
                    InfoRow(label: "Kernel", value: systemInfo.kernel)
                    InfoRow(label: "Uptime", value: systemInfo.uptime)
                    InfoRow(label: "CPU Cores", value: "\(systemInfo.cpuCores)")
                    InfoRow(label: "Memory", value: systemInfo.totalMemory)
                    InfoRow(label: "Architecture", value: systemInfo.architecture)
                }
            } else {
                Text("Fetching system information...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
                .padding(.vertical, 8)
            
            Text("Port Forwards")
                .font(.headline)
                .fontWeight(.semibold)
            
            if session.portForwards.isEmpty {
                Text("No active port forwards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.portForwards) { forward in
                        PortForwardDisplayRow(forward: forward)
                    }
                }
            }
        }
        .frame(width: 280)
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
    }
    
    // MARK: - Toolbar Content
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "connections")
            } label: {
                Label("Connections", systemImage: "server.rack")
            }
        }
    }
}

// MARK: - Supporting Views

struct TerminalLineView: View {
    let line: TerminalLine
    let theme: TerminalTheme
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: theme.fontSize - 2, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(width: 80, alignment: .trailing)
            
            Text(line.text)
                .font(.system(size: theme.fontSize, design: .monospaced))
                .foregroundStyle(colorForLineStyle(line.style))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func colorForLineStyle(_ style: TerminalLine.LineStyle) -> Color {
        switch style {
        case .output: return theme.foreground.color
        case .input: return theme.blue.color
        case .error: return theme.red.color
        case .system: return theme.yellow.color
        case .prompt: return theme.green.color
        }
    }
}

struct SidebarButton: View {
    let icon: String
    let title: String
    var compact: Bool = false
    let id: String
    var onFocusChange: ((String, Bool) -> Void)? = nil
    var onHoverChange: ((String, Bool) -> Void)? = nil
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 0 : 12) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 32 : 30, height: compact ? 32 : 30)
                    .background {
                        if isFocused || isHovered {
                            Circle()
                                .fill(.regularMaterial)
                        }
                    }
                
                if !compact {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? 0 : 12)
            .padding(.vertical, compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        }
        .buttonStyle(.plain)
        .focusable(true)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(id, focused)
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChange?(id, hovering)
        }
        .contentShape(.rect)
        .hoverEffect(.lift)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct PortForwardDisplayRow: View {
    let forward: PortForward
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(forward.isActive ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(forward.type.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text(forward.displayString)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding(.vertical, 4)
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
