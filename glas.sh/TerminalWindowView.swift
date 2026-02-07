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
    @State private var terminalFocused = false
    @State private var toolsExpanded = false
    @State private var sidebarHovered = false
    @State private var sidebarButtonFocused = false
    @State private var lastTerminalGrid: (rows: Int, cols: Int) = (0, 0)
    @State private var terminalViewportSize: CGSize = .zero
    @FocusState private var sidebarFocused: Bool
    @Environment(\.openWindow) private var openWindow
    
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
    }
    
    // MARK: - Terminal Content
    
    private var terminalContent: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let lineHeight = terminalLineHeight

                ZStack(alignment: .topLeading) {
                    settingsManager.currentTheme.background.color

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(renderedAttributedRows.enumerated()), id: \.offset) { _, row in
                            TerminalScreenRowView(
                                text: row,
                                theme: settingsManager.currentTheme,
                                lineHeight: lineHeight
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .clipped()
                .contentShape(.rect)
                .onTapGesture {
                    terminalFocused = true
                }
                .onAppear {
                    terminalFocused = true
                    terminalViewportSize = geometry.size
                    updateTerminalGeometry(for: geometry.size)
                }
                .onChange(of: geometry.size) { _, size in
                    terminalViewportSize = size
                    updateTerminalGeometry(for: size)
                }
                .onChange(of: terminalMetricSignature) { _, _ in
                    updateTerminalGeometry(for: terminalViewportSize)
                }
            }

            TerminalKeyInputBridge(
                isFirstResponder: $terminalFocused,
                onText: { text in
                    session.sendKeyPress(text)
                },
                onBackspace: {
                    session.sendKeyPress("\u{7f}")
                },
                onEnter: {
                    session.sendKeyPress("\n")
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var renderedAttributedRows: [AttributedString] {
        var rows = session.screenStyledRows
        let cursorRow = max(0, session.cursorPosition.row)
        let cursorCol = max(0, session.cursorPosition.col)

        if rows.isEmpty {
            rows = [[
                TerminalStyledCell(
                    scalar: " ",
                    style: TerminalCellStyle(
                        foreground: TerminalRGBColor(red: 229, green: 229, blue: 229),
                        background: TerminalRGBColor(red: 0, green: 0, blue: 0)
                    )
                )
            ]]
        }

        if cursorRow >= rows.count {
            rows.append(contentsOf: Array(repeating: [], count: cursorRow - rows.count + 1))
        }

        if rows[cursorRow].isEmpty {
            rows[cursorRow].append(
                TerminalStyledCell(
                    scalar: " ",
                    style: TerminalCellStyle(
                        foreground: TerminalRGBColor(red: 229, green: 229, blue: 229),
                        background: TerminalRGBColor(red: 0, green: 0, blue: 0)
                    )
                )
            )
        }

        if cursorCol >= rows[cursorRow].count {
            let fillStyle = rows[cursorRow].last?.style ?? TerminalCellStyle(
                foreground: TerminalRGBColor(red: 229, green: 229, blue: 229),
                background: TerminalRGBColor(red: 0, green: 0, blue: 0)
            )
            rows[cursorRow].append(
                contentsOf: Array(
                    repeating: TerminalStyledCell(scalar: " ", style: fillStyle),
                    count: cursorCol - rows[cursorRow].count + 1
                )
            )
        }

        rows[cursorRow][cursorCol].style = TerminalCellStyle(
            foreground: rows[cursorRow][cursorCol].style.background ?? themeBackgroundRGB,
            background: rows[cursorRow][cursorCol].style.foreground
        )

        return rows.map { row in
            var result = AttributedString()
            for cell in row {
                var scalar = AttributedString(cell.scalar)
                scalar.foregroundColor = color(from: cell.style.foreground)
                if let bg = cell.style.background {
                    scalar.backgroundColor = color(from: bg)
                }
                result.append(scalar)
            }
            return result
        }
    }

    private var themeBackgroundRGB: TerminalRGBColor {
        #if canImport(UIKit)
        let uiColor = UIColor(settingsManager.currentTheme.background.color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return TerminalRGBColor(
                red: UInt8(max(0, min(255, Int(red * 255)))),
                green: UInt8(max(0, min(255, Int(green * 255)))),
                blue: UInt8(max(0, min(255, Int(blue * 255))))
            )
        }
        #endif
        return TerminalRGBColor(red: 0, green: 0, blue: 0)
    }

    private func color(from rgb: TerminalRGBColor) -> Color {
        Color(
            red: Double(rgb.red) / 255.0,
            green: Double(rgb.green) / 255.0,
            blue: Double(rgb.blue) / 255.0
        )
    }

    private var terminalLineHeight: CGFloat {
        terminalCellMetrics.lineHeight
    }

    private var terminalCharWidth: CGFloat {
        terminalCellMetrics.charWidth
    }

    private var terminalCellMetrics: (charWidth: CGFloat, lineHeight: CGFloat) {
        let fontSize = max(10, settingsManager.currentTheme.fontSize)
        #if canImport(UIKit)
        let uiFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let measuredWidth = ceil(("W" as NSString).size(withAttributes: [.font: uiFont]).width)
        let measuredLineHeight = ceil(uiFont.lineHeight * settingsManager.currentTheme.lineSpacing)
        return (
            charWidth: max(6, measuredWidth),
            lineHeight: max(12, measuredLineHeight)
        )
        #else
        return (
            charWidth: max(6, fontSize * 0.62),
            lineHeight: max(12, (fontSize * settingsManager.currentTheme.lineSpacing) + 2)
        )
        #endif
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                onFocusChange: handleSidebarButtonFocus,
                action: {
                    openWindow(id: "port-forwarding")
                }
            )
            
            SidebarButton(
                icon: "safari",
                title: "HTML Preview",
                compact: !toolsExpanded,
                onFocusChange: handleSidebarButtonFocus,
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
                onFocusChange: handleSidebarButtonFocus,
                action: {
                    // TODO: Open SFTP browser
                }
            )
            
            SidebarButton(
                icon: "terminal",
                title: "Snippets",
                compact: !toolsExpanded,
                onFocusChange: handleSidebarButtonFocus,
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
                onFocusChange: handleSidebarButtonFocus,
                action: {
                    showingSearch.toggle()
                }
            )
            
            SidebarButton(
                icon: "trash",
                title: "Clear",
                compact: !toolsExpanded,
                onFocusChange: handleSidebarButtonFocus,
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
                    onFocusChange: handleSidebarButtonFocus,
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
                onFocusChange: handleSidebarButtonFocus,
                action: {
                    // TODO: Split terminal
                }
            )
            
            SidebarButton(
                icon: "doc.on.doc",
                title: "Duplicate",
                compact: !toolsExpanded,
                onFocusChange: handleSidebarButtonFocus,
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
        .onChange(of: sidebarFocused) { _, focused in
            syncToolsExpanded(focusedState: focused)
        }
        .onHover { hovering in
            sidebarHovered = hovering
            syncToolsExpanded()
        }
    }

    private func handleSidebarButtonFocus(_ focused: Bool) {
        sidebarButtonFocused = focused
        syncToolsExpanded()
    }

    private func syncToolsExpanded(focusedState: Bool? = nil) {
        let isFocused = focusedState ?? sidebarFocused
        let shouldExpand = sidebarHovered || sidebarButtonFocused || isFocused
        withAnimation(.easeInOut(duration: 0.16)) {
            toolsExpanded = shouldExpand
        }
    }

    private func updateTerminalGeometry(for size: CGSize) {
        let terminalPaddingX: CGFloat = 24
        let terminalPaddingY: CGFloat = 24
        let availableWidth = max(100, size.width - terminalPaddingX)
        let availableHeight = max(80, size.height - terminalPaddingY)
        let charWidth = terminalCharWidth
        let lineHeight = terminalLineHeight

        let cols = max(20, Int(floor(availableWidth / charWidth)))
        let rows = max(8, Int(floor(availableHeight / lineHeight)))
        guard rows != lastTerminalGrid.rows || cols != lastTerminalGrid.cols else { return }

        lastTerminalGrid = (rows: rows, cols: cols)
        session.updateTerminalGeometry(rows: rows, columns: cols)
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

extension TerminalWindowView {
    private var terminalMetricSignature: Int {
        let font = Int(settingsManager.currentTheme.fontSize * 100)
        let spacing = Int(settingsManager.currentTheme.lineSpacing * 100)
        return (font * 10_000) + spacing
    }
}

#if canImport(UIKit)
struct TerminalKeyInputBridge: UIViewRepresentable {
    @Binding var isFirstResponder: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onEnter: () -> Void

    func makeUIView(context: Context) -> TerminalKeyInputView {
        let view = TerminalKeyInputView()
        view.onText = onText
        view.onBackspace = onBackspace
        view.onEnter = onEnter
        return view
    }

    func updateUIView(_ uiView: TerminalKeyInputView, context: Context) {
        uiView.onText = onText
        uiView.onBackspace = onBackspace
        uiView.onEnter = onEnter

        if isFirstResponder, uiView.window != nil, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

final class TerminalKeyInputView: UIView, UIKeyInput, UITextInputTraits {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEnter: (() -> Void)?

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default
    var textContentType: UITextContentType! = nil
    var autocapitalizationType: UITextAutocapitalizationType = .none

    override var canBecomeFirstResponder: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            onEnter?()
        } else {
            onText?(text)
        }
    }

    func deleteBackward() {
        onBackspace?()
    }
}
#endif

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

struct TerminalScreenRowView: View {
    let text: AttributedString
    let theme: TerminalTheme
    var lineHeight: CGFloat? = nil
    
    var body: some View {
        Text(text)
            .font(.system(size: theme.fontSize, design: .monospaced))
            .foregroundStyle(theme.foreground.color)
            .textSelection(.enabled)
            .lineLimit(1)
            .allowsTightening(false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: lineHeight, alignment: .topLeading)
    }
}

struct SidebarButton: View {
    let icon: String
    let title: String
    var compact: Bool = false
    var onFocusChange: ((Bool) -> Void)? = nil
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 0 : 12) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 32 : 30, height: compact ? 32 : 30)
                    .background(.regularMaterial, in: Circle())
                
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
            onFocusChange?(focused)
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
