import LottiKit
import SwiftUI

/// What's going on inside: the glasses' screen, voice, brain, head angle, gestures, test buttons.
struct DebugView: View {
    let model: AppModel
    let brain: AppleBrain

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

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

            Section("Lotti") {
                LabeledContent("Brain", value: brain.unavailableReason ?? "Ready")
                LabeledContent("Microphone", value: conductor.microphoneSource ?? "Not used yet")
                LabeledContent("Last heard", value: conductor.lastHeard.map { $0.isEmpty ? "(nothing)" : $0 } ?? "–")
                LabeledContent("Reconnects", value: "\(model.reconnects)")
                if let error = conductor.lastError {
                    Text(error).foregroundStyle(.red)
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
                }
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
    }
}
