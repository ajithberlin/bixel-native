# Project Assets, AI Control, and Animation Assist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans (recommended inline). Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Persist every AI image artifact in the active project cache, keep Animation Assist visible alongside ads, and add an always-visible left project-assets dock with drag-and-drop placement.

**Architecture:** Add a pure Swift cache-path/naming helper, then let \`AssistantSession\` persist streamed artifacts on its existing serial worker queue and delay completion until those writes finish. Refactor the existing workspace library into a docked \`ProjectAssetsPanel\`; keep PNG drag providers and the existing AppKit canvas placement path. Move the AI affordance into the right tool clusters and give it one restrained animated focal treatment.

**Tech Stack:** SwiftUI, AppKit, Combine, existing \`ProjectStorage\` Rust FFI gateway, lightweight \`xcrun swiftc\` test harnesses.

**Spec:** \`docs/superpowers/specs/2026-09-10-project-assets-ai-ui-design.md\`

## Global Constraints

- Rust core stays UI-free and filesystem access stays behind \`ProjectStorage\`.
- Generated output lives under \`.studio/cache/ai/<conversation-id>/\`; accepted assets remain under \`assets/\`.
- Swift sends whole PNG payloads through the existing drag/drop and image placement APIs.
- Existing 32 MB project read and 5 MB assistant attachment limits remain unchanged.
- The asset dock is always visible on project screens and does not replace map tilesets or the sprite tool dock.
- AI motion respects \`accessibilityReduceMotion\`.

---

### Task 1: Add testable cache and Animation Assist contracts

**Files:**

- Create: \`app/Bixel/Models/ProjectArtifactCache.swift\`
- Modify: \`app/Bixel/Models/WorkspaceDocument.swift:20-48\`
- Test: \`tests/WorkspaceMetadataTests.swift\`

**Interfaces:**

- Produce \`ProjectArtifactCache.relativeDirectory(for:)\`, \`cacheURL(projectRoot:conversationID:)\`, and \`filename(for:uniqueID:)\`.
- Produce \`WorkspaceDocument.supportsAnimationAssist\`.

- [ ] **Step 1: Write the failing assertions**

Append to \`WorkspaceMetadataTests.swift\`:

~~~swift
let conversationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
precondition(ProjectArtifactCache.relativeDirectory(for: conversationID) == ".studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
precondition(ProjectArtifactCache.cacheURL(projectRoot: URL(fileURLWithPath: "/tmp/bixel"), conversationID: conversationID).path == "/tmp/bixel/.studio/cache/ai/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
let safeName = ProjectArtifactCache.filename(for: "../Hero sheet (final).png", uniqueID: conversationID)
precondition(safeName == "AAAAAAAA-Hero-sheet-final-.png")
precondition(WorkspaceDocument(name: "Walk", kind: .animation, width: 32, height: 32).supportsAnimationAssist)
precondition(!WorkspaceDocument(name: "Map", kind: .map, width: 10, height: 10).supportsAnimationAssist)
~~~ 

- [ ] **Step 2: Run the focused harness and verify it fails**

Compile all Swift sources except \`BixelApp.swift\` with \`tests/WorkspaceMetadataTests.swift\`, the existing bridging header, \`generated\`, and the Security/CoreFoundation/SystemConfiguration frameworks. Expected: missing \`ProjectArtifactCache\` and \`supportsAnimationAssist\`.

- [ ] **Step 3: Implement the minimal pure contracts**

Create \`ProjectArtifactCache.swift\` with:

~~~swift
import Foundation

enum ProjectArtifactCache {
    static func relativeDirectory(for conversationID: UUID) -> String {
        ".studio/cache/ai/\(conversationID.uuidString)"
    }

    static func cacheURL(projectRoot: URL, conversationID: UUID) -> URL {
        projectRoot.appendingPathComponent(relativeDirectory(for: conversationID), isDirectory: true)
    }

    static func filename(for suggestedName: String, uniqueID: UUID = UUID()) -> String {
        let leaf = URL(fileURLWithPath: suggestedName).lastPathComponent
        let safe = leaf.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return "\(uniqueID.uuidString.prefix(8))-\(trimmed.isEmpty ? "generated.png" : trimmed)"
    }
}
~~~

Add \`supportsAnimationAssist\` to \`WorkspaceDocument\`, returning false only for \`.map\` and \`.tileset\`.

- [ ] **Step 4: Run the focused harness again**

Expected: workspace metadata tests pass.

---

### Task 2: Persist streamed AI artifacts before session completion

**Files:**

- Modify: \`app/Bixel/Models/AssistantSession.swift:83-115,292-377\`
- Modify: \`app/Bixel/Models/ProjectStore.swift:285-298\`
- Test: \`tests/AssistantSessionTests.swift\`

**Interfaces:**

- Consume \`ProjectArtifactCache.cacheURL\`.
- Produce \`AssistantSession.onArtifactPersisted\` for store refreshes.

- [ ] **Step 1: Write the failing regression**

Configure a temporary project root, receive a PNG \`artifact\` event, drain the main run loop briefly, and assert that a file exists below \`<root>/.studio/cache/ai/<conversation-id>/\`. The assertion must run before any production persistence change.

- [ ] **Step 2: Run the assistant harness and verify the new assertion fails**

Run \`bash scripts/test-assistant.sh\`. Record the current unrelated stale compile errors if present; the new persistence assertion must fail because artifacts are currently memory-only.

- [ ] **Step 3: Implement queued persistence and finish gating**

In \`AssistantSession\`:

1. Replace the computed workspace string with \`workspaceURL\` from \`ProjectArtifactCache.cacheURL\`.
2. Add \`onArtifactPersisted\`, \`pendingArtifactWrites\`, \`finishRequested\`, and \`finishStopped\`.
3. On each decoded artifact, append the in-memory artifact and queue \`ProjectStorage.write(base: workspaceURL, path: ProjectArtifactCache.filename(for:), data:)\`.
4. Dispatch write results to the main actor; refresh on success, surface \`Could not save generated image: ...\` on failure, decrement the pending count, and finish only after the count reaches zero.
5. Flush queued events before \`finish(stopped:)\`; move the existing completion body into \`completeFinish(stopped:)\`.
6. Use the same cache helper for direct local-skill output names.

In \`ProjectStore.open\`, set \`assistant.onArtifactPersisted = { [weak self] in self?.refreshAssets() }\`.

- [ ] **Step 4: Run verification**

Run \`cargo test -p bixel-core\` and the assistant harness. Verify the temporary project contains the generated image below \`.studio/cache/ai/\`.

---

### Task 3: Make Animation Assist ad-safe

**Files:**

- Modify: \`app/Bixel/Views/ContentView.swift:17-31,193-229,246-360\`
- Modify: \`app/Bixel/Views/TopBar.swift:314-392\`
- Test: \`tests/WorkspaceMetadataTests.swift\`

- [ ] **Step 1: Add the failing eligibility assertion**

Add an \`.image\` document assertion to the workspace test so the existing behavior is explicit: image documents support Animation Assist while maps and tilesets do not.

- [ ] **Step 2: Implement stable timeline eligibility and layout**

In \`ContentView\`:

1. Remove \`showLibrary\` and the old floating library overlays.
2. Gate the timeline with \`projects.activeDocument?.supportsAnimationAssist == true\`.
3. Keep top chrome, selection controls, and feedback in the flexible stack.
4. Put \`TimelineBar\` and \`AdBannerView\` in a dedicated bottom chrome container, with the timeline in a bounded max-width row and the ad in its own fixed-size footer.
5. Keep \`showTimeline\` in \`ActionsPopover\`; maps do not render or offer the toggle.

Use this bottom structure:

~~~swift
VStack(spacing: 8) {
    if showTimeline && projects.activeDocument?.supportsAnimationAssist == true {
        TimelineBar(model: model)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .zIndex(1)
    }
    AdBannerView(onPresentPaywall: { showPaywall = true })
        .fixedSize(horizontal: false, vertical: true)
}
.padding(.horizontal, 20)
.padding(.bottom, 8)
~~~

- [ ] **Step 3: Compile and inspect**

Run the focused Swift harness and \`git diff --check\`. Confirm the condition uses the active document contract and the ad is below, not overlapping, the timeline.

---

### Task 4: Build and mount the left project-assets dock

**Files:**

- Modify: \`app/Bixel/Views/WorkspaceLibrary.swift:4-141\`
- Modify: \`app/Bixel/Models/WorkspaceDocument.swift:57-64\`
- Modify: \`app/Bixel/Views/ContentView.swift:193-229,246-309,405-433\`
- Test: \`tests/AssistantSessionTests.swift\` source compile

**Interfaces:**

- Consume \`ProjectStore.assets\`, \`ProjectStore.catalog\`, \`ProjectStore.assetData\`, \`ProjectStore.openImageAsset\`, \`EditorModel.placeAsset\`, and \`imageProvider\`.
- Produce \`ProjectAssetsPanel(store:)\`.

- [ ] **Step 1: Write the failing use-site**

Instantiate \`ProjectAssetsPanel(store: store)\` in the assistant harness before the view exists, then run the Swift source compile and observe the missing type.

- [ ] **Step 2: Refactor the existing library**

Rename the main view to \`ProjectAssetsPanel\` and remove the close button. Add:

- project name, count, refresh, and search;
- segmented filters for All, Images, and Files;
- clickable Documents section;
- generated/project badges using \`asset.path.hasPrefix(".studio/cache/")\` and \`asset.path.hasPrefix("assets/")\`;
- nearest-neighbor image rows with preview data loaded from \`store.assetData\`;
- \`.onDrag { imageProvider(data) }\` only for image rows;
- existing preview actions: open, add layer, assistant reference, sheet slicing, and promote to \`assets/\`.

Add \`ProjectAssetFile.isGenerated\` and \`locationLabel\`. Keep text/code previewable and non-draggable.

- [ ] **Step 3: Mount it as the left sibling**

In \`ContentView.projectCanvasView\`, place before \`editorWorkspaceView\`:

~~~swift
ProjectAssetsPanel(store: projects)
    .id(projects.current?.id)
    .frame(width: 300)
    .frame(maxHeight: .infinity)
    .background(StudioTheme.panel)
    .overlay(alignment: .trailing) {
        Rectangle().fill(StudioTheme.hairlineStrong).frame(width: 1)
    }
~~~

Remove the old sprite/map overlay branches. Leave \`TilesetPanel\` in the map editor.

- [ ] **Step 4: Compile and verify drag/drop**

Run \`bash scripts/test-interactions.sh\`, \`bash scripts/test-assistant.sh\`, and \`git diff --check\`. Confirm image rows provide PNG data and \`CanvasView.performDragOperation\` still calls \`EditorModel.placeAsset\` at the pointer coordinate.

---

### Task 5: Move and animate the AI control

**Files:**

- Modify: \`app/Bixel/Views/TopBar.swift:54-143,174-227,245-303\`
- Test: \`tests/WorkspaceMetadataTests.swift\` source compile

- [ ] **Step 1: Write the placement expectation**

Add this source-level comment to the workspace test:

~~~swift
// TopBar order contract: brush tools -> layers -> color palette -> AI copilot.
~~~

- [ ] **Step 2: Implement the new control**

Create a private \`AICopilotButton\` in \`TopBar.swift\` with \`@Environment(\\.accessibilityReduceMotion)\` and \`@State private var phase\`. Use one green/blue halo plus a slow sparkle orbit/pulse while motion is allowed, a static icon for reduced motion, and accessibility label \`AI Copilot\`.

Remove the old left-cluster AI button. Append the control after \`colorToggle(isSpriteColor: true)\` in the sprite right cluster and after \`layersToggle\` in the map right cluster.

- [ ] **Step 3: Compile and inspect**

Run \`bash scripts/test-interactions.sh\` and \`git diff --check\`. Confirm the old left-cluster button is gone and the sprite order is brush tools, layers, color, AI.

---

### Task 6: Final verification

**Files:** none unless verification finds a regression.

- [ ] **Step 1:** Run \`git diff --check\` and \`git status --short\`.
- [ ] **Step 2:** Run \`cargo test -p bixel-core\`.
- [ ] **Step 3:** Run \`bash scripts/test-interactions.sh\` and \`bash scripts/test-assistant.sh\`; report known baseline failures separately.
- [ ] **Step 4:** If available, run \`xcodegen generate\` and \`xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build\`.
- [ ] **Step 5:** Verify each requirement against code and runtime evidence before claiming completion.

