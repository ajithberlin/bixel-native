import SwiftUI
import AppKit

extension Notification.Name {
    static let assistantFocus = Notification.Name("BixelAssistantFocus")
    static let assistantInsertCommand = Notification.Name("BixelAssistantInsertCommand")
}

/// Tokens are real text attachments: they move with the text, delete atomically,
/// and serialize to stable skill IDs instead of losing their meaning on submit.
final class AssistantToken: NSTextAttachment {
    let command: AssistantCommand
    init(_ command: AssistantCommand) {
        self.command = command
        super.init(data: nil, ofType: nil)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let label = command.title as NSString
        let width = label.size(withAttributes: [.font: font]).width + 30
        image = NSImage(size: NSSize(width: width, height: 25), flipped: false) { rect in
            NSColor(calibratedRed: 0.42, green: 0.60, blue: 1, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
            let blue = NSColor(calibratedRed: 0.42, green: 0.60, blue: 1, alpha: 1)
            if let icon = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
                let tinted = NSImage(size: icon.size, flipped: false) { target in
                    icon.draw(in: target); blue.setFill(); target.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: 6, y: 6, width: 13, height: 13))
            }
            label.draw(at: NSPoint(x: 23, y: 5), withAttributes: [.font: font, .foregroundColor: blue])
            return true
        }
        bounds = CGRect(x: 0, y: -6, width: width, height: 25)
    }
    required init?(coder: NSCoder) { fatalError("Tokens are restored from their plain-text skill markers") }
}

struct AssistantTextInput: NSViewRepresentable {
    @Binding var text: String
    let commands: [AssistantCommand]
    let onQuery: (String?) -> Void
    let onSubmit: () -> Void
    let onMove: (Int) -> Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = ComposerTextView()
        editor.delegate = context.coordinator
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .white.withAlphaComponent(0.88)
        editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.typingAttributes = Coordinator.attributes
        scroll.documentView = editor; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        if Coordinator.serialize(editor.attributedString()) != text {
            editor.textStorage?.setAttributedString(context.coordinator.render(text))
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
        editor.onSubmit = onSubmit; editor.onMove = onMove; editor.onEscape = onEscape
        editor.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.88)]
        var parent: AssistantTextInput
        weak var editor: ComposerTextView?
        var slashRange: NSRange?
        init(_ parent: AssistantTextInput) {
            self.parent = parent; super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(focus), name: .assistantFocus, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(insertCommand(_:)), name: .assistantInsertCommand, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        static func serialize(_ text: NSAttributedString) -> String {
            var result = ""
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                if let token = attributes[.attachment] as? AssistantToken { result += token.command.marker }
                else { result += (text.string as NSString).substring(with: range) }
            }
            return result
        }
        func render(_ text: String) -> NSAttributedString {
            let output = NSMutableAttributedString(string: text, attributes: Self.attributes)
            for command in parent.commands {
                while true {
                    let range = (output.string as NSString).range(of: command.marker)
                    if range.location == NSNotFound { break }
                    output.replaceCharacters(in: range, with: NSAttributedString(attachment: AssistantToken(command)))
                }
            }
            return output
        }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = Self.serialize(editor.attributedString())
            editor.typingAttributes = Self.attributes; editor.needsDisplay = true
            updateQuery()
        }
        func textViewDidChangeSelection(_ notification: Notification) { updateQuery() }
        func updateQuery() {
            guard let editor, !editor.hasMarkedText() else { return }
            let selection = editor.selectedRange()
            guard selection.length == 0 else { slashRange = nil; parent.onQuery(nil); return }
            let prefix = (editor.string as NSString).substring(to: min(selection.location, editor.string.utf16.count))
            if let match = prefix.range(of: "(?:^|\\s)/[a-zA-Z0-9_-]*$", options: .regularExpression) {
                let fragment = String(prefix[match.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                slashRange = NSRange(location: selection.location - fragment.utf16.count, length: fragment.utf16.count)
                parent.onQuery(String(fragment.dropFirst()))
            } else { slashRange = nil; parent.onQuery(nil) }
        }
        @objc func focus() { editor?.window?.makeFirstResponder(editor) }
        @objc func insertCommand(_ notification: Notification) {
            guard let editor, let command = notification.object as? AssistantCommand else { return }
            let range = slashRange ?? editor.selectedRange()
            let replacement = NSMutableAttributedString(attachment: AssistantToken(command))
            replacement.append(NSAttributedString(string: " ", attributes: Self.attributes))
            editor.insertText(replacement, replacementRange: range)
            slashRange = nil; parent.onQuery(nil); focus()
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onMove: ((Int) -> Bool)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 126, onMove?(-1) == true { return }
            if event.keyCode == 125, onMove?(1) == true { return }
            if event.keyCode == 53 { onEscape?(); return }
            if event.keyCode == 36 && !event.modifierFlags.contains(.shift) { onSubmit?(); return }
        }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) {
        let value = AssistantTextInput.Coordinator.serialize(attributedString().attributedSubstring(from: selectedRange()))
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) { insertText(value, replacementRange: selectedRange()) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("Ask anything, or add a /skill…" as NSString).draw(in: NSRect(x: 0, y: 4, width: bounds.width, height: bounds.height), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.35)
            ])
        }
    }
}
