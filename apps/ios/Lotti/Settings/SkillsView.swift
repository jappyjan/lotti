import LottiKit
import SwiftUI

/// Skills (how-tos Lotti can load) and scripts (programs it can run): view, edit, delete, last use.
struct SkillsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case skills, scripts
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @State private var kind = Kind.skills
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            FileList(kind: kind, creating: $creating).id(kind)
        }
        .navigationTitle("Skills & scripts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FileList: View {
    let kind: SkillsView.Kind
    @Binding var creating: Bool

    var body: some View {
        Loaded(load: { [kind] model in try await model.call("\(kind.rawValue).list").items.compactMap(FileEntry.init) }) { entries, reload in
            List {
                Section {
                    if entries.isEmpty { Text("None yet. Lotti writes them itself when you ask.").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        NavigationLink { FileEditorView(kind: kind, name: entry.name) { await reload() } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.headline)
                                if !entry.description.isEmpty { Text(entry.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                Text(entry.useCount == 0 ? "Never used" : "Used \(entry.useCount)× · last \(shortDate(entry.lastUsedAt))")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Section {
                    Button("New \(kind == .skills ? "skill" : "script")", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                NavigationStack { FileEditorView(kind: kind, name: nil) { await reload() } }
            }
        }
    }
}

/// One skill or script: read, edit, save, delete. `name == nil` creates a new one.
struct FileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: SkillsView.Kind
    let name: String?
    let changed: @MainActor () async -> Void
    @State private var fileName: String
    @State private var content = ""
    @State private var loaded: Bool
    @State private var confirmDelete = false
    @State private var error: String?

    init(kind: SkillsView.Kind, name: String?, changed: @escaping @MainActor () async -> Void) {
        self.kind = kind
        self.name = name
        self.changed = changed
        _fileName = State(initialValue: name ?? "")
        _loaded = State(initialValue: name == nil)
    }

    var body: some View {
        Form {
            if name == nil { Section { TextField("Name", text: $fileName).textInputAutocapitalization(.never).autocorrectionDisabled() } }
            Section {
                TextEditor(text: $content)
                    .font(.callout.monospaced())
                    .frame(minHeight: 320)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!loaded)
            }
            if name != nil {
                Section { Button("Delete", role: .destructive) { confirmDelete = true } }
            }
        }
        .navigationTitle(name ?? "New \(kind == .skills ? "skill" : "script")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if name == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(fileName.isEmpty || !loaded) }
        }
        .errorAlert($error)
        .confirmationDialog("Delete \(name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await attempt($error) {
                        _ = try await model.call("\(kind.rawValue).delete", ["name": .string(fileName)])
                        await changed()
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard let name else { return }
            await attempt($error) {
                content = try await model.call("\(kind.rawValue).get", ["name": .string(name)]).text("content") ?? ""
                loaded = true
            }
        }
    }

    private func save() {
        Task {
            await attempt($error) {
                _ = try await model.call("\(kind.rawValue).put", ["name": .string(fileName), "content": .string(content)])
                await changed()
                dismiss()
            }
        }
    }
}
