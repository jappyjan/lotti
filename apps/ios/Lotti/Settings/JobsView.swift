import LottiKit
import SwiftUI

/// Scheduled jobs: prompts Lotti runs on a schedule (a morning brief, a weekly summary …) plus the
/// built-ins (meeting reminders, mail triage, dreaming), which you can edit and switch off.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        Loaded(load: { model in try await model.call("jobs.list").items.compactMap(JobInfo.init) }) { jobs, reload in
            List {
                Section {
                    ForEach(jobs) { job in
                        NavigationLink { JobDetailView(job: job) } label: { row(job, reload) }
                    }
                } footer: {
                    Text("Built-in jobs can be switched off or re-timed, not deleted. \"No AI\" jobs are plain code and cost no tokens; the others call your AI provider.")
                }
                Section {
                    Button("New job", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                NavigationStack { JobDetailView(job: nil) { await reload() } }
            }
            .errorAlert($error)
        }
        .navigationTitle("Scheduled jobs")
    }

    private func row(_ job: JobInfo, _ reload: @escaping @MainActor () async -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).foregroundStyle(job.enabled ? .primary : .secondary)
                Text(job.scheduleLabel).font(.caption).foregroundStyle(.secondary)
                if let summary = job.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(job.aiBadge).font(.caption2.weight(.medium)).foregroundStyle(job.ai == "none" ? .green : .orange)
                Text("Next \(shortDate(job.nextRunAt)) · last \(shortDate(job.lastRunAt))").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { on in
                Task {
                    await attempt($error) { _ = try await model.call("jobs.update", ["id": .string(job.id), "enabled": .bool(on)]) }
                    await reload()
                }
            }))
            .labelsHidden()
        }
    }
}

/// A job: create (`job == nil`) or edit, run now, history, delete.
struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: JobInfo?
    var done: @MainActor () async -> Void = {}
    @State private var name: String
    @State private var prompt: String
    @State private var schedule: ScheduleDraft
    @State private var enabled: Bool
    @State private var settingValue = ""
    @State private var history: [JobRunInfo] = []
    @State private var runNote: String?
    @State private var running = false
    @State private var confirmDelete = false
    @State private var error: String?

    init(job: JobInfo?, done: @escaping @MainActor () async -> Void = {}) {
        self.job = job
        self.done = done
        _name = State(initialValue: job?.name ?? "")
        _prompt = State(initialValue: job?.prompt ?? "")
        _schedule = State(initialValue: job.map { ScheduleDraft(text: $0.scheduleText, cron: $0.cron) } ?? ScheduleDraft())
        _enabled = State(initialValue: job?.enabled ?? true)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                if job?.isBuiltin != true {
                    TextField("What should Lotti do?", text: $prompt, axis: .vertical).lineLimit(3...10)
                }
                Toggle("Enabled", isOn: $enabled)
                if let job, let label = job.settingLabel, job.settingKey != nil {
                    LabeledContent("\(label) (\(job.settingUnit ?? ""))") {
                        TextField("10", text: $settingValue).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                if let job {
                    VStack(alignment: .leading, spacing: 4) {
                        if let summary = job.summary { Text(summary).textCase(nil) }
                        Text(job.aiNote).textCase(nil).foregroundStyle(job.ai == "none" ? .green : .orange)
                    }
                }
            } footer: {
                if job?.isBuiltin == true {
                    Text("You can change the schedule, switch it off\(job?.settingKey != nil ? " and set its lead time" : ""). The job itself is built in.")
                }
                if job?.isBuiltin != true {
                    Text("Lotti runs this prompt with its tools. If there is nothing to say it answers NOTHING and you hear nothing; otherwise the result lands in your inbox.")
                }
            }
            scheduleSection
            if let job {
                Section {
                    Button { run(job) } label: { if running { ProgressView() } else { Text("Run now") } }
                        .disabled(running)
                    if let runNote { Text(runNote).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("History") {
                    if history.isEmpty { Text("Not run yet.").foregroundStyle(.secondary) }
                    ForEach(history) { run in
                        NavigationLink { RunOutputView(run: run) } label: {
                            LabeledContent(shortDate(run.startedAt)) { Text(run.status).foregroundStyle(color(run.status)) }
                        }
                    }
                }
                if !job.isBuiltin {
                    Section { Button("Delete job", role: .destructive) { confirmDelete = true } }
                }
            }
        }
        .navigationTitle(job == nil ? "New job" : job?.name ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if job == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(job == nil ? "Create" : "Save") { save() }
                    .disabled(name.isEmpty || !schedule.isValid || (job?.isBuiltin != true && prompt.isEmpty))
            }
        }
        .errorAlert($error)
        .confirmationDialog("Delete this job?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let job else { return }
                Task {
                    await attempt($error) {
                        _ = try await model.call("jobs.delete", ["id": .string(job.id)])
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadHistory()
            if let key = job?.settingKey, let value = try? await model.call("settings.get", ["key": .string(key)]) {
                settingValue = value["value"]?.number.map { String(Int($0)) } ?? ""
            }
        }
    }

    @ViewBuilder private var scheduleSection: some View {
        Section {
            Picker("Repeats", selection: $schedule.kind) {
                ForEach(ScheduleDraft.Kind.allCases) { Text($0.title).tag($0) }
            }
            switch schedule.kind {
            case .everyMinutes:
                Stepper("Every \(schedule.minutes) minutes", value: $schedule.minutes, in: 1...720, step: 5)
            case .hourly:
                EmptyView()
            case .custom:
                TextField("0 8 * * *", text: $schedule.custom)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
            case .weekly:
                Picker("Day", selection: $schedule.weekday) {
                    ForEach(0..<7, id: \.self) { Text(ScheduleDraft.weekdayNames[$0].capitalized).tag($0) }
                }
                timePicker
            case .daily, .weekdays, .monthly:
                timePicker
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text(schedule.isValid ? "Sent as: \(schedule.text)" : "Enter a cron expression, e.g. 0 8 * * *.")
        }
    }

    private var timePicker: some View {
        DatePicker("Time", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                schedule.hour = parts.hour ?? 8
                schedule.minute = parts.minute ?? 0
            }), displayedComponents: .hourAndMinute)
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "ok": .green
        case "error": .red
        default: .secondary
        }
    }

    private func save() {
        var input: [String: JSONValue] = ["name": .string(name), "schedule": .string(schedule.text), "enabled": .bool(enabled)]
        if job?.isBuiltin != true { input["prompt"] = .string(prompt) }
        Task {
            await attempt($error) {
                if let key = job?.settingKey, let minutes = Int(settingValue), minutes > 0 {
                    _ = try await model.call("settings.set", ["key": .string(key), "value": .number(Double(minutes))])
                }
                if let job {
                    input["id"] = .string(job.id)
                    _ = try await model.call("jobs.update", .object(input))
                } else {
                    _ = try await model.call("jobs.create", .object(input))
                }
                await done()
                dismiss()
            }
        }
    }

    private func run(_ job: JobInfo) {
        running = true
        runNote = nil
        Task {
            defer { running = false }
            await attempt($error) {
                let result = try await model.call("jobs.run_now", ["id": .string(job.id)])
                runNote = [result.text("status"), result.text("output")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                await loadHistory()
            }
        }
    }

    private func loadHistory() async {
        guard let job else { return }
        let result = try? await model.call("jobs.history", ["id": .string(job.id), "limit": 20])
        history = result?.items.compactMap(JobRunInfo.init) ?? []
    }
}

struct RunOutputView: View {
    let run: JobRunInfo

    var body: some View {
        List {
            Section {
                LabeledContent("Started", value: shortDate(run.startedAt))
                LabeledContent("Result", value: run.status)
            }
            Section("Output") {
                Text(run.output.isEmpty ? "(nothing)" : run.output).textSelection(.enabled)
            }
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
    }
}
