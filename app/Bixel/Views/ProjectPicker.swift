import SwiftUI

struct ProjectPicker: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var assistant: AssistantSession

    init(store: ProjectStore) {
        self.store = store
        self.assistant = store.assistant
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Projects").font(.title2.bold())
                Spacer()
                if store.current != nil { Button("Done") { dismiss() } }
            }
            Text("Your artwork, AI files, and conversations stay together on this device.")
                .foregroundColor(.secondary)
            HStack {
                TextField("New project name", text: $name).onSubmit(create)
                Button("Create Project", action: create)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.busy)
            }
            List(store.projects) { project in
                Button {
                    store.select(project)
                    if store.current?.id == project.id { dismiss() }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(project.name)
                        Spacer()
                        if project.id == store.current?.id { Image(systemName: "checkmark") }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(assistant.busy)
            }
            .frame(minHeight: 200)
            HStack {
                Text("Saved in Documents / Bixel / Projects")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if let current = store.current {
                    Button("AI Files") {
                        NSWorkspace.shared.open(store.root.appendingPathComponent("\(current.id)/.studio/cache/ai"))
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { store.refresh() }
    }

    private func create() {
        let previous = store.current?.id
        store.create(name: name)
        if store.current?.id != previous { dismiss() }
    }
}
