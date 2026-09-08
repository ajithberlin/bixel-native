import SwiftUI

/// Preserve paragraphs and code fences; Swift's attributed text handles inline Markdown.
struct AssistantMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    ScrollView(.horizontal) {
                        Text(part.trimmingCharacters(in: .newlines)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(10)
                    }.background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    ForEach(Array(part.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("#") {
                            Text(.init(line.drop(while: { $0 == "#" || $0 == " " }).description)).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                        } else {
                            Text(.init(line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line))
                                .font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }.tint(StudioTheme.accent)
    }
}
