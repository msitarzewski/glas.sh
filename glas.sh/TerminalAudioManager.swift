//
//  TerminalAudioManager.swift
//  glas.sh
//
//  Spatial audio playback for terminal bell alerts.
//  Each instance owns its own AVAudioPlayer so visionOS spatializes
//  the sound from the window that created the player.
//  Player is created lazily on first play (not init) so it attaches
//  to the correct window context.
//

import AVFoundation
import os

@MainActor
final class TerminalAudioManager {
    private var bellPlayer: AVAudioPlayer?
    private var didPrepare = false

    private static var audioSessionConfigured = false

    init() {
        if !Self.audioSessionConfigured {
            Self.audioSessionConfigured = true
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient)
            } catch {
                Logger.audio.error("Failed to set audio session category: \(error)")
            }
        }
    }

    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true

        guard let url = Bundle.main.url(forResource: "terminal_bell", withExtension: "caf") else {
            Logger.audio.warning("terminal_bell.caf not found in bundle")
            return
        }
        do {
            bellPlayer = try AVAudioPlayer(contentsOf: url)
            bellPlayer?.prepareToPlay()
        } catch {
            Logger.audio.error("Failed to prepare bell sound: \(error)")
        }
    }

    func playBell() {
        prepareIfNeeded()
        guard let player = bellPlayer else { return }
        player.currentTime = 0
        player.play()
    }
}
