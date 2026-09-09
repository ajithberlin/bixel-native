// Run with scripts/test-assistant.sh. No model requests or external network calls.
import SwiftUI
import AppKit

@main
struct AssistantSessionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let session = AssistantSession()
        precondition(session.commands.count > 4, "Use the complete engine skill registry")
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
        session.receive(AssistantEvent(type: "artifact", id: "image1", parent_id: "arbitrary-tool", name: "result.png", png: png.base64EncodedString(), width: 1, height: 1))
        session.receive(AssistantEvent(type: "tool_result", id: "arbitrary-tool", name: "future_code_tool", text: "Actual tool output", success: true))
        session.receive(AssistantEvent(type: "started", id: "round1", title: "Thinking"))
        session.receive(AssistantEvent(type: "text", id: "round1", delta: "Done."))
        session.receive(AssistantEvent(type: "finished"))
        let blocks = session.messages[0].blocks
        precondition(blocks.map(\.kind) == [.thinking, .text, .tool, .thinking, .text], "Preserve actual event order, including intermediate text")
        precondition(blocks[1].text == "Inspecting the reference.", "Accumulate streaming deltas")
        precondition(blocks[2].title == "future_code_tool", "Unknown tools must render generically")
        precondition(blocks[2].artifacts[0].data == png, "Associate output images with their tool call")
        precondition(!blocks.contains(where: \.running), "Finish all active steps")
        session.receive(AssistantEvent(type: "error", message: "Connection failed"))
        precondition(session.messages[0].blocks.last?.kind == .error)
        precondition(session.messages[0].blocks.last?.failed == true)
        let cancellation = AssistantCancellation()
        cancellation.stop()
        precondition(cancellation.isStopped)
        print("PASS: inline token round-trip, registry, streaming order, generic tools, image association, failure, cancellation")
    }
}
