//
//  glasWidgets.swift
//  glasWidgets
//
//  Widget bundle entry point for glas.sh spatial widgets
//

import WidgetKit
import SwiftUI

@main
struct GlasWidgetBundle: WidgetBundle {
    var body: some Widget {
        ServerHealthWidget()
    }
}
