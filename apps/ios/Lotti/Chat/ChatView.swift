import LottiKit
import SwiftUI

/// Lotti as a chat: what you type or say, what Lotti answers, and what comes in meanwhile.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.items.isEmpty { EmptyChat(mascot: model.mascot) }
                    ForEach(chat.items) { item in
                        ChatRow(item: item, isLast: item.id == chat.items.last?.id).id(item.id)
                    }
                    if chat.isAsking { WorkingRow(text: chat.statusLine).id("working") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.items.count) { scrollToBottom(proxy) }
            .onChange(of: chat.isAsking) { scrollToBottom(proxy) }
            .onChange(of: chat.statusLine) { scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
        .safeAreaInset(edge: .bottom, spacing: 0) { ComposerBar() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    if !chat.items.isEmpty { MascotAvatarView(host: model.mascot) }
                    Text("Lotti").font(.headline)
                    Circle().fill(chat.isOnline ? Color.green : Color.orange).frame(width: 8, height: 8)
                }
            }
            ToolbarItemGroup(placement: .topBarLeading) {
                NavigationLink { ConversationsView() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Conversations")
                NavigationLink { InboxView() } label: { Image(systemName: pending > 0 ? "tray.full" : "tray") }
                    .accessibilityLabel("Inbox, \(pending) new")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }

    private var pending: Int { model.backend.inbox.pending(at: .now).count }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct EmptyChat: View {
    let mascot: MascotHost
    @AppStorage(MascotSetting.key) private var mascotEnabled = MascotSetting.defaultValue

    var body: some View {
        VStack(spacing: 8) {
            if mascotEnabled {
                MascotView(host: mascot).frame(width: 200, height: 200)
                Text(lang("Hi Jan, frag mich was", "Hi Jan, ask me anything")).font(.title3.weight(.semibold))
            } else {
                Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.green)
                Text(lang("Frag Lotti, was du willst", "Ask Lotti anything")).font(.title3.weight(.semibold))
            }
            Text(lang("Tippe, oder halte das Mikrofon und sprich.", "Type, or hold the microphone and speak.")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// "Pair Lotti Brain" or "Offline" above the chat; nothing while connected.
private struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat

    var body: some View {
        if !model.isPaired {
            NavigationLink { BrainSettingsView() } label: {
                banner("Lotti Brain isn't set up. Pair it in Settings; until then only timers, navigation and reminders work.", "link.badge.plus")
            }
        } else if !chat.isOnline {
            banner(model.backend.state == .connecting ? "Connecting to Lotti Brain…" : "Offline: timers, navigation and reminders only.",
                   "wifi.slash")
        }
    }

    private func banner(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.15))
    }
}

struct WorkingRow: View {
    let text: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text ?? "Thinking…").foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }
}

// MARK: - Rows

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    let item: ChatItem
    let isLast: Bool

    var body: some View {
        switch item.kind {
        case .user: userBubble
        case .lotti: lottiBlock
        case .note: note
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
        case .catchup: catchup
        case .inbox:
            if let id = item.inboxId, let inboxItem = model.backend.inbox.item(id) { InboxCard(item: inboxItem) }
        case .divider:
            HStack {
                line
                Text(item.text).font(.caption).foregroundStyle(.secondary)
                line
            }
        }
    }

    private var line: some View { Rectangle().fill(.quaternary).frame(height: 1) }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(markdown(item.text))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                .textSelection(.enabled)
            if item.channel == .glasses {
                Label("via glasses", systemImage: "eyeglasses").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var lottiBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(markdown(item.text)).textSelection(.enabled)
            if item.offline || item.channel == .glasses {
                HStack(spacing: 10) {
                    if item.offline { Label("Offline answer", systemImage: "wifi.slash") }
                    if item.channel == .glasses { Label("via glasses", systemImage: "eyeglasses") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                ActionCard(action: action) {
                    Task { await chat.perform(action, in: item.id) }
                } dismiss: {
                    chat.dismiss(action, in: item.id)
                }
            }
            if let undo = item.undo { undoButton(undo) }
            if isLast, !item.followUps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(item.followUps, id: \.self) { followUp in
                            Button(followUp) { chat.send(followUp) }
                                .buttonStyle(.bordered)
                                .disabled(chat.isAsking)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 24)
    }

    private var note: some View {
        HStack {
            Label(item.text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            if let undo = item.undo { undoButton(undo) }
        }
    }

    /// Says Undo; the backend's label describes the inverse ("Remove Milch again") and reads like a
    /// new action, so it is only the accessibility hint.
    private func undoButton(_ undo: UndoAction) -> some View {
        Button {
            Task { await chat.undo(undo, in: item.id) }
        } label: {
            Label(lang("Rückgängig", "Undo"), systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .accessibilityHint(undo.label)
    }

    private var catchup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Catch-up", systemImage: "sun.horizon").font(.caption.weight(.semibold)).foregroundStyle(.green)
            Text(markdown(item.text)).textSelection(.enabled)
            Text(shortDate(item.at)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Simple inline Markdown (bold, italics, links, code); plain text when it doesn't parse.
func markdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

// MARK: - Composer

private struct ComposerBar: View {
    @Environment(ChatModel.self) private var chat
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = chat
        VStack(spacing: 4) {
            if let error = chat.voiceError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.isListening ? "Listening…" : "Message Lotti", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { chat.send(chat.draft) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                trailingButton
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var trailingButton: some View {
        if chat.isAsking {
            Button { chat.cancel() } label: { circle("stop.fill", .gray) }
                .accessibilityLabel("Stop")
        } else if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isListening {
            circle(chat.isListening ? "waveform" : "mic.fill", chat.isListening ? .red : .green)
                .onLongPressGesture(minimumDuration: 100, maximumDistance: 80, perform: {}, onPressingChanged: { pressing in
                    if pressing { focused = false; chat.beginTalking() } else { chat.endTalking() }
                })
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(chat.isListening ? "Stop talking" : "Hold to talk")
                .accessibilityHint(chat.isListening ? "Sends what you said." : "Activate to start listening, activate again to send.")
                // VoiceOver can't hold: activating toggles listening instead.
                .accessibilityAction {
                    if chat.isListening {
                        chat.endTalking()
                    } else {
                        focused = false
                        chat.beginTalking()
                    }
                }
        } else {
            Button { chat.send(chat.draft) } label: { circle("arrow.up", .green) }
                .accessibilityLabel("Send")
        }
    }

    private func circle(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color, in: Circle())
    }
}
