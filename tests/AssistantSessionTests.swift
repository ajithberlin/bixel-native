// Run with scripts/test-assistant.sh. No model requests or external network calls.
import SwiftUI
import AppKit
import Combine

@main
struct AssistantSessionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) == .swiftUI,
            "macOS 14 and newer must use SwiftUI's settings presentation action"
        )
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)) == .legacySelector("showSettingsWindow:"),
            "macOS 13 must use the Settings scene selector"
        )
        precondition(
            AppSettings.route(for: OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)) == .legacySelector("showPreferencesWindow:"),
            "macOS 12 and older must use the Preferences scene selector"
        )
        let editor = EditorModel()
        editor.brushSize = 1
        var updates = 0
        let observation = editor.objectWillChange.sink { updates += 1 }
        editor.beginStroke(x: 1, y: 1)
        for x in 2...20 { editor.continueStroke(x: x, y: 1) }
        precondition(updates == 0, "Pointer samples must not refresh the whole SwiftUI hierarchy")
        editor.endStroke(x: 21, y: 1)
        precondition(updates == 1, "Refresh document controls once after a stroke")
        precondition(editor.document.getPixel(layer: 0, frame: 0, x: 21, y: 1).a > 0)
        let canvas = PixelCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        let canvasCoordinator = CanvasView.Coordinator(model: editor, viewport: CanvasViewport())
        editor.tool = .pencil
        canvasCoordinator.commitLine(from: CGPoint(x: 15, y: 295), to: CGPoint(x: 500, y: 295), dragged: true, in: canvas)
        precondition(editor.document.getPixel(layer: 0, frame: 0, x: 31, y: 0).a == 255, "Mouse-up outside canvas must finish the line at its edge")
        let afterEnd = updates
        canvasCoordinator.drag(at: CGPoint(x: 100, y: 100), in: canvas)
        precondition(updates == afterEnd, "Releasing outside must clear the active stroke")
        withExtendedLifetime(observation) {}
        let session = AssistantSession()
        precondition(session.commands.count > 4, "Use the complete engine skill registry")
        let localResult = try! JSONDecoder().decode(SkillRunResult.self, from: Data(#"{"source_image":"source","image":"prepared","frames":[],"text":"ok"}"#.utf8))
        precondition(localResult.source_image == "source", "Local image results must retain the unprepared source artifact")
        let first = session.commands[0], second = session.commands[1]
        let input = "Before \(first.marker) between \(second.marker) after 🐈"
        session.input = input
        precondition(session.selectedCommands.count == 2)
        precondition(session.readable(input).contains("/\(first.id) between /\(second.id)"))

        let view = AssistantTextInput(text: .constant(input), commands: session.commands,
            onQuery: { _ in }, onSubmit: {}, onMove: { _ in false }, onEscape: {})
        let coordinator = view.makeCoordinator()
        let rendered = coordinator.render(input)
        precondition(AssistantTextInput.Coordinator.serialize(rendered) == input, "Inline tokens must round-trip without losing surrounding Unicode text")
        var tokens = 0
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value is AssistantToken { tokens += 1 }
        }
        precondition(tokens == 2, "Both skills must be actual inline text attachments")

        session.messages = [AssistantMessage(isUser: false, text: "")]
        session.receive(AssistantEvent(type: "started", id: "round0", title: "Thinking"))
        session.receive(AssistantEvent(type: "thinking", id: "round0", delta: "Provider summary"))
        session.receive(AssistantEvent(type: "text", id: "round0", delta: "Inspecting "))
        session.receive(AssistantEvent(type: "text", id: "round0", delta: "the reference."))
        session.receive(AssistantEvent(type: "tool_call", id: "arbitrary-tool", name: "future_code_tool", arguments: "{\"code\":\"print(1)\"}"))
        let png = AIService.rgbaToPNG([255, 0, 0, 255], width: 1, height: 1)!
        session.receive(AssistantEvent(type: "artifact", id: "image1", parent_id: "arbitrary-tool", name: "result.png", png: png.base64EncodedString(), width: 1, height: 1, source: true))
        session.receive(AssistantEvent(type: "tool_result", id: "arbitrary-tool", name: "future_code_tool", text: "Actual tool output", success: true))
        session.receive(AssistantEvent(type: "started", id: "round1", title: "Thinking"))
        session.receive(AssistantEvent(type: "text", id: "round1", delta: "Done."))
        session.receive(AssistantEvent(type: "finished"))
        let blocks = session.messages[0].blocks
        precondition(blocks.map(\.kind) == [.thinking, .text, .tool, .thinking, .text], "Preserve actual event order, including intermediate text")
        precondition(blocks[1].text == "Inspecting the reference.", "Accumulate streaming deltas")
        precondition(blocks[2].title == "future_code_tool", "Unknown tools must render generically")
        precondition(blocks[2].artifacts[0].data == png, "Associate output images with their tool call")
        precondition(blocks[2].artifacts[0].isSource, "Generated originals must retain source provenance in the transcript")
        let restoredArtifact = try! JSONDecoder().decode(AssistantArtifact.self,
                                                          from: JSONEncoder().encode(blocks[2].artifacts[0]))
        precondition(restoredArtifact.isSource, "Original/prepared provenance must survive assistant persistence")
        precondition(!blocks.contains(where: \.running), "Finish all active steps")
        session.receive(AssistantEvent(type: "error", message: "Connection failed"))
        precondition(session.messages[0].blocks.last?.kind == .error)
        precondition(session.messages[0].blocks.last?.failed == true)
        let cancellation = AssistantCancellation()
        cancellation.stop()
        precondition(cancellation.isStopped)
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bixel-project-tests-\(UUID().uuidString)/Documents/Bixel/Projects")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let store = ProjectStore(root: projectRoot)
        precondition(store.error == nil, store.error ?? "unexpected project catalog state")
        store.create(name: "First")
        precondition(store.error == nil, store.error ?? "")
        let firstProject = store.current!
        store.editor.brushSize = 1
        store.editor.beginStroke(x: 7, y: 9)
        store.editor.endStroke(x: 7, y: 9)
        store.assistant.messages = [AssistantMessage(isUser: true, text: "A green knight")]
        store.assistant.newChat()
        precondition(store.assistant.history.count == 1)
        store.assistant.messages = [AssistantMessage(isUser: true, text: "Give the knight a shield")]
        let firstConversation = store.assistant.conversationID
        store.create(name: "Second")
        precondition(store.current?.id != firstProject.id)
        precondition(store.assistant.messages.isEmpty && store.assistant.history.isEmpty)
        precondition(store.editor.document.getPixel(layer: 0, frame: 0, x: 7, y: 9).a == 0)
        store.select(firstProject)
        precondition(store.assistant.messages.first?.text == "Give the knight a shield")
        precondition(store.assistant.history.count == 1)
        precondition(store.assistant.conversationID == firstConversation)
        precondition(store.editor.document.getPixel(layer: 0, frame: 0, x: 7, y: 9).a == 255)
        try! store.flush()
        let reopened = ProjectStore(root: projectRoot)
        precondition(reopened.error == nil, reopened.error ?? "")
        precondition(reopened.current?.id == firstProject.id)
        precondition(reopened.assistant.messages.first?.text == "Give the knight a shield")
        precondition(reopened.editor.document.getPixel(layer: 0, frame: 0, x: 7, y: 9).a == 255)
        reopened.assistant.busy = true
        reopened.select(store.projects.first { $0.id != firstProject.id }!)
        precondition(reopened.current?.id == firstProject.id, "Do not switch projects during generation")
        reopened.assistant.busy = false
        precondition(PixelCanvas().acceptsFirstMouse(for: nil))
        print("PASS: project creation, isolation, reopen, layered persistence, first click, stroke refresh batching")
        print("PASS: inline token round-trip, registry, streaming order, generic tools, image association, failure, cancellation")
    }
}
