//
//  TerminalAudioManager.swift
//  glas.sh
//
//  Terminal bell audio playback.
//
//  Known limitation: visionOS does not provide an API to spatialize
//  short sound effects from a specific window. The bell plays correctly
//  but is not anchored to a particular terminal window's spatial position.
//  RealityKit spatial audio requires a Volume or ImmersiveSpace context
//  and crashes when hosted in a zero/overlay RealityView within a Window.
//

import AudioToolbox

@MainActor
final class TerminalAudioManager {
    func playBell() {
        AudioServicesPlaySystemSound(1007)
    }
}
