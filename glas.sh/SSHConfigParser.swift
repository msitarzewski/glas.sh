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

        func flushCurrent() {
            guard !currentHosts.isEmpty else { return }
            for alias in currentHosts {
                if alias.contains("*") || alias.contains("?") || alias.contains("!") {
                    warnings.append("Skipped wildcard/negated Host pattern '\(alias)'.")
                    continue
                }
                entries.append(
                    ParsedSSHHostEntry(
                        alias: alias,
                        hostName: hostName,
                        user: user,
                        port: port,
                        identityFile: identityFile
                    )
                )
            }
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let stripped = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty, !stripped.hasPrefix("#") else { continue }

            let line = stripped.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? stripped
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else {
                warnings.append("Ignored malformed line \(lineNo).")
                continue
            }

            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if blockedDirectives.contains(key) {
                warnings.append("Ignored unsupported directive '\(parts[0])' on line \(lineNo).")
                continue
            }

            switch key {
            case "host":
                flushCurrent()
                let hostParts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                currentHosts = hostParts.map(String.init)
                hostName = nil
                user = nil
                port = nil
                identityFile = nil
            case "hostname":
                hostName = value
            case "user":
                user = value
            case "port":
                port = Int(value)
                if port == nil {
                    warnings.append("Ignored invalid Port '\(value)' on line \(lineNo).")
                }
            case "identityfile":
                identityFile = value
            case "identitiesonly":
                break
            default:
                break
            }
        }
        flushCurrent()
        return (entries, warnings)
    }
}
