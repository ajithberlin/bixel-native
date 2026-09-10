import SwiftUI
import AppKit

struct AIGeneratedImageReviewView: View {
    let draft: AIGeneratedImageDraft
    let onCreateProject: () -> Void
    let onKeepInGallery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your image is ready")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Review it before deciding where to keep it.")
                        .font(.system(size: 12))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Spacer()
                Text("\(draft.width) × \(draft.height) px")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.bixelGreen)
            }

            if let image = NSImage(data: draft.data) {
                ZStack {
                    CheckerboardView(cell: 12)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(14)
                }
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
                )
                .accessibilityLabel("Generated image, \(draft.width) by \(draft.height) pixels")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28))
                    Text("Preview unavailable")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(StudioTheme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 280)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(draft.style)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(draft.prompt)
                    .font(.system(size: 11))
                    .foregroundColor(StudioTheme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button("Keep in Gallery") {
                    onKeepInGallery()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Project") {
                    onCreateProject()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.bixelGreen)
                .foregroundColor(.black)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(StudioTheme.homeDark)
    }
}

struct AIGalleryStrip: View {
    @ObservedObject var gallery: AIGalleryStore
    let onSelect: (AIGalleryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Gallery")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Generated images you chose to keep")
                        .font(.system(size: 11))
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Spacer()
                Text("\(gallery.items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(StudioTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(gallery.items.prefix(8))) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            AIGalleryCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct AIGalleryCard: View {
    let item: AIGalleryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CheckerboardView(cell: 7)
                if let image = NSImage(data: item.data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(8)
                }
            }
            .frame(width: 132, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(StudioTheme.homeCardBorder, lineWidth: 1)
            )

            Text(item.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text("\(item.width) × \(item.height) px")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(StudioTheme.textSecondary)
        }
        .frame(width: 132, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.width) by \(item.height) pixels")
        .help("View generated image")
    }
}

struct AIGalleryImagePreview: View {
    let item: AIGalleryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    Text("\(item.width) × \(item.height) px · \(item.style)")
                        .font(.caption)
                        .foregroundColor(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let image = NSImage(data: item.data) {
                ZStack {
                    CheckerboardView(cell: 12)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text(item.prompt)
                .font(.system(size: 11))
                .foregroundColor(StudioTheme.textSecondary)
                .lineLimit(3)
        }
        .padding(24)
        .frame(width: 640, height: 650)
        .background(StudioTheme.homeDark)
    }
}
