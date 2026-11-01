import LottiKit
import SwiftUI
import UIKit

@main
struct LottiApp: App {
    @State private var model: AppModel
    private let speech: AppleSpeechRecognizer
    private let brain: AppleBrain

    init() {
        let link = G2Link()
        let speech = AppleSpeechRecognizer(locale: Locale(identifier: Settings.speechLanguage))
        let brain = AppleBrain()
        let conductor = Conductor(link: link, brain: brain, speech: speech, phoneMicrophone: PhoneMicrophone(),
                                  today: DeviceToday())
        self.speech = speech
        self.brain = brain
        _model = State(initialValue: AppModel(link: link, conductor: conductor))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, speech: speech, brain: brain)
                .task { await model.launch() }
                .task { await model.keepConnected() }
                .task { await model.conductor.run() }
                .task { await model.receiveInputs() }
                .task { await model.runLaunchArguments() }
                .onAppear {
                    // Debug runs stream the console; a locked phone stops `devicectl` launches.
                    if ProcessInfo.processInfo.arguments.contains("--awake") {
                        UIApplication.shared.isIdleTimerDisabled = true
                    }
                }
        }
    }
}

enum Settings {
    static let speechLanguageKey = "speechLanguage"
    static let languages = [("de-DE", "Deutsch"), ("en-US", "English")]

    /// The language you speak to Lotti in. Defaults to the phone's language if it's German.
    static var speechLanguage: String {
        UserDefaults.standard.string(forKey: speechLanguageKey)
            ?? (Locale.current.language.languageCode?.identifier == "de" ? "de-DE" : "en-US")
    }
}
