//
//  Constants.swift
//  glas.sh
//
//  Typed constants for UserDefaults keys and Keychain service names
//

import Foundation

enum UserDefaultsKeys {
    static let servers = "servers"
    static let autoReconnect = "autoReconnect"
    static let confirmBeforeClosing = "confirmBeforeClosing"
    static let saveScrollback = "saveScrollback"
    static let maxScrollbackLines = "maxScrollbackLines"
    static let bellEnabled = "bellEnabled"
    static let visualBell = "visualBell"
    static let hostKeyVerificationMode = "hostKeyVerificationMode"
    static let cursorStyle = "cursorStyle"
    static let blinkingCursor = "blinkingCursor"
    static let windowOpacity = "windowOpacity"
    static let blurBackground = "blurBackground"
    static let interactiveGlassEffects = "interactiveGlassEffects"
    static let glassTint = "glassTint"
    static let showSidebarByDefault = "showSidebarByDefault"
    static let showInfoPanelByDefault = "showInfoPanelByDefault"
    static let sidebarPosition = "sidebarPosition"
    static let sessionOverrides = "sessionOverrides"
    static let trustedHostKeys = "trustedHostKeys"
    static let sshKeys = "sshKeys"
    static let theme = "theme"
    static let snippets = "snippets"
}
