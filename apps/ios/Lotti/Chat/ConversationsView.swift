import LottiKit
import SwiftUI

/// Past conversations, read-only; the current one is the chat itself.
struct ConversationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var found: [ConversationInfo]?
    @State private var searchError: String?

    var body: some View {
        Loaded(load: { model in try await model.call("conversations.list", ["limit": 50]).items.compactMap(ConversationInfo.init) }) { list, _ in
            let shown = found ?? list
            List {
                if let searchError {
                    Text("Search failed: \(searchError)").foregroundStyle(.red)
                } else if found != nil, shown.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                }
                ForEach(shown) { conversation in
                    if conversation.isOpen {
                        Button { dismiss() } label: { row(conversation, current: true) }
                    } else {
                        NavigationLink { ConversationDetailView(conversation: conversation) } label: { row(conversation, current: false) }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search conversations")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: search) { if search.isEmpty { found = nil; searchError = nil } }
        }
        .navigationTitle("Conversations")
    }

    private func row(_ conversation: ConversationInfo, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conversation.title.isEmpty ? (current ? "Current conversation" : "Conversation") : conversation.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if current { Text("Now").font(.caption2.weight(.bold)).foregroundStyle(.green) }
            }
            if !conversation.summary.isEmpty {
                Text(conversation.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(shortDate(conversation.lastActiveAt)).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func runSearch() async {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return found = nil }
        do {
            let result = try await model.call("conversations.search", ["query": .string(query), "limit": 20])
            // Hits may be conversations or turns that name their conversation; list what we can read as conversations.
            found = result.items.compactMap { ConversationInfo($0) ?? $0["conversation"].flatMap(ConversationInfo.init) }
            searchError = nil
        } catch {
            found = []
            searchError = error.localizedDescription
        }
    }
}

struct ConversationDetailView: View {
    let conversation: ConversationInfo

    var body: some View {
        Loaded(load: { model in
            try await model.call("conversations.get", ["id": .string(conversation.id)])["turns"]?.array?.compactMap(TurnInfo.init) ?? []
        }) { turns, _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !conversation.summary.isEmpty {
                        Text(conversation.summary).font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    ForEach(turns) { turn in
                        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 2) {
                            Text(markdown(turn.text))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(turn.role == .user ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 18))
                                .textSelection(.enabled)
                            Text(shortDate(turn.at)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "Conversation" : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
