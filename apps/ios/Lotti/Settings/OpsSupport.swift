import LottiKit
import SwiftUI

/// Loads something from the management API and shows it: a spinner while loading, the error with
/// "Try again" if it fails, and your content (a List or Form) once there is a value. Pull to
/// refresh reloads. `content` gets the value and a `reload` it can call after a change.
struct Loaded<Value, Content: View>: View {
    @Environment(AppModel.self) private var model
    let load: @MainActor (AppModel) async throws -> Value
    @ViewBuilder let content: (Value, @escaping @MainActor () async -> Void) -> Content

    @State private var value: Value?
    @State private var failure: String?

    var body: some View {
        Group {
            if !model.isPaired {
                ContentUnavailableView("Lotti Brain isn't paired", systemImage: "link.badge.plus",
                                       description: Text("Pair it in Settings → Lotti Brain."))
            } else if let value {
                content(value) { await reload() }
            } else if let failure {
                List {
                    Section {
                        Text(failure).foregroundStyle(.red)
                        Button("Try again") { Task { await reload() } }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await reload() }
        .onChange(of: model.isPaired) { Task { await reload() } }
        .refreshable { await reload() }
    }

    @MainActor private func reload() async {
        guard model.isPaired else { return }
        do {
            value = try await load(model)
            failure = nil
        } catch {
            // Keep what was shown; only a first load shows the error in place.
            if value == nil { failure = error.localizedDescription }
        }
    }
}

/// Runs `work`; a failure goes to `message` (see `errorAlert`).
@MainActor
func attempt(_ message: Binding<String?>, _ work: @MainActor () async throws -> Void) async {
    do { try await work() } catch { message.wrappedValue = error.localizedDescription }
}

extension View {
    /// An alert with the text in `message`, cleared when dismissed.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("That didn't work", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
              actions: { Button("OK", role: .cancel) {} }, message: { Text(message.wrappedValue ?? "") })
    }
}

/// A row for a status: a name on the left, a coloured dot and text on the right.
struct StatusRow: View {
    let title: String
    let value: String
    var good: Bool?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let good { Circle().fill(good ? Color.green : Color.orange).frame(width: 8, height: 8) }
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

/// A write-only secret field: it never shows what is stored, only lets you replace it.
struct SecretField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        SecureField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
