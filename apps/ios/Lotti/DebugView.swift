import LottiKit
import SwiftUI

/// What's going on inside: the glasses' screen, voice, brains, head angle, gestures, test buttons (Settings → Debug).
struct DebugView: View {
    let model: AppModel
    let brain: AppleBrain
    let navigation: NavigationController

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

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
                if link.stateTrace.isEmpty { Text("No state messages from the glasses yet.").foregroundStyle(.secondary) }
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
                Text("Take the glasses off and put them on. Tap the matching marker at the same moment. Every state message the glasses send is listed here and written to the log with the markers.")
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
