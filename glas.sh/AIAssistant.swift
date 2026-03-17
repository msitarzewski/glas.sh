//
//  AIAssistant.swift
//  glas.sh
//
//  On-device AI command assistant and error explainer using Foundation Models
//

#if canImport(FoundationModels)
import FoundationModels
#endif
import SwiftUI
import os

// MARK: - Generable Structs

#if canImport(FoundationModels)
@Generable
struct CommandSuggestion {
    @Guide(description: "The exact shell command to run")
    var command: String

    @Guide(description: "Brief explanation of what the command does")
    var explanation: String

    @Guide(description: "Risk level: safe, moderate, or destructive")
    var riskLevel: String
}

@Generable
struct ErrorExplanation {
    @Guide(description: "What went wrong in plain language")
    var problem: String

    @Guide(description: "Shell command to fix the issue, or empty string if no fix available")
    var suggestedFix: String

    @Guide(description: "Why this fix works or why there is no fix")
    var reasoning: String
}

@Generable
struct SessionSummary {
    @Guide(description: "3-5 bullet points of what was accomplished")
    var highlights: String

    @Guide(description: "Notable commands that were run")
    var commandsRun: String

    @Guide(description: "Duration in human-readable format")
    var duration: String

    @Guide(description: "Any errors or issues encountered")
    var issues: String
}
#endif

// MARK: - AIAssistant

@MainActor
@Observable
final class AIAssistant {
    var isAvailable = false
    var isProcessing = false
    var lastSuggestion: (command: String, explanation: String, riskLevel: String)?
    var lastError: (problem: String, suggestedFix: String, reasoning: String)?
    var lastSessionSummary: (highlights: String, commandsRun: String, duration: String, issues: String)?
    var errorMessage: String?

    func checkAvailability() {
        #if canImport(FoundationModels)
        Task {
            let availability = SystemLanguageModel.default.availability
            isAvailable = (availability == .available)
            Logger.ai.info("Foundation Models availability: \(String(describing: availability))")
        }
        #else
        isAvailable = false
        #endif
    }

    func suggestCommand(prompt: String, host: String, username: String, currentDirectory: String?) async {
        #if canImport(FoundationModels)
        guard isAvailable else {
            errorMessage = "AI model not available on this device."
            return
        }

        isProcessing = true
        lastSuggestion = nil
        errorMessage = nil

        do {
            let systemPrompt = """
            You are a shell command assistant for an SSH terminal client. \
            The user is connected to server \(host) as \(username). \
            Current directory: \(currentDirectory ?? "unknown"). \
            Suggest a single shell command based on the user's natural language request. \
            Assess risk: "safe" for read-only commands, "moderate" for modifications, \
            "destructive" for deletions or system changes.
            """
            let session = LanguageModelSession(instructions: systemPrompt)

            let response = try await session.respond(
                to: prompt,
                generating: CommandSuggestion.self
            )

            let result = response.content
            lastSuggestion = (
                command: result.command,
                explanation: result.explanation,
                riskLevel: result.riskLevel
            )
            Logger.ai.info("Command suggestion generated: \(result.command)")
        } catch {
            Logger.ai.error("Command suggestion failed: \(error)")
            errorMessage = "Failed to generate suggestion: \(error.localizedDescription)"
        }

        isProcessing = false
        #endif
    }

    func explainError(terminalContext: [String], host: String, username: String) async {
        #if canImport(FoundationModels)
        guard isAvailable else { return }

        isProcessing = true
        lastError = nil

        do {
            let contextLines = terminalContext.suffix(30).joined(separator: "\n")
            let systemPrompt = """
            You are a terminal error diagnostic assistant. \
            The user is connected to server \(host) as \(username). \
            Analyze the terminal output below and explain what went wrong. \
            If possible, suggest a fix command. Keep explanations concise.
            """
            let session = LanguageModelSession(instructions: systemPrompt)

            let response = try await session.respond(
                to: "Terminal output:\n\(contextLines)",
                generating: ErrorExplanation.self
            )

            let result = response.content
            lastError = (
                problem: result.problem,
                suggestedFix: result.suggestedFix,
                reasoning: result.reasoning
            )
            Logger.ai.info("Error explanation generated")
        } catch {
            Logger.ai.error("Error explanation failed: \(error)")
        }

        isProcessing = false
        #endif
    }

    func summarizeSession(recordingText: String, serverName: String) async {
        #if canImport(FoundationModels)
        guard isAvailable else {
            errorMessage = "AI model not available on this device."
            return
        }

        isProcessing = true
        lastSessionSummary = nil
        errorMessage = nil

        do {
            let systemPrompt = """
            You are a terminal session analyst. Summarize what happened during \
            an SSH session on server "\(serverName)". The recording contains \
            base64-encoded terminal input and output events in asciicast v2 format. \
            Decode and analyze the content to provide a concise summary. \
            Focus on commands run, their results, and any errors encountered.
            """
            let session = LanguageModelSession(instructions: systemPrompt)

            let response = try await session.respond(
                to: recordingText,
                generating: SessionSummary.self
            )

            let result = response.content
            lastSessionSummary = (
                highlights: result.highlights,
                commandsRun: result.commandsRun,
                duration: result.duration,
                issues: result.issues
            )
            Logger.ai.info("Session summary generated for \(serverName)")
        } catch {
            Logger.ai.error("Session summary failed: \(error)")
            errorMessage = "Failed to generate session summary: \(error.localizedDescription)"
        }

        isProcessing = false
        #endif
    }

    func reset() {
        lastSuggestion = nil
        lastError = nil
        lastSessionSummary = nil
        errorMessage = nil
        isProcessing = false
    }
}

// MARK: - Error Detection

func detectErrorInTerminalOutput(_ lines: [String]) -> Bool {
    let errorPatterns = [
        "Error:", "error:", "ERROR:",
        "Permission denied",
        "command not found",
        "fatal:",
        "bash:",
        "zsh:",
        "No such file or directory",
        "Connection refused",
        "Operation not permitted",
        "segmentation fault",
        "Segmentation fault",
        "SIGKILL", "SIGSEGV",
        "panic:",
        "Cannot",
        "cannot",
        "failed",
        "FAILED",
    ]

    for line in lines.suffix(5) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        for pattern in errorPatterns {
            if trimmed.contains(pattern) {
                return true
            }
        }
    }
    return false
}

// MARK: - AI Assistant View

struct AIAssistantView: View {
    let aiAssistant: AIAssistant
    let host: String
    let username: String
    let onRunCommand: (String) -> Void

    @State private var prompt = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(FoundationModels)
                assistantContent
                #else
                ContentUnavailableView(
                    "AI Not Available",
                    systemImage: "cpu",
                    description: Text("Foundation Models requires visionOS 26 or later.")
                )
                #endif
            }
            .navigationTitle("AI Assistant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 440)
    }

    private var assistantContent: some View {
        VStack(spacing: 16) {
            if !aiAssistant.isAvailable {
                ContentUnavailableView(
                    "Model Unavailable",
                    systemImage: "cpu.fill",
                    description: Text("The on-device language model is not available. Check Settings > Apple Intelligence.")
                )
            } else {
                HStack(spacing: 8) {
                    TextField("Describe what you want to do...", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runSuggestion() }

                    Button {
                        runSuggestion()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aiAssistant.isProcessing)
                }
                .padding(.horizontal)

                if aiAssistant.isProcessing {
                    ProgressView("Thinking...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let suggestion = aiAssistant.lastSuggestion {
                    suggestionCard(suggestion)
                } else if let error = aiAssistant.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ContentUnavailableView(
                        "Ask a Question",
                        systemImage: "sparkles",
                        description: Text("Describe what you want to do in natural language, and AI will suggest a shell command.")
                    )
                }
            }

            Spacer()
        }
        .padding(.top, 16)
    }

    private func suggestionCard(_ suggestion: (command: String, explanation: String, riskLevel: String)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Suggested Command")
                    .font(.headline)
                Spacer()
                riskBadge(suggestion.riskLevel)
            }

            Text(suggestion.command)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            Text(suggestion.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    onRunCommand(suggestion.command)
                    dismiss()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = suggestion.command
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func riskBadge(_ level: String) -> some View {
        let color: Color
        switch level.lowercased() {
        case "safe": color = .green
        case "moderate": color = .yellow
        case "destructive": color = .red
        default: color = .gray
        }

        return Text(level.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func runSuggestion() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            await aiAssistant.suggestCommand(
                prompt: text,
                host: host,
                username: username,
                currentDirectory: nil
            )
        }
    }
}

// MARK: - AI Error Card

struct AIErrorCard: View {
    let error: (problem: String, suggestedFix: String, reasoning: String)
    let onRunFix: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error.problem)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !error.suggestedFix.isEmpty {
                Text(error.suggestedFix)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button {
                        onRunFix(error.suggestedFix)
                        onDismiss()
                    } label: {
                        Label("Run Fix", systemImage: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = error.suggestedFix
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(error.reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
