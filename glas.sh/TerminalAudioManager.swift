//
//  TerminalAudioManager.swift
//  glas.sh
//
//  Spatial audio playback for terminal bell alerts.
//  Uses AudioServices with a custom registered sound so visionOS
//  spatializes it from the calling window.
//

import AudioToolbox
import os

@MainActor
final class TerminalAudioManager {
    private var soundID: SystemSoundID = 0

    init() {
        guard let url = Bundle.main.url(forResource: "terminal_bell", withExtension: "caf") else {
            Logger.audio.warning("terminal_bell.caf not found in bundle")
            return
        }
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        if status != kAudioServicesNoError {
            Logger.audio.error("Failed to register bell sound: \(status)")
            soundID = 0
        }
    }

    deinit {
        if soundID != 0 {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }

    func playBell() {
        guard soundID != 0 else { return }
        AudioServicesPlaySystemSound(soundID)
    }
}
