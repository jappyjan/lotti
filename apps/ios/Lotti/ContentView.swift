import LottiKit
import SwiftUI

/// The app: a chat with Lotti. Settings, the inbox and past conversations are one tap away.
struct ContentView: View {
    let model: AppModel
    let chat: ChatModel
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var linkMessage: String?

    var body: some View {
        NavigationStack { ChatView() }
            .environment(model)
            .environment(chat)
            .environment(services)
            .tint(.green)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.didBecomeActive() }
            }
            .onOpenURL { url in open(url) }
            .errorAlert($linkMessage)
    }

    /// `lotti://pair?url=…&code=…` (from the QR code, scanned with the camera app) pairs the phone.
    private func open(_ url: URL) {
        guard url.scheme == "lotti", url.host() == "pair" else { return }
        Task {
            await attempt($linkMessage) {
                if try await !model.pair(link: url.absoluteString) { linkMessage = "That isn't a Lotti pairing link." }
            }
        }
    }
}
