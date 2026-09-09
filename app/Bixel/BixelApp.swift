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
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { post(.studioCut) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { post(.studioCopy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { post(.studioPaste) }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button("Delete") { post(.studioDelete) }
                Divider()
                Button("Flip Horizontal") { post(.studioFlipH) }
                    .keyboardShortcut("x", modifiers: [.command])
                Button("Flip Vertical") { post(.studioFlipV) }
                    .keyboardShortcut("y", modifiers: [.command])
                Button("Rotate Clockwise") { post(.studioRotate) }
                    .keyboardShortcut("c", modifiers: [.command])
                Divider()
                Button("Resize Map…") { post(.studioMapResize) }
                Button("Export Tiled JSON…") { post(.studioExportTiledJSON) }
                Button("Export Map CSV…") { post(.studioExportCSV) }
                Button("Export Map PNG…") { post(.studioExportMapPNG) }
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
