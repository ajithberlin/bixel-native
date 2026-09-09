// BixelApp.swift
//
// Application entry point. Menu commands post notifications that ContentView
// routes to the active editor model / viewport.

import SwiftUI

@main
struct BixelApp: App {
    var body: some Scene {
        Window("Bixel Studio", id: "studio") {
            ContentView()
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { post(.studioUndo) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { post(.studioRedo) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Zoom In") { post(.studioZoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { post(.studioZoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom to Fit") { post(.studioZoomFit) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
