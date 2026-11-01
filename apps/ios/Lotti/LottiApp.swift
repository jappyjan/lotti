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
        if ProcessInfo.processInfo.arguments.contains("--imu-log") { link.imuLogInterval = 0.25 }
        link.headUpSettings = Settings.headUp
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
                .task {
                    await model.conductor.setHeadTracking(Settings.headUpEnabled)
                    await model.launch()
                }
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
    static let hiddenCalendarsKey = "hiddenCalendars"

    /// Calendars you switched off. New calendars show up by default.
    static var hiddenCalendars: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenCalendarsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenCalendarsKey) }
    }

    static let headUpKey = "headUp"
    static let headUpEnabledKey = "headUpEnabled"

    static var headUp: HeadUpSettings {
        get {
            UserDefaults.standard.data(forKey: headUpKey).flatMap { try? JSONDecoder().decode(HeadUpSettings.self, from: $0) }
                ?? HeadUpSettings()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: headUpKey) }
    }

    static var headUpEnabled: Bool {
        get { UserDefaults.standard.object(forKey: headUpEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: headUpEnabledKey) }
    }

    static let speechLanguageKey = "speechLanguage"
    static let languages = [("de-DE", "Deutsch"), ("en-US", "English")]

    /// The language you speak to Lotti in. Defaults to the phone's language if it's German.
    static var speechLanguage: String {
        UserDefaults.standard.string(forKey: speechLanguageKey)
            ?? (Locale.current.language.languageCode?.identifier == "de" ? "de-DE" : "en-US")
    }
}
