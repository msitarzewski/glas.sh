//
//  SettingsView.swift
//  glas.sh
//
//  Application settings
//

import SwiftUI

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
        .frame(width: 600, height: 500)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    
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
                Toggle("Save scrollback history", isOn: $settings.saveScrollback)
                    .onChange(of: settings.saveScrollback) { _, _ in
                        settings.saveSettings()
                    }
                
                Stepper("Max scrollback lines: \(settings.maxScrollbackLines)",
                       value: $settings.maxScrollbackLines,
                       in: 1000...100000,
                       step: 1000)
                    .onChange(of: settings.maxScrollbackLines) { _, _ in
                        settings.saveSettings()
                    }
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Terminal Settings

struct TerminalSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @State private var showingThemeEditor = false
    
    var body: some View {
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
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle()
                                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                                }
                            
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Section("Font") {
                Picker("Font Family", selection: .constant("SF Mono")) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Monaco").tag("Monaco")
                    Text("Menlo").tag("Menlo")
                    Text("Courier New").tag("Courier New")
                }
                
                Slider(value: .constant(14), in: 10...24, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("10")
                } maximumValueLabel: {
                    Text("24")
                }
            }
            
            Section("Cursor") {
                Picker("Cursor Style", selection: .constant("Block")) {
                    Text("Block").tag("Block")
                    Text("Underline").tag("Underline")
                    Text("Bar").tag("Bar")
                }
                
                Toggle("Blinking cursor", isOn: .constant(true))
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingThemeEditor) {
            ThemeEditorView()
                .environment(settingsManager)
        }
    }
}

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @Environment(SettingsManager.self) private var settingsManager
    
    var body: some View {
        Form {
            Section("Window") {
                Slider(value: .constant(0.95), in: 0.5...1.0) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Text("50%")
                } maximumValueLabel: {
                    Text("100%")
                }
                
                Toggle("Blur background", isOn: .constant(true))
            }
            
            Section("Glass Effect") {
                Toggle("Interactive glass effects", isOn: .constant(true))
                
                Picker("Glass Tint", selection: .constant("None")) {
                    Text("None").tag("None")
                    Text("Blue").tag("Blue")
                    Text("Purple").tag("Purple")
                    Text("Green").tag("Green")
                }
            }
            
            Section("Layout") {
                Toggle("Show sidebar by default", isOn: .constant(true))
                
                Toggle("Show info panel by default", isOn: .constant(false))
                
                Picker("Sidebar Position", selection: .constant("Left")) {
                    Text("Left").tag("Left")
                    Text("Right").tag("Right")
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
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)
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
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)
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
    
    init() {
        _theme = State(initialValue: TerminalTheme.default)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Colors") {
                    ColorPicker("Background", selection: .constant(.black))
                    ColorPicker("Foreground", selection: .constant(.white))
                    ColorPicker("Cursor", selection: .constant(.green))
                    ColorPicker("Selection", selection: .constant(.blue))
                }
                
                Section("ANSI Colors") {
                    ColorPicker("Red", selection: .constant(.red))
                    ColorPicker("Green", selection: .constant(.green))
                    ColorPicker("Blue", selection: .constant(.blue))
                    ColorPicker("Yellow", selection: .constant(.yellow))
                    ColorPicker("Cyan", selection: .constant(.cyan))
                    ColorPicker("Magenta", selection: .constant(.purple))
                }
            }
            .navigationTitle("Edit Theme")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settingsManager.saveTheme(theme)
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
}
