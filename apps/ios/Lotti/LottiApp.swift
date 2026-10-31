import LottiKit
import SwiftUI

@main
struct LottiApp: App {
    @State private var model = AppModel(link: G2Link())

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.launch() }
        }
    }
}
