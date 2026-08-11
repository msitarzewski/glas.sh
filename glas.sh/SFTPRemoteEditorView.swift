//
//  SFTPRemoteEditorView.swift
//  glas.sh
//
//  Consumer-owned presentation for editing bytes transported by SFTPBrowserView.
//

import SwiftUI
import UniformTypeIdentifiers
import Observation
import GlassEditorCore
import GlassEditorUI

struct SFTPRemoteFileObservation: Sendable {
    let data: Data
    let stat: RemoteStat
    let digest: ContentDigest
}

struct SFTPRemoteConflictPrompt: Identifiable, Sendable {
    let id = UUID()
    let state: ConflictState
    let resolutions: [ConflictResolution]
    let observation: SFTPRemoteFileObservation?
}

@MainActor
@Observable
final class SFTPRemoteEditorDocument: Identifiable {
    let id = UUID()
    let filename: String
    let remotePath: String
    let model: GlassEditorModel
    var remoteSession: RemoteDocumentSession
    var isWorking = false
    var statusMessage: String?
    var errorMessage: String?
    var conflictPrompt: SFTPRemoteConflictPrompt?

    init(
        filename: String,
        remotePath: String,
        model: GlassEditorModel,
        remoteSession: RemoteDocumentSession
    ) {
        self.filename = filename
        self.remotePath = remotePath
        self.model = model
        self.remoteSession = remoteSession
    }

    func surfaceConflict(_ state: ConflictState, observation: SFTPRemoteFileObservation?) {
        model.conflictState = state
        let resolutions = ConflictPrompt.availableResolutions(
            for: state,
            origin: model.snapshot.origin
        )
        conflictPrompt = resolutions.isEmpty
            ? nil
            : SFTPRemoteConflictPrompt(
                state: state,
                resolutions: resolutions,
                observation: observation
            )
    }
}

struct SFTPRemoteEditorView: View {
    let document: SFTPRemoteEditorDocument
    let surfaceCondition: SurfaceCondition
    let save: @MainActor (_ authorizedObservation: SFTPRemoteFileObservation?) async -> Void
    let checkRemote: @MainActor () async -> Void
    let resolveConflict: @MainActor (
        _ resolution: ConflictResolution,
        _ observation: SFTPRemoteFileObservation?
    ) async -> Void
    let localCopySaved: @MainActor () async -> Void
    let close: @MainActor () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCloseConfirmation = false
    @State private var showingLocalExporter = false
    @State private var localExportDocument: SFTPRemoteEditorExportDocument?

    var body: some View {
        @Bindable var document = document

        NavigationStack {
            GlassEditorView(model: document.model)
                .navigationTitle(document.filename)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            requestClose()
                        }
                        .disabled(document.isWorking)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save") {
                            Task { await save(nil) }
                        }
                        .disabled(!document.model.isDirty || document.isWorking)
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if document.isWorking || document.statusMessage != nil {
                        statusBar
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #endif
        .interactiveDismissDisabled(document.model.isDirty || document.isWorking)
        .onAppear {
            document.model.updateSurface(surfaceCondition)
        }
        .onChange(of: surfaceCondition) { _, newValue in
            document.model.updateSurface(newValue)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, !document.isWorking else { return }
            Task { await checkRemote() }
        }
        .confirmationDialog(
            conflictTitle,
            isPresented: conflictBinding,
            titleVisibility: .visible
        ) {
            if let prompt = document.conflictPrompt {
                ForEach(prompt.resolutions, id: \.self) { resolution in
                    conflictButton(for: resolution, observation: prompt.observation)
                }
            }
        } message: {
            Text(conflictMessage)
        }
        .alert("Discard Unsaved Changes?", isPresented: $showingCloseConfirmation) {
            Button("Discard Changes", role: .destructive) { close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your unsaved edits to \(document.filename) will be lost.")
        }
        .alert("Remote Editor", isPresented: errorBinding) {
            Button("OK") { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "The operation could not be completed.")
        }
        .fileExporter(
            isPresented: $showingLocalExporter,
            document: localExportDocument,
            contentType: .data,
            defaultFilename: document.filename
        ) { result in
            switch result {
            case .success:
                Task { await localCopySaved() }
            case .failure(let error):
                document.errorMessage = "The local copy could not be saved: \(error.localizedDescription)"
            }
            localExportDocument = nil
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if document.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(document.statusMessage ?? "Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { document.conflictPrompt != nil },
            set: { isPresented in
                if !isPresented { document.conflictPrompt = nil }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { document.errorMessage != nil },
            set: { isPresented in
                if !isPresented { document.errorMessage = nil }
            }
        )
    }

    private var conflictTitle: String {
        switch document.model.conflictState {
        case .noConflict:
            return "Remote File"
        case .remoteChangedLocalClean:
            return "Remote File Changed"
        case .remoteChangedLocalDirty:
            return "Conflicting Changes"
        case .indeterminate:
            return "Remote Status Unknown"
        }
    }

    private var conflictMessage: String {
        switch document.model.conflictState {
        case .noConflict:
            return "The remote file matches this editor."
        case .remoteChangedLocalClean:
            return "The remote file changed after it was opened. Reload it or keep the current view without overwriting the newer remote content."
        case .remoteChangedLocalDirty:
            return "Both this editor and the remote file changed. Choose which work to preserve. Nothing will be overwritten automatically."
        case .indeterminate:
            return "glas.sh could not prove that the remote file is unchanged. Choose how to proceed; nothing will be overwritten automatically."
        }
    }

    @ViewBuilder
    private func conflictButton(
        for resolution: ConflictResolution,
        observation: SFTPRemoteFileObservation?
    ) -> some View {
        switch resolution {
        case .overwriteRemote:
            Button("Overwrite Remote", role: .destructive) {
                document.conflictPrompt = nil
                Task { await save(observation) }
            }
        case .discardLocalAndReload:
            Button("Discard Local Changes and Reload", role: .destructive) {
                document.conflictPrompt = nil
                Task { await resolveConflict(resolution, observation) }
            }
        case .saveLocalCopy:
            Button("Save Local Copy…") {
                beginLocalExport()
            }
        case .keepEditing:
            Button("Keep Editing", role: .cancel) {
                document.conflictPrompt = nil
                Task { await resolveConflict(resolution, observation) }
            }
        }
    }

    private func beginLocalExport() {
        do {
            let data = try EncodingDetector.encode(
                document.model.text,
                as: document.model.snapshot.encoding
            )
            localExportDocument = SFTPRemoteEditorExportDocument(data: data)
            showingLocalExporter = true
        } catch {
            document.errorMessage = error.localizedDescription
        }
    }

    private func requestClose() {
        if document.model.isDirty {
            showingCloseConfirmation = true
        } else {
            close()
        }
    }
}

private struct SFTPRemoteEditorExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
