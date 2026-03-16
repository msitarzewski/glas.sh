//
//  TerminalAudioManager.swift
//  glas.sh
//
//  Spatial audio playback for terminal bell alerts
//

import AVFoundation
import os

@MainActor
final class TerminalAudioManager {
    static let shared = TerminalAudioManager()

    private var bellPlayer: AVAudioPlayer?

    private init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
        } catch {
            Logger.audio.error("Failed to set audio session category: \(error)")
        }
        preloadBell()
    }

    private func preloadBell() {
        guard let url = Bundle.main.url(forResource: "terminal_bell", withExtension: "caf") else {
            Logger.audio.warning("terminal_bell.caf not found in bundle")
            return
        }
        do {
            bellPlayer = try AVAudioPlayer(contentsOf: url)
            bellPlayer?.prepareToPlay()
        } catch {
            Logger.audio.error("Failed to preload bell sound: \(error)")
        }
    }

    func playBell() {
        guard let player = bellPlayer else {
            Logger.audio.warning("Bell player not available, attempting reload")
            preloadBell()
            return
        }
        player.currentTime = 0
        player.play()
    }
}
