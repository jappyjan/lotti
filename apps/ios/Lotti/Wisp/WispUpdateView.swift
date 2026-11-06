import LottiKit
import SwiftUI
import UIKit

/// Settings → Developer → Wisp update (only with the developer setting on). Builds the model;
/// the screen itself is `WispUpdateScreen`.
struct WispUpdateView: View {
    @Environment(AppModel.self) private var app
    @State private var model: WispUpdateModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                WispUpdateScreen(model: model)
            } else if let loadError {
                ContentUnavailableView("Wisp update unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Wisp update")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        guard model == nil else { return }
        do {
            let engine = try WispOtaEngine(bundle: .main)
            let store = try WispStockStore(engine: engine)
            model = WispUpdateModel(engine: engine, store: store, log: WispLog(), access: try Self.access(for: app))
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    static func access(for app: AppModel) throws -> any WispTempleAccess {
        #if targetEnvironment(simulator)
        // No Bluetooth in the Simulator: wisp-ota's fake stock temple (Simulator builds only).
        if let fake = try? WispFakeTempleAccess(bundle: .main, stockVersion: "2.4.0.24") { return fake }
        #endif
        guard let link = app.link as? G2Link else { throw WispOtaEngine.EngineError.javaScript("No G2 link in this build.") }
        return G2TempleAccess(link: link)
    }
}

struct WispUpdateScreen: View {
    @Bindable var model: WispUpdateModel
    @Environment(AppModel.self) private var app
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            intro
            templeSection
            readSection
            stockSection
            prepareSection
            sendSection
            logSection
        }
        .font(.subheadline)
        .navigationBarBackButtonHidden(model.isSending)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            model.screenClosed()
            if !model.isSending { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Sections

    private var intro: some View {
        Section {
            Label("Rung 1 only. Every send needs Jan's explicit go in chat (safety.md rule 4). One temple per send, left first.",
                  systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
            if model.access is WispFakeTempleAccess {
                Label("Simulated temple (wisp-ota fake stock temple). No glasses involved.", systemImage: "testtube.2")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var templeSection: some View {
        Section {
            Picker("Temple", selection: $model.temple) {
                Text("Left").tag(G2Side.left)
                Text("Right").tag(G2Side.right)
            }
            .pickerStyle(.segmented)
            .disabled(model.isSending || model.busy != nil)
            if let blocker = model.access.blocker {
                Text(blocker).foregroundStyle(.red)
                Button("End the Lotti glasses session") { app.disconnect() }
            }
        } header: {
            Text("Temple")
        } footer: {
            Text("The screen keeps the phone awake. Keep Lotti in the foreground until the result shows.")
        }
    }

    private var readSection: some View {
        Section {
            Button {
                Task { await model.readVersion() }
            } label: {
                Label("Read version and battery", systemImage: "info.circle")
            }
            .disabled(model.busy != nil || model.isSending)
            if model.systemConnectionSeen {
                systemConnection
                Button {
                    Task { await model.readVersion() }
                } label: {
                    Label("Retry read", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy != nil || model.isSending)
            }
            if let rb = model.readback {
                LabeledContent("\(model.temple.rawValue.capitalized) version", value: rb.version(of: model.temple) ?? "–")
                LabeledContent("Battery (as reported by the right temple)", value: rb.battery.map { "\($0) %\(rb.charging ? " (charging)" : "")" } ?? "unreadable")
                if let stock = model.stockVersion {
                    LabeledContent("Stock base", value: stock)
                }
            }
        } header: {
            Text("1 · Read")
        } footer: {
            Text("Read-only: opens only the right arm, asks for its settings (sid 0x09), closes it again. The right arm reports both temples' versions and one battery value; the left arm doesn't answer this read.")
        }
    }

    private var stockSection: some View {
        Section {
            Button {
                Task { await model.fetchStock() }
            } label: {
                Label(model.stockVersion.map { "Get stock \($0)" } ?? "Get stock bundle", systemImage: "arrow.down.circle")
            }
            .disabled(model.stockVersion == nil || model.busy != nil || model.isSending)
            if let stock = model.stock {
                LabeledContent("Version", value: stock.release.version)
                LabeledContent("Size", value: "\(stock.bytes.count) bytes")
                hash("SHA-256", stock.sha256)
                LabeledContent("Pinned", value: stock.check.pinnedOfficial && stock.sha256 == stock.release.sha256 ? "✓ matches the catalog" : "✗")
            }
        } header: {
            Text("2 · Stock bundle")
        } footer: {
            Text("From Even's CDN, checked against the pinned size and SHA-256 like `wisp-ota fetch`, cached in the app.")
        }
    }

    private var prepareSection: some View {
        Section {
            HStack {
                Text("New version")
                TextField("2.2.6.19", text: $model.rung1Version)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .monospaced()
            }
            Button {
                Task { await model.prepareRung1() }
            } label: {
                Label("Repack for rung 1", systemImage: "shippingbox")
            }
            .disabled(model.stock == nil || model.busy != nil || model.isSending)
            Button {
                Task { await model.prepareStockBack() }
            } label: {
                Label("Prepare pure stock (round trip back)", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.stock == nil || model.busy != nil || model.isSending)
            if let p = model.prepared {
                LabeledContent("Bundle", value: p.info.kind == .rung1 ? "\(p.info.fromVersion) → \(p.info.toVersion)" : "pure stock \(p.info.toVersion)")
                LabeledContent("Guard report") {
                    Text(p.info.sendable ? "SENDABLE" : "NOT SENDABLE")
                        .bold()
                        .foregroundStyle(p.info.sendable ? .green : .red)
                }
                if let digest = model.preparedSHA256 { hash("SHA-256", digest) }
                DisclosureGroup("Guards (verify)") { mono(p.info.verifyText) }
                DisclosureGroup("Structural diff against stock") { mono(p.info.diffText) }
            }
        } header: {
            Text("3 · Repack and verify")
        } footer: {
            Text("Rung 1 changes only the version string; both CRC layers are recomputed. The diff must show nothing else.")
        }
    }

    private var sendSection: some View {
        Section {
            ForEach(model.gates) { gate in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: gate.ok ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(gate.ok ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(gate.title)
                        if let detail = gate.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if model.systemConnectionSeen {
                systemConnection
            }
            Toggle(isOn: $model.evenAppAcknowledged) {
                Text("The Even app is force-quit and won't reconnect during the update")
            }
            .disabled(model.isSending)
            TextField("Type \"\(model.temple.rawValue)\" to confirm", text: $model.typedTemple)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .disabled(model.isSending)
            Button(role: .destructive) {
                typing = false
                Task { await model.send() }
            } label: {
                Label("Send to the \(model.temple.rawValue) temple", systemImage: "antenna.radiowaves.left.and.right")
                    .bold()
            }
            .disabled(!model.canSend)
            if model.isSending || model.progress != nil {
                progressView
            }
            if model.isSending {
                Button("Abort", role: .cancel) { model.abort() }
                    .disabled(!model.canAbort)
            }
            if let busy = model.busy {
                HStack { ProgressView(); Text(busy) }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            if let final = model.final { finalView(final) }
        } header: {
            Text("4 · Send")
        } footer: {
            Text("Right before sending, the status is read again through the right arm: battery and version must still pass. For the left temple the right arm is closed again before the left arm is opened; never both at once. Abort works only until RESULT_CHECK.")
        }
    }

    /// Shown after an open was refused because the arm is already connected to the phone. The
    /// toggle is for the next attempt only: one read (right arm), or one send (right arm for the
    /// re-read, then the target arm).
    @ViewBuilder private var systemConnection: some View {
        let arms = model.systemConnectedArms.map(\.rawValue).sorted()
        Text("The \(arms.joined(separator: " and ")) \(arms.count > 1 ? "arms are" : "arm is") already connected to this phone. If Lotti and the Even app are both closed, iOS itself holds the connection (Settings → Bluetooth shows the glasses as Connected), and Lotti can connect on top of it.")
            .foregroundStyle(.orange)
        Toggle(isOn: $model.systemConnectionAccepted) {
            Text("Lotti and the Even app are both closed. iOS itself holds this connection (Settings → Bluetooth shows it as Connected).")
        }
        .disabled(model.isSending || model.busy != nil)
        Text("Applies to the next attempt only, then turns off again: one read (opens the right arm), or one send (opens the right arm for the re-read, closes it, then opens the \(model.temple.rawValue) arm).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = model.progress {
                ProgressView(value: Double(p.bytesAcked), total: Double(max(p.totalBytes, 1)))
                Text(verbatim: "\(p.state) · block \(min(p.block, p.blocks))/\(p.blocks) · \(p.bytesAcked / 1024)/\(p.totalBytes / 1024) KiB · run \(max(p.componentAttempt, 1))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func finalView(_ final: WispUpdateModel.Final) -> some View {
        switch final {
        case .success(let text):
            Label { Text("\(Text("Success.").bold()) \(text)") } icon: { Image(systemName: "checkmark.seal.fill") }
                .foregroundStyle(.green)
        case .failedStockIntact(let text):
            Label { Text("\(Text("Failed, stock intact.").bold()) \(text)") } icon: { Image(systemName: "xmark.octagon") }
                .foregroundStyle(.orange)
        case .resultUnknown(let text):
            Label { Text("\(Text("Result unknown.").bold()) Do nothing else; reconnect and read the version. \(text)") } icon: {
                Image(systemName: "questionmark.diamond.fill")
            }
            .foregroundStyle(.red)
        }
    }

    private var logSection: some View {
        Section {
            ForEach(model.log.entries.suffix(6).reversed()) { entry in
                Text(entry.text).font(.caption2.monospaced()).lineLimit(3)
            }
            NavigationLink("Full log") { WispLogView(log: model.log) }
            ShareLink(item: model.log.url) { Label("Export log", systemImage: "square.and.arrow.up") }
        } header: {
            Text("Log")
        } footer: {
            Text("Every step with its SHA-256s, for the hardware log in docs/wisp/safety.md.")
        }
    }

    private func hash(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func mono(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).fixedSize()
        }
    }
}

struct WispLogView: View {
    let log: WispLog

    var body: some View {
        List(log.entries.reversed()) { entry in
            Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
        }
        .navigationTitle("Wisp log")
        .toolbar { ShareLink(item: log.url) }
    }
}
