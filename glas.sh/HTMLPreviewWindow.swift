//
//  HTMLPreviewWindow.swift
//  glas.sh
//
//  Live HTML preview with auto-reload
//

import SwiftUI
import WebKit

struct HTMLPreviewWindow: View {
    let context: HTMLPreviewContext
    @Environment(SessionManager.self) private var sessionManager
    
    @State private var webPage = WebPage()
    @State private var isLoading = false
    @State private var showingURLEditor = false
    @State private var editingURL: String
    @State private var autoReload: Bool
    @State private var reloadTimer: Timer?
    
    init(context: HTMLPreviewContext) {
        self.context = context
        _editingURL = State(initialValue: context.url)
        _autoReload = State(initialValue: context.autoReload)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
            
            Divider()
            
            // Web content
            ZStack {
                WebView(webPage)
                
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                }
            }
        }
        .background(.ultraThinMaterial)
        .onAppear {
            loadURL()
            setupAutoReload()
        }
        .onDisappear {
            stopAutoReload()
        }
        .sheet(isPresented: $showingURLEditor) {
            urlEditorSheet
        }
    }
    
    // MARK: - Toolbar
    
    private var toolbar: some View {
        HStack(spacing: 16) {
            // Navigation controls
            HStack(spacing: 8) {
                Button {
                    // TODO: Implement back when WebPage API is available
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(true) // TODO: Enable when back/forward implemented
                
                Button {
                    // TODO: Implement forward when WebPage API is available
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(true) // TODO: Enable when back/forward implemented
                
                Button {
                    loadURL()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: isLoading)
                }
                .buttonStyle(.bordered)
            }
            
            // URL display
            Button {
                showingURLEditor = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    
                    Text(editingURL)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: .capsule)
            
            // Auto-reload toggle
            Toggle(isOn: $autoReload) {
                Label("Auto Reload", systemImage: "arrow.clockwise.circle")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .onChange(of: autoReload) { _, newValue in
                if newValue {
                    setupAutoReload()
                } else {
                    stopAutoReload()
                }
            }
            
            // Tools menu
            Menu {
                Button {
                    inspectElement()
                } label: {
                    Label("Inspect Element", systemImage: "magnifyingglass")
                }
                
                Button {
                    viewSource()
                } label: {
                    Label("View Source", systemImage: "doc.text")
                }
                
                Divider()
                
                Button {
                    takeScreenshot()
                } label: {
                    Label("Take Screenshot", systemImage: "camera")
                }
                
                Button {
                    exportPDF()
                } label: {
                    Label("Export as PDF", systemImage: "doc.richtext")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    @Namespace private var toolbarNamespace
    
    // MARK: - URL Editor Sheet
    
    private var urlEditorSheet: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("http://localhost:8080", text: $editingURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                Section("Settings") {
                    Toggle("Auto Reload", isOn: $autoReload)
                }
            }
            .navigationTitle("Edit Preview URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingURLEditor = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        loadURL()
                        showingURLEditor = false
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadURL() {
        guard let url = URL(string: editingURL) else { return }
        _ = webPage.load(URLRequest(url: url))
    }
    
    private func setupAutoReload() {
        stopAutoReload()
        
        guard autoReload else { return }
        
        reloadTimer = Timer.scheduledTimer(withTimeInterval: context.reloadInterval, repeats: true) { _ in
            loadURL()
        }
    }
    
    private func stopAutoReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
    }
    
    private func inspectElement() {
        // TODO: Open developer tools when API is available
        print("Inspect element - API not yet implemented")
    }
    
    private func viewSource() {
        // TODO: Implement when WebPage JavaScript API is available
        print("View source - API not yet implemented")
    }
    
    private func takeScreenshot() {
        // TODO: Implement when WebPage snapshot API is available
        print("Screenshot - API not yet implemented")
    }
    
    private func exportPDF() {
        // TODO: Implement when WebPage PDF API is available
        print("Export PDF - API not yet implemented")
    }
}

#Preview {
    let context = HTMLPreviewContext(
        sessionID: UUID(),
        url: "http://localhost:8080"
    )
    
    return HTMLPreviewWindow(context: context)
        .environment(SessionManager())
}
