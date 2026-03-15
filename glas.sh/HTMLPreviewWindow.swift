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
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
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
            Button {
                loadURL()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: isLoading)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reload")
            
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
            .background(.regularMaterial, in: .capsule)
            
            Toggle(isOn: $autoReload) {
                Label("Auto Reload", systemImage: "arrow.clockwise.circle")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityLabel("Auto reload")
            .accessibilityValue(autoReload ? "On" : "Off")
            .onChange(of: autoReload) { _, newValue in
                if newValue {
                    setupAutoReload()
                } else {
                    stopAutoReload()
                }
            }
            
        }
        .padding()
    }
    
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
    
}

#Preview {
    let context = HTMLPreviewContext(
        sessionID: UUID(),
        url: "http://localhost:8080"
    )
    
    return HTMLPreviewWindow(context: context)
        .environment(SessionManager())
}
