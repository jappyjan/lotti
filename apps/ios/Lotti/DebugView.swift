import LottiKit
import SwiftUI

/// What's going on inside: the glasses' screen, voice, brains, head angle, gestures, test buttons (Settings → Debug).
struct DebugView: View {
    let model: AppModel
    let brain: AppleBrain
    let navigation: NavigationController

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

    @Environment(\.scenePhase) private var scenePhase
    @State private var threshold = Settings.wakeThreshold
    @State private var recorder: WakeWordRecorder?

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
                    .disabled(recorder.activity != nil || !link.status.isConnected)
                Button("Record 30 × \"Hey Lotti\" in a row") { recorder.recordSeries() }
                    .disabled(recorder.activity != nil || !link.status.isConnected)
                if case .series = recorder.activity {
                    Button("Stop", role: .destructive) { recorder.stop() }
                }
                if recorder.activity == .background {
                    Button("Stop background", role: .destructive) { recorder.stop() }
                } else {
                    Button("Record background") { recorder.startBackground() }
                        .disabled(recorder.activity != nil || !link.status.isConnected)
                }
                if let busy = recorder.busyText { Text(busy).foregroundStyle(.secondary) }
                if let error = recorder.error { Text(error).foregroundStyle(.red) }
                LabeledContent("Saved", value: "\(recorder.counts["hey_lotti"] ?? 0) Hey Lotti, \(recorder.counts["background"] ?? 0) background")
            } header: {
                Text("Record training clips")
            } footer: {
                Text("From the glasses' mic (connect them first), saved in Documents/wakeword. \"Hey Lotti\" doesn't wake Lotti while recording; leaving this screen or locking the phone stops it. Copy them to packages/wake-word/data/user and retrain.")
            }
        }
    }

    var body: some View {
        List {
            Section("On the glasses") {
                if let screen = conductor.screen {
                    if let header = screen.header {
                        LabeledContent(header.left, value: header.right).font(.caption)
                    }
                    Text(screen.text).font(.headline)
                    ForEach(screen.details, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    if !screen.cards.isEmpty {
                        HStack(alignment: .top) {
                            ForEach(Array(screen.cards.enumerated()), id: \.offset) { _, card in
                                VStack(alignment: .leading) {
                                    Text(card.title).font(.subheadline.bold())
                                    ForEach(card.lines, id: \.self) { Text($0).font(.caption) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
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

            Section("Lotti") {
                LabeledContent("Brain", value: brain.unavailableReason ?? "Ready")
                LabeledContent("Microphone", value: conductor.microphoneSource ?? "Not used yet")
                LabeledContent("Last heard", value: conductor.lastHeard.map { $0.isEmpty ? "(nothing)" : $0 } ?? "–")
                LabeledContent("Reconnects", value: "\(model.reconnects)")
                LabeledContent("Lotti Brain", value: model.isPaired ? String(describing: model.backend.state) : "Not paired")
                if let problem = model.backend.lastError { Text(problem).font(.caption).foregroundStyle(.secondary) }
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

            Section("Head") {
                LabeledContent("Now", value: link.headPitch.map { String(format: "%.0f°", $0) } ?? "–")
                LabeledContent("Straight ahead", value: String(format: "%.0f°", link.headUpSettings.straightAhead))
                LabeledContent("Opens at", value: String(format: "%.0f°", link.headUpSettings.config.upAngle))
            }

            Section {
                LabeledContent("Wear state", value: String(describing: link.wearState))
                Button("Marker: glasses ON now") { link.addStateMarker("glasses ON") }
                Button("Marker: glasses OFF now") { link.addStateMarker("glasses OFF") }
                Button("Ask the glasses now") { Task { await link.checkWear() } }
                    .disabled(!link.status.isConnected)
                if link.stateTrace.isEmpty { Text("No answers from the glasses yet.").foregroundStyle(.secondary) }
                ForEach(link.stateTrace.reversed().prefix(30)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.time, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        Text(entry.isMarker ? "MARK \(entry.text)" : entry.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.isMarker ? .orange : .primary)
                    }
                }
            } header: {
                Text("Wear capture")
            } footer: {
                Text("The glasses only say whether they're worn when asked, so Lotti asks every 10 seconds. Take them off and put them on, tap the matching marker, and check that the answers follow. Changes and markers are also written to the log.")
            }

            if link.status.isConnected {
                Section("Try") {
                    Button("Show today view") { conductor.handle(InputEvent(.doubleTap, from: .unknown)) }
                    Button("Ask \"What's on today?\"") { conductor.ask("What's on today?") }
                    Button("Ask \"Timer for 10 minutes\"") { conductor.ask("Set a timer for 10 minutes") }
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
        .onAppear { if recorder == nil { recorder = WakeWordRecorder(conductor: conductor) } }
        // No recording you can't see (or stop).
        .onDisappear { recorder?.stop() }
        // Nor in the background or with the phone locked.
        .onChange(of: scenePhase) { _, phase in if phase != .active { recorder?.stop() } }
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
