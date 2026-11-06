import CoreML
import LottiKit
import SwiftUI
import UIKit

/// What the settings screens need besides the models.
@Observable
final class AppServices {
    let speech: AppleSpeechRecognizer
    let brain: AppleBrain
    let navigation: NavigationController

    init(speech: AppleSpeechRecognizer, brain: AppleBrain, navigation: NavigationController) {
        self.speech = speech
        self.brain = brain
        self.navigation = navigation
    }
}

@main
struct LottiApp: App {
    @State private var model: AppModel
    @State private var chat: ChatModel
    private let services: AppServices
    #if LOTTI_APNS
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    #endif

    init() {
        LogFile.start()
        // Earlier builds talked to Hermes; the app is Lotti Brain only now.
        for key in ["hermesConversation", "hermesConversationMinutes", "hermesSession", "hermesAddress", "hermesHiddenReads"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let link = G2Link()
        if ProcessInfo.processInfo.arguments.contains("--imu-log") { link.imuLogInterval = 0.25 }
        link.headUpSettings = Settings.headUp
        let speech = AppleSpeechRecognizer(locale: Locale(identifier: Settings.speechLanguage))
        let today = DeviceToday()
        let navigation = NavigationController(link: link, today: today)
        let tools = PhoneTools.all(today: today, startNavigation: { [weak navigation] destination, mode in
            guard let navigation else { throw ToolError("Navigation is not available.") }
            return try await navigation.start(destination: destination, mode: mode)
        })
        let toolbox = Toolbox(tools)
        // Offline: only timers, navigation, reminders and the local day (Apple's model when the phone has it).
        let offlineTools = Toolbox(tools.filter { PhoneTools.onDevice.contains($0.spec.name) })
        let apple = AppleBrain(tools: offlineTools)
        let offline = OfflineChoice(primary: apple, primaryAvailable: { [apple] in apple.unavailableReason == nil },
                                    fallback: OfflineBrain(tools: offlineTools))
        // Lotti Brain: the backend calls `location` and `reminders` on this phone.
        let backend = BackendClient(toolbox: toolbox)
        backend.allowedTools = ["location", "reminders"]
        let microphone = PhoneMicrophone()
        let conductor = Conductor(link: link, brain: offline, remote: BackendBrain(client: backend, channel: .glasses), backend: backend,
                                  toolbox: toolbox, timers: AlarmTimers(), speech: speech, phoneMicrophone: microphone,
                                  today: today, wakeDetector: Self.wakeDetector())
        let model = AppModel(link: link, conductor: conductor, backend: backend, deviceName: UIDevice.current.name,
                             appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
        let chat = ChatModel(backend: backend, offline: offline, toolbox: toolbox, speech: speech, microphone: microphone)
        chat.loadTurns = { [weak model] id in
            guard let model else { return [] }
            return try await model.call("conversations.get", ["id": .string(id)])["turns"]?.array?.compactMap(TurnInfo.init) ?? []
        }
        PushRegistration.onToken = { [weak model] token in model?.setAPNsToken(token) }
        services = AppServices(speech: speech, brain: apple, navigation: navigation)
        _model = State(initialValue: model)
        _chat = State(initialValue: chat)
    }

    /// The "Hey Lotti" classifier from the bundled model, or nil if it isn't there.
    private static func wakeDetector() -> WakeWordDetector? {
        guard let url = Bundle.main.url(forResource: "HeyLotti", withExtension: "mlmodelc"),
              let classifier = try? SoundAnalysisClassifier(contentsOf: url) else {
            print("[Wake] HeyLotti model missing, wake word off")
            return nil
        }
        return WakeWordDetector(classifier: classifier, threshold: Settings.wakeThreshold)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, chat: chat, services: services)
                .task { await PhoneTools.requestAccess() }
                .task {
                    await model.conductor.setHeadTracking(Settings.headUpEnabled)
                    await model.launch()
                }
                .task {
                    model.startBackend()
                    model.didBecomeActive()
                    await model.observeBackend()
                }
                .task { await chat.run() }
                .task { await PushRegistration.register() }
                .task { await model.keepConnected() }
                .task { model.conductor.setWakeWord(enabled: Settings.wakeWordEnabled) }
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

    static let wakeWordKey = "wakeWordEnabled"
    static let wakeThresholdKey = "wakeThreshold"

    /// Listen for "Hey Lotti" whenever the glasses are connected. On by default.
    static var wakeWordEnabled: Bool {
        get { UserDefaults.standard.object(forKey: wakeWordKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: wakeWordKey) }
    }

    /// How sure the sound classifier must be to start checking a candidate (Debug).
    static var wakeThreshold: Double {
        get { UserDefaults.standard.object(forKey: wakeThresholdKey) as? Double ?? WakeWordDetector.defaultThreshold }
        set { UserDefaults.standard.set(newValue, forKey: wakeThresholdKey) }
    }

    static let wispUpdateKey = "developer.wispUpdate"

    /// Settings → Developer → "Wisp update screen". Off by default; shows the rung-1 firmware
    /// update screen (`WispUpdateView`) when on.
    static var wispUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: wispUpdateKey) as? Bool ?? false
    }

    static let speechLanguageKey = "speechLanguage"
    static let languages = [("de-DE", "Deutsch"), ("en-US", "English")]

    /// The language you speak to Lotti in. Defaults to the phone's language if it's German.
    static var speechLanguage: String {
        UserDefaults.standard.string(forKey: speechLanguageKey)
            ?? (Locale.current.language.languageCode?.identifier == "de" ? "de-DE" : "en-US")
    }
}
