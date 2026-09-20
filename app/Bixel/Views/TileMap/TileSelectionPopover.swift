// TileSelectionPopover.swift
//
// Popover menu for the Tilemap Designer's Select tool.
// Provides selection mode switching (Replace, Add, Subtract, Intersect)
// matching the Tiled application, clipboard operations (Copy, Cut, Paste, Delete),
// selection helpers (Select All, Deselect, Invert), and keyboard shortcut tips.

import SwiftUI

struct TileSelectionPopover: View {
    @ObservedObject var model: TileMapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: title + selection status pill
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(StudioTheme.accent)

                Text("Tile Selection")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                statusBadge
            }

            // Mode Selector (Replace, Add, Subtract, Intersect)
            VStack(alignment: .leading, spacing: 6) {
                Text("MODE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 6) {
                    ForEach(MapSelectionMode.allCases) { mode in
                        modeButton(mode)
                    }
                }

                // Mode helper description
                Text(modeDescription(model.selectionMode))
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.top, 2)
            }

            Divider().overlay(StudioTheme.hairline)

            // Clipboard Operations (Copy, Cut, Paste, Delete)
            VStack(alignment: .leading, spacing: 6) {
                Text("CLIPBOARD")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 6) {
                    actionButton(
                        title: "Copy",
                        symbol: "doc.on.doc",
                        shortcut: "⌘C",
                        disabled: model.tileSelection.isEmpty
                    ) {
                        model.copySelection()
                    }

                    actionButton(
                        title: "Cut",
                        symbol: "scissors",
                        shortcut: "⌘X",
                        disabled: model.tileSelection.isEmpty
                    ) {
                        model.cutSelection()
                    }

                    actionButton(
                        title: "Paste",
                        symbol: "doc.on.clipboard",
                        shortcut: "⌘V",
                        disabled: model.clipboard == nil || model.clipboard?.isEmpty == true
                    ) {
                        model.beginPaste()
                        dismiss()
                    }

                    actionButton(
                        title: "Delete",
                        symbol: "trash",
                        shortcut: "⌫",
                        disabled: model.tileSelection.isEmpty,
                        role: .destructive
                    ) {
                        model.deleteSelection()
                    }
                }
            }

            // Selection Helpers (Select All, Deselect, Invert)
            VStack(alignment: .leading, spacing: 6) {
                Text("SELECTION")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(StudioTheme.textSecondary)

                HStack(spacing: 6) {
                    secondaryButton(title: "Select All", shortcut: "⌘A") {
                        model.selectAll()
                    }

                    secondaryButton(title: "Deselect", shortcut: "⌘D", disabled: model.tileSelection.isEmpty) {
                        model.deselectAll()
                    }

                    secondaryButton(title: "Invert", shortcut: nil) {
                        model.invertSelection()
                    }
                }
            }

            Divider().overlay(StudioTheme.hairline)

            // Bottom Pro Tip
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10))
                    .foregroundColor(StudioTheme.accent)
                    .padding(.top, 1)

                Text("Drag on canvas to select. Hold ⇧ to add, ⌥ to subtract, ⇧⌥ to intersect.")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).fill(StudioTheme.panelElevated.opacity(0.85)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(StudioTheme.hairlineStrong, lineWidth: 1)
                )
        )
    }

    // MARK: - Subviews

    private var statusBadge: some View {
        Group {
            if model.tileSelection.isEmpty {
                Text("No selection")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(StudioTheme.textDisabled)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            } else {
                let count = model.tileSelection.count
                let dims = model.tileSelection.boundingRect.map { " (\($0.width)×\($0.height))" } ?? ""
                Text("\(count) tiles\(dims)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(StudioTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(StudioTheme.accent.opacity(0.18)))
            }
        }
    }

    private func modeButton(_ mode: MapSelectionMode) -> some View {
        let isSelected = model.selectionMode == mode
        return Button {
            model.selectionMode = mode
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? StudioTheme.accent : Color.white.opacity(0.85))

                Text(mode.label)
                    .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : StudioTheme.textSecondary)

                Text(mode.shortcut)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? StudioTheme.accent : StudioTheme.textDisabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? StudioTheme.accentSoft : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? StudioTheme.accent : StudioTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(mode.tooltip)
    }

    private func actionButton(
        title: String,
        symbol: String,
        shortcut: String,
        disabled: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(disabled ? StudioTheme.textDisabled : (role == .destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.9)))

                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(disabled ? StudioTheme.textDisabled : .white)

                Text(shortcut)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.textDisabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(disabled ? 0.02 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(StudioTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func secondaryButton(
        title: String,
        shortcut: String?,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(disabled ? StudioTheme.textDisabled : .white)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(StudioTheme.textDisabled)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(disabled ? 0.02 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(StudioTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func modeDescription(_ mode: MapSelectionMode) -> String {
        switch mode {
        case .replace:
            return "New drag replaces the active selection"
        case .add:
            return "Adds new tiles to selection (hold ⇧)"
        case .subtract:
            return "Removes tiles from selection (hold ⌥)"
        case .intersect:
            return "Keeps only overlapping tiles (hold ⇧⌥)"
        }
    }
}
