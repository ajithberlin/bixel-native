// ToolHoverButton.swift
//
// Reusable hover button component and view modifier for Bixel tool buttons.
// Provides Procreate-style dark UI hover feedback:
// - Subtle frosted glass highlight & hairline stroke on mouse hover
// - Gentle spring scale effect
// - macOS pointing hand cursor on hover
// - Rich hover tooltip detailing tool name, shortcut, and description

import SwiftUI
import AppKit

struct ToolHoverButton<Content: View>: View {
    let isSelected: Bool
    var selectedColor: Color
    var idleColor: Color
    var tooltipName: String
    var shortcut: String?
    var tooltipDescription: String?
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    let action: () -> Void
    let content: (Bool, Bool) -> Content

    @State private var isHovered = false

    init(
        isSelected: Bool = false,
        selectedColor: Color = StudioTheme.accent,
        idleColor: Color = Color.white.opacity(0.85),
        tooltipName: String,
        shortcut: String? = nil,
        tooltipDescription: String? = nil,
        width: CGFloat = 28,
        height: CGFloat = 28,
        cornerRadius: CGFloat = 6,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ isSelected: Bool, _ isHovered: Bool) -> Content
    ) {
        self.isSelected = isSelected
        self.selectedColor = selectedColor
        self.idleColor = idleColor
        self.tooltipName = tooltipName
        self.shortcut = shortcut
        self.tooltipDescription = tooltipDescription
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.action = action
        self.content = content
    }

    private var fullTooltip: String {
        var text = tooltipName
        if let shortcut, !shortcut.isEmpty {
            text += " (\(shortcut))"
        }
        if let tooltipDescription, !tooltipDescription.isEmpty {
            text += "\n\(tooltipDescription)"
        }
        return text
    }

    var body: some View {
        Button(action: action) {
            content(isSelected, isHovered)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(borderStroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.72), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(fullTooltip)
    }

    private var backgroundFill: Color {
        if isSelected {
            return isHovered ? selectedColor.opacity(0.26) : selectedColor.opacity(0.18)
        } else if isHovered {
            return Color.white.opacity(0.12)
        } else {
            return Color.clear
        }
    }

    private var borderStroke: Color {
        if isSelected {
            return isHovered ? selectedColor.opacity(0.9) : selectedColor.opacity(0.55)
        } else if isHovered {
            return Color.white.opacity(0.24)
        } else {
            return Color.clear
        }
    }
}

// MARK: - Convenience View Modifier for Existing Buttons

struct ToolHoverModifier: ViewModifier {
    var isSelected: Bool = false
    var selectedColor: Color = StudioTheme.accent
    var name: String
    var shortcut: String? = nil
    var details: String? = nil
    var cornerRadius: CGFloat = 6

    @State private var isHovered = false

    private var fullHelp: String {
        var result = name
        if let shortcut, !shortcut.isEmpty {
            result += " (\(shortcut))"
        }
        if let details, !details.isEmpty {
            result += "\n\(details)"
        }
        return result
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? (isHovered ? selectedColor.opacity(0.26) : selectedColor.opacity(0.18))
                            : (isHovered ? Color.white.opacity(0.12) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? (isHovered ? selectedColor.opacity(0.9) : selectedColor.opacity(0.55))
                            : (isHovered ? Color.white.opacity(0.24) : Color.clear),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.72), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help(fullHelp)
    }
}

extension View {
    func toolHoverEffect(
        name: String,
        shortcut: String? = nil,
        details: String? = nil,
        isSelected: Bool = false,
        selectedColor: Color = StudioTheme.accent,
        cornerRadius: CGFloat = 6
    ) -> some View {
        self.modifier(
            ToolHoverModifier(
                isSelected: isSelected,
                selectedColor: selectedColor,
                name: name,
                shortcut: shortcut,
                details: details,
                cornerRadius: cornerRadius
            )
        )
    }
}
