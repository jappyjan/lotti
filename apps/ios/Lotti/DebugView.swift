import LottiKit
import SwiftUI

/// What's going on inside: the glasses' screen, voice, brain, head angle, gestures, test buttons.
struct DebugView: View {
    let model: AppModel
    let brain: AppleBrain
    let hermes: HermesBrain
    let navigation: NavigationController

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

    @State private var displayStyle: DisplayStyle = Settings.displayStyle
    @State private var threshold = Settings.wakeThreshold
    @State private var recorder: WakeWordRecorder?

    private func setDisplayStyle(_ style: DisplayStyle) {
        Settings.displayStyle = style
        conductor.setDisplayStyle(style)
    }

    private var wakeStateText: String {
        switch conductor.wakeState {
        case .off: "Off"
        case .listening: "Listening"
        case .unavailable(let reason): "Glasses mic unavailable (\(reason))"
        }
    }

    @ViewBuilder private var wakeSection: some View {
        Section {
            LabeledContent("State", value: wakeStateText)
            LabeledContent("Last score", value: conductor.wakeScore.map { String(format: "%.2f", $0) } ?? "–")
            LabeledContent("Last candidate", value: conductor.wakeLast ?? "–")
            LabeledContent("Ran", value: String(format: "%.1f min classifier, %.1f min speech",
                                                conductor.wakeMinutes.stage1, conductor.wakeMinutes.stage2))
            VStack(alignment: .leading) {
                Text(String(format: "Threshold %.2f", threshold))
                Slider(value: $threshold, in: 0.5...0.99, step: 0.01)
                    .onChange(of: threshold) { _, value in
                        Settings.wakeThreshold = value
                        conductor.wakeThreshold = value
                    }
            }
        } header: {
            Text("Hey Lotti")
        }

        if let recorder {
            Section {
                Button("Record \"Hey Lotti\" (2 s)") { recorder.recordPhrase() }
                    .disabled(recorder.busy != nil || !link.status.isConnected)
                Button("Record 30 × \"Hey Lotti\" in a row") { recorder.recordSeries() }
                    .disabled(recorder.busy != nil || !link.status.isConnected)
                if recorder.isSeries {
                    Button("Stop", role: .destructive) { recorder.stop() }
                }
                if recorder.busy == "Recording background…" {
                    Button("Stop background", role: .destructive) { recorder.stop() }
                } else {
                    Button("Record background") { recorder.startBackground() }
                        .disabled(recorder.busy != nil || !link.status.isConnected)
                }
                if let busy = recorder.busy { Text(busy).foregroundStyle(.secondary) }
                if let error = recorder.error { Text(error).foregroundStyle(.red) }
                LabeledContent("Saved", value: "\(recorder.counts["hey_lotti"] ?? 0) Hey Lotti, \(recorder.counts["background"] ?? 0) background")
            } header: {
                Text("Record training clips")
            } footer: {
                Text("From the glasses' mic, saved in Documents/wakeword. Copy them to packages/wake-word/data/user and retrain.")
            }
        }
    }

    var body: some View {
        List {
            Section("On the glasses") {
                if let screen = conductor.screen {
                    Text(screen.text).font(.headline)
                    ForEach(screen.details, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    if let rail = screen.rail {
                        ForEach(Array(rail.items.enumerated()), id: \.offset) { index, item in
                            Label(item.title, systemImage: index == rail.highlighted ? "chevron.right.circle.fill" : "circle")
                                .foregroundStyle(index == rail.highlighted ? .green : .secondary)
                        }
                    }
                } else {
                    Text("Display off").foregroundStyle(.secondary)
                }
                LabeledContent("Mode", value: String(describing: conductor.mode))
            }

            Section("Display layout") {
                Picker("Choices", selection: $displayStyle) {
                    Text("Choices below (default)").tag(DisplayStyle.choicesBelow)
                    Text("Wider rail, 3 choices").tag(DisplayStyle.wideRail)
                    Text("Rail (old)").tag(DisplayStyle.rail)
                }
                .onChange(of: displayStyle) { _, style in setDisplayStyle(style) }
            }

            Section("Lotti") {
                LabeledContent("Brain", value: brain.unavailableReason ?? "Ready")
                LabeledContent("Microphone", value: conductor.microphoneSource ?? "Not used yet")
                LabeledContent("Last heard", value: conductor.lastHeard.map { $0.isEmpty ? "(nothing)" : $0 } ?? "–")
                LabeledContent("Reconnects", value: "\(model.reconnects)")
                if let error = conductor.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }

            wakeSection

            Section("On-device brain, last answer") {
                if brain.trace.isEmpty { Text("Nothing asked yet.").foregroundStyle(.secondary) }
                ForEach(Array(brain.trace.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }

            Section("Hermes") {
                if let session = hermes.sessionID {
                    LabeledContent("Session") {
                        Text(session).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if hermes.trace.isEmpty {
                    Text(hermes.isConfigured ? "Nothing asked since launch." : "Not set up.").foregroundStyle(.secondary)
                }
                ForEach(Array(hermes.trace.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }

            Section("Head") {
                LabeledContent("Now", value: link.headPitch.map { String(format: "%.0f°", $0) } ?? "–")
                LabeledContent("Straight ahead", value: String(format: "%.0f°", link.headUpSettings.straightAhead))
                LabeledContent("Opens at", value: String(format: "%.0f°", link.headUpSettings.config.upAngle))
            }

            if link.status.isConnected {
                Section("Try") {
                    Button("Show today view") { conductor.handle(InputEvent(.tap, from: .unknown)) }
                    Button("Ask \"What's on today?\"") { conductor.ask("What's on today?") }
                    Button("Ask \"Timer for 10 minutes\"") { conductor.ask("Set a timer for 10 minutes") }
                    if hermes.isConfigured {
                        Button("Ask Hermes about tomorrow") { conductor.ask("How does tomorrow look?", onHermes: true) }
                    }
                }
            }

            Section("Navigation maps") {
                mapPreview("Mini map", image: navigation.renderer.lastMini)
                mapPreview("Full map", image: navigation.renderer.lastFull)
            }

            Section("Last input") {
                if model.inputs.isEmpty {
                    Text("Tap a touchpad or use the ring.").foregroundStyle(.secondary)
                }
                ForEach(model.inputs) { input in
                    LabeledContent {
                        Text(input.time, format: .dateTime.hour().minute().second())
                    } label: {
                        Text(input.event.gesture.rawValue)
                        Text(input.event.source.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Debug")
        .onAppear { if recorder == nil { recorder = WakeWordRecorder(hub: conductor.microphone) } }
    }

    /// The last map bitmap the glasses got, or a placeholder. Tap for the full-size image.
    @ViewBuilder private func mapPreview(_ name: String, image: UIImage?) -> some View {
        if let image {
            NavigationLink {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .navigationTitle(name)
            } label: {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 96)
                        .background(Color.black)
                    VStack(alignment: .leading) {
                        Text(name)
                        Text("\(Int(image.size.width))×\(Int(image.size.height)) px")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        } else {
            Text("\(name): nothing sent yet.").foregroundStyle(.secondary)
        }
    }
}
