import BrainEval
import SwiftUI

/// Spike S3: a throwaway screen to run the brain eval on the phone.
@available(iOS 27.0, *)
struct EvalView: View {
    @State private var controller = EvalController()
    @State private var choice: EvalModelChoice = .apple

    var body: some View {
        List {
            Section {
                Picker("Model", selection: $choice) {
                    ForEach(EvalModelChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(controller.status).foregroundStyle(.secondary)
            } footer: {
                Text("Gemma downloads 3.6 GB (E2B) or 5.2 GB (E4B) on first use. Use Wi-Fi.")
            }

            Section("Run") {
                Button("Run eval (all \(EvalTask.allCases.count) tasks)") { controller.runEval(choice) }
                Button("Soak: 30 min back-to-back") { controller.runSoak(choice) }
                Button("Background probe: 10 min, lock the phone") { controller.runBackgroundProbe(choice) }
                Button("Cancel", role: .destructive) { controller.cancel() }
                    .disabled(!controller.isRunning)
            }

            if !controller.lastSummaries.isEmpty {
                Section("Last run") {
                    ForEach(controller.lastSummaries, id: \.task) { s in
                        LabeledContent(s.task.rawValue) {
                            Text("\(s.passed)/\(s.cases) · \(s.medianTotalMs ?? 0) ms")
                        }
                    }
                }
            }
        }
        .navigationTitle("Brain eval")
    }
}
