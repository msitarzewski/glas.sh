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
#if canImport(AppKit)
import AppKit
#endif

struct CommandSuggestion {
    var command: String
    var explanation: String
    var riskLevel: String
}

struct ErrorExplanation {
    var problem: String
    var suggestedFix: String
    var reasoning: String
}

enum AIResponseParser {
    private static let maximumResponseBytes = 65_536
    private static let maximumSectionBytes = 32_768
    private static let allowedRiskLevels: Set<String> = ["safe", "moderate", "destructive"]

    static func commandSuggestion(from response: String) -> CommandSuggestion? {
        guard let values = sections(
            in: response,
            labels: ["COMMAND", "EXPLANATION", "RISK"]
        ) else { return nil }
        guard let command = values["COMMAND"], !command.isEmpty,
              let explanation = values["EXPLANATION"], !explanation.isEmpty,
              let riskValue = values["RISK"]?.lowercased(),
              allowedRiskLevels.contains(riskValue),
              !command.contains("\0")
        else { return nil }

        return CommandSuggestion(
            command: command,
            explanation: explanation,
            riskLevel: riskValue
        )
    }

    static func errorExplanation(from response: String) -> ErrorExplanation? {
        guard let values = sections(
            in: response,
            labels: ["PROBLEM", "FIX", "REASONING"]
        ) else { return nil }
        guard let problem = values["PROBLEM"], !problem.isEmpty,
              let suggestedFix = values["FIX"],
              let reasoning = values["REASONING"], !reasoning.isEmpty
        else { return nil }

        return ErrorExplanation(
            problem: problem,
            suggestedFix: suggestedFix,
            reasoning: reasoning
        )
    }

    private static func sections(in response: String, labels: [String]) -> [String: String]? {
        guard response.utf8.count <= maximumResponseBytes,
              !response.contains("```") else { return nil }

        var linesByLabel: [String: [String]] = [:]
        var currentLabel: String?
        var nextLabelIndex = 0

        let normalized = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let uppercased = trimmed.uppercased()

            if let label = labels.first(where: { uppercased.hasPrefix("\($0):") }) {
                guard nextLabelIndex < labels.count,
                      label == labels[nextLabelIndex],
                      linesByLabel[label] == nil else { return nil }
                nextLabelIndex += 1
                currentLabel = label
                let colonIndex = trimmed.index(trimmed.startIndex, offsetBy: label.count)
                let valueStart = trimmed.index(after: colonIndex)
                let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
                linesByLabel[label] = [value]
            } else if let currentLabel {
                linesByLabel[currentLabel, default: []].append(line)
            }
        }

        guard nextLabelIndex == labels.count else { return nil }
        let values = linesByLabel.mapValues { lines in
            lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.values.allSatisfy({ $0.utf8.count <= maximumSectionBytes }) else {
            return nil
        }
        return values
    }
}

// MARK: - Deterministic Command Policy

struct GeneratedCommandAssessment: Equatable {
    let requiresConfirmation: Bool
    let isExecutable: Bool
    let reasons: [String]

    var label: String { requiresConfirmation ? "Review required" : "Read-only" }
}

struct GeneratedCommandConfirmation: Equatable {
    let exactCommand: String
    let assessment: GeneratedCommandAssessment

    init(command: String) {
        exactCommand = command
        assessment = GeneratedCommandPolicy.assess(command)
    }
}

enum GeneratedCommandPolicy {
    private static let safeUtilities: Set<String> = [
        "pwd", "ls", "cat", "head", "tail", "less", "more", "grep", "rg",
        "find", "stat", "file", "du", "df", "ps", "whoami", "id", "uname",
        "date", "printenv", "which", "type", "man", "hostname", "uptime",
    ]
    private static let destructiveUtilities: Set<String> = [
        "rm", "rmdir", "mv", "dd", "mkfs", "diskutil", "shutdown", "reboot",
        "halt", "kill", "killall", "pkill", "chmod", "chown", "chgrp", "truncate",
    ]
    private static let privilegeUtilities: Set<String> = ["sudo", "su", "doas"]
    private static let credentialUtilities: Set<String> = [
        "passwd", "security", "ssh-keygen", "gpg", "keychain", "secret-tool",
    ]
    private static let networkUtilities: Set<String> = [
        "curl", "wget", "nc", "netcat", "socat", "scp", "sftp", "ssh", "rsync",
    ]
    private static let interpreterUtilities: Set<String> = [
        "sh", "bash", "zsh", "fish", "eval", "exec", "xargs", "osascript",
        "python", "python3", "ruby", "perl", "node",
    ]

    static func assess(_ command: String) -> GeneratedCommandAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GeneratedCommandAssessment(
                requiresConfirmation: true,
                isExecutable: false,
                reasons: ["Empty or unclassified command"]
            )
        }

        var reasons: [String] = []
        let containsDisallowedUnicode = command.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format:
                return true
            default:
                return false
            }
        }
        if containsDisallowedUnicode {
            reasons.append("Blocked: control or invisible Unicode formatting character")
        }
        let controlSyntax = ["\n", "\r", ";", "&&", "||", "|", ">", "<", "`", "$(", "${"]
        if controlSyntax.contains(where: command.contains) {
            reasons.append("Shell control, redirection, or substitution syntax")
        }

        let rawTokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let utilities = rawTokens.map { token -> String in
            let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\"(){}[]"))
            return (stripped as NSString).lastPathComponent.lowercased()
        }
        if let utility = utilities.first {
            if destructiveUtilities.contains(utility) {
                reasons.append("Destructive or system-modifying utility")
            } else if privilegeUtilities.contains(utility) {
                reasons.append("Privilege escalation")
            } else if credentialUtilities.contains(utility) {
                reasons.append("Credential or key operation")
            } else if networkUtilities.contains(utility) {
                reasons.append("Network transfer or remote execution")
            } else if interpreterUtilities.contains(utility) {
                reasons.append("Interpreter or indirect execution")
            } else if utility == "git" {
                let readOnlyGitActions: Set<String> = ["status", "log", "diff", "show", "branch"]
                if utilities.count < 2 || !readOnlyGitActions.contains(utilities[1]) {
                    reasons.append("Potentially modifying git operation")
                }
            } else if utility == "find" {
                if utilities.contains("-delete") || utilities.contains("-exec") || utilities.contains("-execdir") {
                    reasons.append("Modifying or indirect find action")
                }
            } else if !safeUtilities.contains(utility) {
                reasons.append("Unclassified command")
            }
        }

        if utilities.dropFirst().contains(where: destructiveUtilities.contains) {
            reasons.append("Destructive utility appears in command arguments")
        }
        if utilities.contains(where: privilegeUtilities.contains) {
            reasons.append("Privilege escalation")
        }
        if utilities.contains(where: credentialUtilities.contains) {
            reasons.append("Credential or key operation")
        }
        if utilities.contains(where: networkUtilities.contains) {
            reasons.append("Network transfer or remote execution")
        }

        var uniqueReasons: [String] = []
        for reason in reasons where !uniqueReasons.contains(reason) {
            uniqueReasons.append(reason)
        }
        return GeneratedCommandAssessment(
            // Model output is never sent to a shell without an explicit human
            // confirmation. Utility allowlists cannot safely model every flag,
            // environment, shell, and OS-specific side effect.
            requiresConfirmation: true,
            isExecutable: !containsDisallowedUnicode,
            reasons: uniqueReasons
        )
    }
}

// MARK: - AIAssistant

@MainActor
@Observable
final class AIAssistant {
    var isAvailable = false
    var isProcessing = false
    var lastSuggestion: (command: String, explanation: String, riskLevel: String)?
    var lastError: (problem: String, suggestedFix: String, reasoning: String)?
    var errorMessage: String?
    private var requestGeneration: UInt64 = 0

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
        guard isAvailable, !isProcessing else {
            if !isAvailable {
                errorMessage = "AI model not available on this device."
            }
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        defer {
            if requestGeneration == generation {
                isProcessing = false
            }
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
            "destructive" for deletions or system changes. Return exactly three labeled \
            sections: COMMAND:, EXPLANATION:, and RISK:. Do not use Markdown fences.
            """
            let session = LanguageModelSession(instructions: systemPrompt)

            let response = try await session.respond(to: prompt)
            guard requestGeneration == generation else { return }
            guard let result = AIResponseParser.commandSuggestion(from: response.content) else {
                throw AIResponseFormatError.invalidCommandSuggestion
            }
            lastSuggestion = (
                command: result.command,
                explanation: result.explanation,
                riskLevel: result.riskLevel
            )
            Logger.ai.info("Command suggestion generated")
        } catch {
            guard requestGeneration == generation else { return }
            Logger.ai.error("Command suggestion failed")
            errorMessage = "Failed to generate suggestion: \(error.localizedDescription)"
        }
        #endif
    }

    func explainError(terminalContext: [String], host: String, username: String) async {
        #if canImport(FoundationModels)
        guard isAvailable, !isProcessing else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        defer {
            if requestGeneration == generation {
                isProcessing = false
            }
        }

        isProcessing = true
        lastError = nil

        do {
            let contextLines = terminalContext.suffix(30).joined(separator: "\n")
            let systemPrompt = """
            You are a terminal error diagnostic assistant. \
            The user is connected to server \(host) as \(username). \
            Analyze the terminal output below and explain what went wrong. \
            If possible, suggest a fix command. Keep explanations concise. Return exactly \
            three labeled sections: PROBLEM:, FIX:, and REASONING:. Leave FIX: empty when \
            there is no safe fix. Do not use Markdown fences.
            """
            let session = LanguageModelSession(instructions: systemPrompt)

            let response = try await session.respond(to: "Terminal output:\n\(contextLines)")
            guard requestGeneration == generation else { return }
            guard let result = AIResponseParser.errorExplanation(from: response.content) else {
                throw AIResponseFormatError.invalidErrorExplanation
            }
            lastError = (
                problem: result.problem,
                suggestedFix: result.suggestedFix,
                reasoning: result.reasoning
            )
            Logger.ai.info("Error explanation generated")
        } catch {
            guard requestGeneration == generation else { return }
            Logger.ai.error("Error explanation failed")
        }
        #endif
    }

    func reset() {
        requestGeneration &+= 1
        lastSuggestion = nil
        lastError = nil
        errorMessage = nil
        isProcessing = false
    }
}

private enum AIResponseFormatError: LocalizedError {
    case invalidCommandSuggestion
    case invalidErrorExplanation

    var errorDescription: String? {
        switch self {
        case .invalidCommandSuggestion:
            "The on-device model returned an invalid command suggestion format."
        case .invalidErrorExplanation:
            "The on-device model returned an invalid error explanation format."
        }
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
    let currentDirectory: String?
    let onRunCommand: (String) -> Void

    @State private var prompt = ""
    @State private var composedCommand = ""
    @State private var pendingConfirmation: GeneratedCommandConfirmation?
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
                    description: Text(foundationModelsRequirement)
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
        .onChange(of: aiAssistant.lastSuggestion?.command) { _, command in
            pendingConfirmation = nil
            composedCommand = command ?? ""
        }
        .onChange(of: composedCommand) { _, command in
            if pendingConfirmation?.exactCommand != command {
                pendingConfirmation = nil
            }
        }
        .alert("Run generated command?", isPresented: confirmationBinding) {
            if pendingConfirmation?.assessment.isExecutable == true {
                Button("Run Exactly as Shown", role: .destructive) { executeComposedCommand() }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var foundationModelsRequirement: String {
        #if os(macOS)
        "Foundation Models requires macOS 26 or later and Apple Intelligence."
        #else
        "Foundation Models requires visionOS 26 or later and Apple Intelligence."
        #endif
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
                policyBadge(GeneratedCommandPolicy.assess(composedCommand))
                riskBadge(suggestion.riskLevel)
            }

            TextEditor(text: $composedCommand)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 110)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Editable generated command")

            Text(suggestion.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    reviewComposedCommand()
                } label: {
                    Label("Review & Run", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(composedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = composedCommand
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(composedCommand, forType: .string)
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

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private func reviewComposedCommand() {
        pendingConfirmation = GeneratedCommandConfirmation(command: composedCommand)
    }

    private var confirmationMessage: String {
        guard let confirmation = pendingConfirmation else { return "" }
        let reasons = confirmation.assessment.reasons.isEmpty
            ? "No additional policy warnings."
            : confirmation.assessment.reasons.joined(separator: "\n")
        let disposition = confirmation.assessment.isExecutable
            ? ""
            : "\n\nThis command cannot be run because its exact text could visually misrepresent what the shell receives."
        return "Exact command:\n\(confirmation.exactCommand)\n\n\(reasons)\(disposition)"
    }

    private func executeComposedCommand() {
        guard let confirmation = pendingConfirmation,
              confirmation.assessment.isExecutable,
              !confirmation.exactCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingConfirmation = nil
            return
        }
        pendingConfirmation = nil
        onRunCommand(confirmation.exactCommand)
        dismiss()
    }

    private func riskBadge(_ level: String) -> some View {
        let color: Color
        switch level.lowercased() {
        case "safe": color = .green
        case "moderate": color = .yellow
        case "destructive": color = .red
        default: color = .gray
        }

        return Text("Model: \(level.capitalized)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func policyBadge(_ assessment: GeneratedCommandAssessment) -> some View {
        Text(assessment.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (assessment.requiresConfirmation ? Color.orange : Color.green).opacity(0.2),
                in: Capsule()
            )
            .foregroundStyle(assessment.requiresConfirmation ? Color.orange : Color.green)
    }

    private func runSuggestion() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !aiAssistant.isProcessing else { return }
        pendingConfirmation = nil
        Task {
            await aiAssistant.suggestCommand(
                prompt: text,
                host: host,
                username: username,
                currentDirectory: currentDirectory
            )
        }
    }
}

// MARK: - AI Error Card

struct AIErrorCard: View {
    let error: (problem: String, suggestedFix: String, reasoning: String)
    let onRunFix: (String) -> Void
    let onDismiss: () -> Void
    @State private var composedFix: String
    @State private var pendingConfirmation: GeneratedCommandConfirmation?

    init(
        error: (problem: String, suggestedFix: String, reasoning: String),
        onRunFix: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.error = error
        self.onRunFix = onRunFix
        self.onDismiss = onDismiss
        _composedFix = State(initialValue: error.suggestedFix)
    }

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
                TextEditor(text: $composedFix)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 55, maxHeight: 90)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button {
                        reviewFix()
                    } label: {
                        Label("Review & Run", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = composedFix
                        #elseif canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(composedFix, forType: .string)
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
        .onChange(of: error.suggestedFix) { _, fix in
            pendingConfirmation = nil
            composedFix = fix
        }
        .onChange(of: composedFix) { _, fix in
            if pendingConfirmation?.exactCommand != fix {
                pendingConfirmation = nil
            }
        }
        .alert("Run generated fix?", isPresented: confirmationBinding) {
            if pendingConfirmation?.assessment.isExecutable == true {
                Button("Run Exactly as Shown", role: .destructive) { executeFix() }
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private func reviewFix() {
        pendingConfirmation = GeneratedCommandConfirmation(command: composedFix)
    }

    private var confirmationMessage: String {
        guard let confirmation = pendingConfirmation else { return "" }
        let reasons = confirmation.assessment.reasons.isEmpty
            ? "No additional policy warnings."
            : confirmation.assessment.reasons.joined(separator: "\n")
        let disposition = confirmation.assessment.isExecutable
            ? ""
            : "\n\nThis fix cannot be run because its exact text could visually misrepresent what the shell receives."
        return "Exact fix:\n\(confirmation.exactCommand)\n\n\(reasons)\(disposition)"
    }

    private func executeFix() {
        guard let confirmation = pendingConfirmation,
              confirmation.assessment.isExecutable,
              !confirmation.exactCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingConfirmation = nil
            return
        }
        pendingConfirmation = nil
        onRunFix(confirmation.exactCommand)
        onDismiss()
    }
}
