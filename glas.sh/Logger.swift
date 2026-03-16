//
//  Logger.swift
//  glas.sh
//
//  Structured logging via os.Logger
//

import os

extension Logger {
    static let ssh = Logger(subsystem: "sh.glas", category: "ssh")
    static let keychain = Logger(subsystem: "sh.glas", category: "keychain")
    static let settings = Logger(subsystem: "sh.glas", category: "settings")
    static let servers = Logger(subsystem: "sh.glas", category: "servers")
    static let ai = Logger(subsystem: "sh.glas", category: "ai")
    static let audio = Logger(subsystem: "sh.glas", category: "audio")
}
