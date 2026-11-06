import LottiKit
import SwiftUI

/// Everything about Lotti that isn't the chat. Each row is a plain list screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppServices.self) private var services
    @AppStorage(Settings.speechLanguageKey) private var speechLanguage = Settings.speechLanguage
    @AppStorage(Settings.wispUpdateKey) private var wispUpdate = false

    var body: some View {
        List {
            Section {
                NavigationLink { BrainSettingsView() } label: {
                    row("Lotti Brain", "server.rack", brainStatus)
                }
                NavigationLink { ProvidersView() } label: { row("AI providers", "cpu", nil) }
                NavigationLink { AccountsView() } label: { row("Accounts", "person.crop.circle", nil) }
                NavigationLink { McpView() } label: { row("MCP servers", "puzzlepiece.extension", nil) }
            }
            Section {
                NavigationLink { JobsView() } label: { row("Scheduled jobs", "clock", nil) }
                NavigationLink { MemoryView() } label: { row("Memory", "brain", nil) }
                NavigationLink { SkillsView() } label: { row("Skills & scripts", "wand.and.stars", nil) }
                NavigationLink { InboxSettingsView() } label: { row("Inbox & catch-up", "tray", nil) }
            }
            Section {
                NavigationLink { GlassesSettingsView() } label: { row("Glasses", "eyeglasses", glassesStatus) }
                NavigationLink { PhoneToolsView() } label: { row("Phone tools", "iphone", nil) }
                Picker("I speak", selection: $speechLanguage) {
                    ForEach(Settings.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: speechLanguage) { _, new in
                    services.speech.locale = Locale(identifier: new)
                    Task { await services.speech.prepare() }
                }
            }
            Section {
                NavigationLink { PrivacyView() } label: { row("Privacy", "hand.raised", nil) }
                NavigationLink { PushView() } label: { row("Push notifications", "bell.badge", nil) }
                NavigationLink { AdvancedSettingsView() } label: { row("Advanced", "slider.horizontal.3", nil) }
                NavigationLink { DebugView(model: model, brain: services.brain, navigation: services.navigation) } label: { row("Debug", "ladybug", nil) }
            }
            Section {
                Toggle(isOn: $wispUpdate) { Label("Wisp update screen", systemImage: "hammer") }
                if wispUpdate {
                    NavigationLink { WispUpdateView() } label: { row("Wisp update (rung 1)", "cpu.fill", nil) }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Off by default. Shows the rung-1 firmware screen for Wisp development (docs/wisp/safety.md). Don't turn it on unless you are flashing with Jan's go.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ icon: String, _ value: String?) -> some View {
        LabeledContent {
            if let value { Text(value).foregroundStyle(.secondary) }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private var brainStatus: String {
        guard model.isPaired else { return "Not paired" }
        return model.backend.state == .connected ? "Connected" : "Offline"
    }

    private var glassesStatus: String { model.link.status.isConnected ? "Connected" : "Not connected" }
}
