//
//  SSHConfigParser.swift
//  glas.sh
//
//  Parser for ~/.ssh/config format
//

import Foundation

struct SSHConfigImportResult {
    let imported: Int
    let updated: Int
    let skipped: Int
    let warnings: [String]
}

struct ParsedSSHHostEntry {
    let alias: String
    let hostName: String?
    let user: String?
    let port: Int?
    let identityFile: String?
}

enum SSHConfigParser {
    static func parse(_ text: String) -> ([ParsedSSHHostEntry], [String]) {
        let blockedDirectives: Set<String> = [
            "proxycommand", "localcommand", "include", "match", "proxyjump", "remotecommand"
        ]
        var warnings: [String] = []
        var entries: [ParsedSSHHostEntry] = []

        var currentHosts: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
        var skippingMatch = false
        var invalidPort = false

        func flushCurrent() {
            guard !currentHosts.isEmpty else { return }
            guard !currentHosts.contains(where: { $0.hasPrefix("!") }) else {
                warnings.append("Skipped negated Host block '\(currentHosts.joined(separator: " "))'; its conditional exclusions are unsupported.")
                return
            }
            guard !invalidPort else {
                warnings.append("Skipped Host block '\(currentHosts.joined(separator: " "))' because its Port is invalid.")
                return
            }
            for alias in currentHosts {
                if alias.contains("*") || alias.contains("?") || alias.contains("!") {
                    warnings.append("Skipped wildcard/negated Host pattern '\(alias)'.")
                    continue
                }
                if let index = entries.firstIndex(where: { $0.alias == alias }) {
                    let previous = entries[index]
                    // OpenSSH takes the first obtained value for each option.
                    entries[index] = ParsedSSHHostEntry(
                        alias: alias,
                        hostName: previous.hostName ?? hostName,
                        user: previous.user ?? user,
                        port: previous.port ?? port,
                        identityFile: previous.identityFile ?? identityFile
                    )
                } else {
                    entries.append(ParsedSSHHostEntry(
                        alias: alias,
                        hostName: hostName,
                        user: user,
                        port: port,
                        identityFile: identityFile
                    ))
                }
            }
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let stripped = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty, !stripped.hasPrefix("#") else { continue }

            // A Match block ends the preceding Host scope, including malformed
            // Match declarations. Conditional directives must never leak back.
            let directive = stripped.prefix { !$0.isWhitespace && $0 != "=" }.lowercased()
            if directive == "match" {
                flushCurrent()
                currentHosts = []
                skippingMatch = true
                warnings.append("Skipped unsupported Match block on line \(lineNo) through the next Host declaration.")
                continue
            }
            if skippingMatch && directive != "host" { continue }

            let parts = tokens(in: stripped)
            guard parts.count >= 2 else {
                if directive == "host" {
                    flushCurrent()
                    currentHosts = []
                }
                warnings.append("Ignored malformed line \(lineNo).")
                continue
            }

            let key = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            if blockedDirectives.contains(key) {
                warnings.append("Ignored unsupported directive '\(parts[0])' on line \(lineNo).")
                continue
            }

            switch key {
            case "host":
                flushCurrent()
                skippingMatch = false
                currentHosts = Array(parts.dropFirst())
                hostName = nil
                user = nil
                port = nil
                identityFile = nil
                invalidPort = false
            case "hostname":
                if currentHosts.isEmpty {
                    warnings.append("Ignored global HostName on line \(lineNo); set it in each explicit Host block.")
                } else if hostName == nil { hostName = value }
            case "user":
                if currentHosts.isEmpty {
                    warnings.append("Ignored global User on line \(lineNo); set it in each explicit Host block.")
                } else if user == nil { user = value }
            case "port":
                if currentHosts.isEmpty {
                    warnings.append("Ignored global Port on line \(lineNo); set it in each explicit Host block.")
                } else if port == nil {
                    if let number = Int(value), (1...65535).contains(number) {
                        port = number
                    } else {
                        invalidPort = true
                        warnings.append("Invalid Port on line \(lineNo); expected 1–65535.")
                    }
                }
            case "identityfile":
                if currentHosts.isEmpty {
                    warnings.append("Ignored global IdentityFile on line \(lineNo); set it in each explicit Host block.")
                } else if identityFile == nil {
                    identityFile = value
                } else {
                    warnings.append("Ignored additional IdentityFile on line \(lineNo); only one imported key can be selected per profile.")
                }
            default:
                warnings.append("Ignored unsupported directive '\(parts[0])' on line \(lineNo).")
            }
        }
        flushCurrent()
        return (entries, warnings)
    }

    private static func tokens(in line: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#" && !quoted {
                break
            } else if !quoted && (character.isWhitespace || (character == "=" && result.count <= 1 && token.isEmpty)) {
                if !token.isEmpty {
                    result.append(token)
                    token = ""
                }
            } else if !quoted && character == "=" && result.isEmpty {
                result.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        guard !quoted, !escaped else { return [] }
        if !token.isEmpty { result.append(token) }
        return result
    }
}
