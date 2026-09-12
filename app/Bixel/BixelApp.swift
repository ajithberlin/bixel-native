// BixelApp.swift
//
// Application entry point. Menu commands post notifications that ContentView
// routes to the active editor model / viewport.

import SwiftUI

@main
struct BixelApp: App {
    init() {
        SubscriptionManager.shared.configure()
    }

    var body: some Scene {
        Window("Bixel Studio", id: "studio") {
            ContentView()
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Unlock Lifetime Ad-Free…") { post(.studioUnlockLifetime) }
                Button("Manage Purchases…") { post(.studioCustomerCenter) }
                Button("Restore Purchases") { post(.studioRestorePurchases) }
                Divider()
            }
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
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Flip Vertical") { post(.studioFlipV) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Rotate Clockwise") { post(.studioRotate) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Resize Map…") { post(.studioMapResize) }
                Button("Export Tiled JSON…") { post(.studioExportTiledJSON) }
                Button("Export Map CSV…") { post(.studioExportCSV) }
                Button("Export Map PNG…") { post(.studioExportMapPNG) }
            }
            CommandMenu("Frame") {
                Button("Add Frame") { post(.studioAddFrame) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Duplicate Frame") { post(.studioDuplicateFrame) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Delete Frame") { post(.studioDelete) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Copy Frame") { post(.studioCopy) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Cut Frame") { post(.studioCut) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Paste Frame") { post(.studioPaste) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Previous Frame") { post(.studioPrevFrame) }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Next Frame") { post(.studioNextFrame) }
                    .keyboardShortcut(".", modifiers: .command)
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
            CommandGroup(replacing: .help) {
                Button("Bixel Tools Reference & Guide…") { post(.studioShowHelp) }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Quick Shortcuts Reference…") { post(.studioShowHelp) }
            }
        }
        Settings {
            SettingsView()
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
