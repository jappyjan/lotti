import LottiKit
import SwiftUI

/// What Lotti remembers about you: list, search, edit, delete; plus the nightly "dreaming" that tidies it.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MemoryInfo]?
    @State private var adding = false
    @State private var newText = ""
    @State private var error: String?
    @State private var searchError: String?
    /// The memory whose swipe Delete waits for the confirmation.
    @State private var deleting: MemoryInfo?

    var body: some View {
        Loaded(load: { model in try await model.call("memory.list", ["limit": 300]).items.compactMap(MemoryInfo.init) }) { memories, reload in
            List {
                Section {
                    NavigationLink("Dreaming") { DreamingView() }
                }
                Section {
                    let shown = results ?? memories
                    if let searchError { Text("Search failed: \(searchError)").foregroundStyle(.red) }
                    if shown.isEmpty, searchError == nil { Text(results == nil ? "Nothing remembered yet." : "No matches.").foregroundStyle(.secondary) }
                    ForEach(shown) { memory in
                        NavigationLink { MemoryDetailView(memory: memory) { await reload() } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(memory.text).lineLimit(3)
                                Text([memory.kind, shortDate(memory.lastUsedAt ?? memory.createdAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = memory }
                        }
                    }
                }
                Section {
                    Button("Remember something", systemImage: "plus") { adding = true }
                }
            }
            .searchable(text: $query, prompt: "Search memories")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { if query.isEmpty { results = nil; searchError = nil } }
            .confirmationDialog("Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { memory in
                Button("Delete", role: .destructive) {
                    Task {
                        await attempt($error) { _ = try await model.call("memory.delete", ["id": .string(memory.id)]) }
                        await reload()
                    }
                }
            } message: { memory in
                Text(memory.text)
            }
            .alert("Remember", isPresented: $adding) {
                TextField("What should Lotti remember?", text: $newText)
                Button("Save") {
                    let text = newText
                    newText = ""
                    Task {
                        await attempt($error) { _ = try await model.call("memory.remember", ["text": .string(text)]) }
                        await reload()
                    }
                }
                Button("Cancel", role: .cancel) { newText = "" }
            }
            .errorAlert($error)
        }
        .navigationTitle("Memory")
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return results = nil }
        do {
            let found = try await model.call("memory.search", ["query": .string(text), "limit": 30])
            // Hits may wrap the memory (`{memory, score}`) or be the memory itself.
            results = found.items.compactMap { MemoryInfo($0) ?? $0["memory"].flatMap(MemoryInfo.init) }
            searchError = nil
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }
}

struct MemoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let memory: MemoryInfo
    let changed: @MainActor () async -> Void
    @State private var text: String
    @State private var error: String?
    @State private var confirmDelete = false

    init(memory: MemoryInfo, changed: @escaping @MainActor () async -> Void) {
        self.memory = memory
        self.changed = changed
        _text = State(initialValue: memory.text)
    }

    var body: some View {
        Form {
            Section {
                TextField("Memory", text: $text, axis: .vertical).lineLimit(2...12)
                Button("Save") {
                    Task {
                        await attempt($error) {
                            _ = try await model.call("memory.update", ["id": .string(memory.id), "text": .string(text)])
                            await changed()
                            dismiss()
                        }
                    }
                }
                .disabled(text.isEmpty || text == memory.text)
            }
            Section {
                if !memory.kind.isEmpty { LabeledContent("Kind", value: memory.kind) }
                LabeledContent("Learned", value: shortDate(memory.createdAt))
                LabeledContent("Last used", value: shortDate(memory.lastUsedAt))
                if memory.superseded { Text("Replaced by a newer memory.").foregroundStyle(.secondary) }
                if let source = memory.sourceConversation, let conversation = ConversationInfo(["id": .string(source)]) {
                    NavigationLink("Source conversation") { ConversationDetailView(conversation: conversation) }
                }
            }
            Section {
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await attempt($error) {
                        _ = try await model.call("memory.delete", ["id": .string(memory.id)])
                        await changed()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Lotti forgets it for good.")
        }
    }
}

/// The nightly tidy-up of memory: merged duplicates, resolved contradictions, dropped stale ones.
struct DreamingView: View {
    @Environment(AppModel.self) private var model
    @State private var latest: String?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        Loaded(load: { model in try await model.call("dreaming.reports", ["limit": 15]).items }) { reports, reload in
            List {
                Section {
                    Button { run(reload) } label: { if running { ProgressView() } else { Text("Run dreaming now") } }
                        .disabled(running)
                    if let latest { Text(latest).font(.callout) }
                }
                Section("Reports") {
                    if reports.isEmpty { Text("No reports yet.").foregroundStyle(.secondary) }
                    ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shortDate(report.date("at"))).font(.caption).foregroundStyle(.secondary)
                            Text(report.text("report") ?? "").textSelection(.enabled)
                        }
                    }
                }
            }
            .errorAlert($error)
        }
        .navigationTitle("Dreaming")
    }

    private func run(_ reload: @escaping @MainActor () async -> Void) {
        running = true
        Task {
            defer { running = false }
            await attempt($error) {
                let report = try await model.call("dreaming.run_now")
                latest = report.text("report")
                await reload()
            }
        }
    }
}
