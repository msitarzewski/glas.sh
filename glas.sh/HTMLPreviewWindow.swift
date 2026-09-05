#if DEBUG
//
//  HTMLPreviewWindow.swift
//  glas.sh
//
//  Live HTML preview with auto-reload
//

import SwiftUI
import WebKit
import os

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
        NavigationStack {
            ZStack {
                WebView(webPage)
                
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("HTML Preview")
            .toolbar { previewToolbar }
        }
        #if os(visionOS)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
        #endif
        .onAppear {
            loadURL()
            setupAutoReload()
        }
        .onDisappear {
            stopAutoReload()
        }
        .onChange(of: autoReload) { _, newValue in
            if newValue {
                setupAutoReload()
            } else {
                stopAutoReload()
            }
        }
        .sheet(isPresented: $showingURLEditor) {
            urlEditorSheet
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                showingURLEditor = true
            } label: {
                Label {
                    Text(editingURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "link")
                }
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Edit preview URL")
            .accessibilityValue(editingURL)
            .help("Edit preview URL")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                loadURL()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: isLoading)
            }
            .help("Reload preview")

            Toggle(isOn: $autoReload) {
                Label("Auto Reload", systemImage: "arrow.clockwise.circle")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Auto reload")
            .accessibilityValue(autoReload ? "On" : "Off")
            .help("Auto reload preview")
        }
    }
    
    // MARK: - URL Editor Sheet
    
    private var urlEditorSheet: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("http://localhost:8080", text: $editingURL)
                        .terminalTextInputDefaults()
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
        
        let reload: @MainActor @Sendable () -> Void = { loadURL() }
        reloadTimer = Timer.scheduledTimer(withTimeInterval: context.reloadInterval, repeats: true) { _ in
            Task { @MainActor in reload() }
        }
    }
    
    private func stopAutoReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
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
#endif
