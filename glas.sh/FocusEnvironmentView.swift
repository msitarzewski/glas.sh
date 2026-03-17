//
//  FocusEnvironmentView.swift
//  glas.sh
//
//  Immersive focus environment that dims passthrough for distraction-free terminal work
//

import SwiftUI
import RealityKit

struct FocusEnvironmentView: View {
    var body: some View {
        RealityView { content in
            // Empty scene — we only need the surroundings effect
        }
        .preferredSurroundingsEffect(.systemDark)
    }
}
