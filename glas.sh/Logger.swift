//
//  Logger.swift
//  glas.sh
//
//  Structured logging via os.Logger
//

import os

extension Logger {
    nonisolated static let ssh = Logger(subsystem: "sh.glas", category: "ssh")
    nonisolated static let keychain = Logger(subsystem: "sh.glas", category: "keychain")
    nonisolated static let settings = Logger(subsystem: "sh.glas", category: "settings")
    nonisolated static let servers = Logger(subsystem: "sh.glas", category: "servers")
    nonisolated static let ai = Logger(subsystem: "sh.glas", category: "ai")
    nonisolated static let audio = Logger(subsystem: "sh.glas", category: "audio")
    nonisolated static let tailscale = Logger(subsystem: "sh.glas", category: "tailscale")
    nonisolated static let recording = Logger(subsystem: "sh.glas", category: "recording")
    nonisolated static let immersive = Logger(subsystem: "sh.glas", category: "immersive")
}
