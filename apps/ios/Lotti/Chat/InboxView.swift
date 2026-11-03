import LottiKit
import SwiftUI

func icon(for kind: InboxKind) -> String {
    switch kind {
    case .mail: "envelope"
    case .calendar: "calendar"
    case .job: "clock.badge.checkmark"
    case .reminder: "bell"
    case .info: "info.circle"
    }
}

/// An inbox item in the chat and the inbox list: what it is, open, its actions, dismiss.
struct InboxCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title, systemImage: icon(for: item.kind)).font(.subheadline.weight(.semibold))
            if !item.summary.isEmpty { Text(item.summary).font(.callout).foregroundStyle(.secondary) }
            HStack {
                NavigationLink("Open") { InboxItemView(itemId: item.id) }
                    .buttonStyle(.bordered)
                ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title) { Task { await chat.perform(action) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                Spacer()
                Button("Dismiss") { model.backend.inboxEvent(item.id, .dismissed) }
                    .buttonStyle(.borderless)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The inbox: what is pending and seen (live from the backend), and what you dismissed or expired.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @State private var history: [InboxItem] = []
    @State private var error: String?

    var body: some View {
        let open = model.backend.inbox.active(at: .now)
        List {
            if open.isEmpty {
                Section { Text("Nothing waiting.").foregroundStyle(.secondary) }
            } else {
                Section("Waiting") {
                    ForEach(open) { item in
                        NavigationLink { InboxItemView(itemId: item.id) } label: { row(item) }
                            .swipeActions {
                                Button("Dismiss", role: .destructive) { model.backend.inboxEvent(item.id, .dismissed) }
                            }
                    }
                }
                Section {
                    Button("Dismiss all", role: .destructive) {
                        Task {
                            await attempt($error) { _ = try await model.call("inbox.dismiss_all") }
                            model.backend.syncInbox()
                        }
                    }
                }
            }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history) { item in
                        NavigationLink { InboxItemView(itemId: item.id, fallback: item) } label: { row(item) }
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .errorAlert($error)
        .task { await loadHistory() }
        .refreshable {
            model.backend.syncInbox()
            await loadHistory()
        }
    }

    private func row(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(item.title, systemImage: icon(for: item.kind))
                .fontWeight(item.status == .pending ? .semibold : .regular)
            if !item.summary.isEmpty { Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let created = item.createdAt { Text(shortDate(created)).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private func loadHistory() async {
        guard let management = model.management else { return }
        var found: [InboxItem] = []
        for status in ["dismissed", "expired"] { found += (try? await management.inboxList(status: status, limit: 30)) ?? [] }
        history = found.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}

/// One item in full: the original text, its actions, dismiss. Opening marks it seen.
struct InboxItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    let itemId: String
    var fallback: InboxItem?

    var body: some View {
        let item = model.backend.inbox.item(itemId) ?? fallback
        List {
            if let item {
                Section {
                    Label(item.title, systemImage: icon(for: item.kind)).font(.headline)
                    if !item.summary.isEmpty { Text(item.summary) }
                }
                if !item.body.isEmpty {
                    Section("Original") { Text(item.body).textSelection(.enabled) }
                }
                Section {
                    LabeledContent("Status", value: item.status.rawValue.capitalized)
                    if let created = item.createdAt { LabeledContent("Received", value: shortDate(created)) }
                    if let expires = item.expiresAt { LabeledContent("Expires", value: shortDate(expires)) }
                    if let source = item.sourceRef { LabeledContent("Source", value: source) }
                }
                if !item.actions.isEmpty && item.isActive(at: .now) {
                    Section {
                        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.title) { Task { await chat.perform(action) } }
                        }
                    }
                }
                if item.isActive(at: .now) {
                    Section {
                        Button("Dismiss", role: .destructive) {
                            model.backend.inboxEvent(item.id, .dismissed)
                            dismiss()
                        }
                    }
                }
            } else {
                Text("This item is gone.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let item = model.backend.inbox.item(itemId), item.status == .pending { model.backend.inboxEvent(itemId, .opened) }
        }
    }
}
