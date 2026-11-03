import LottiKit
import SwiftUI

/// External MCP servers Lotti can use as tools. Every tool needs your tap by default; switch that
/// off per tool for the ones you trust.
struct McpView: View {
    @State private var adding = false

    var body: some View {
        Loaded(load: { model in try await model.call("mcp.list").items.compactMap(McpServer.init) }) { servers, reload in
            List {
                Section {
                    if servers.isEmpty { Text("No MCP servers.").foregroundStyle(.secondary) }
                    ForEach(servers) { server in
                        NavigationLink { McpDetailView(server: server) } label: {
                            LabeledContent(server.name) {
                                Text(server.enabled ? (server.status == "ok" ? "OK" : server.status?.capitalized ?? "On") : "Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("Add MCP server", systemImage: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack { McpAddView { await reload() } }
            }
        }
        .navigationTitle("MCP servers")
    }
}

struct McpAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let done: @MainActor () async -> Void
    @State private var name = ""
    @State private var transport = "http"
    @State private var url = ""
    @State private var command = ""
    @State private var args = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Type", selection: $transport) {
                    Text("HTTP").tag("http")
                    Text("Command (stdio)").tag("stdio")
                }
                if transport == "http" {
                    TextField("URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } else {
                    TextField("Command", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Arguments (space separated)", text: $args).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("Its tools need your confirmation until you switch that off per tool.")
            }
        }
        .navigationTitle("Add MCP server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(name.isEmpty || (transport == "http" ? url.isEmpty : command.isEmpty)) }
        }
        .errorAlert($error)
    }

    private func add() {
        var input: [String: JSONValue] = ["name": .string(name), "transport": .string(transport)]
        if transport == "http" {
            input["url"] = .string(url)
        } else {
            input["command"] = .string(command)
            input["args"] = .array(args.split(separator: " ").map { JSONValue.string(String($0)) })
        }
        Task {
            await attempt($error) {
                _ = try await model.call("mcp.add", .object(input))
                await done()
                dismiss()
            }
        }
    }
}

struct McpDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: McpServer
    @State private var name: String
    @State private var url: String
    @State private var command: String
    @State private var args: String
    @State private var enabled: Bool
    @State private var confirmation: [String: Bool]
    @State private var tools: [String]
    @State private var testing = false
    @State private var testNote: String?
    @State private var secretKey = "bearer"
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var confirmDelete = false
    @State private var confirmClearSecret = false
    @State private var hasCredential: Bool
    @State private var error: String?

    init(server: McpServer) {
        self.server = server
        _hasCredential = State(initialValue: server.hasCredential)
        _name = State(initialValue: server.name)
        _url = State(initialValue: server.url)
        _command = State(initialValue: server.command)
        _args = State(initialValue: server.args.joined(separator: " "))
        _enabled = State(initialValue: server.enabled)
        _confirmation = State(initialValue: server.confirmation)
        _tools = State(initialValue: server.confirmation.keys.sorted())
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                if server.transport == "http" {
                    TextField("URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    TextField("Command", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Arguments", text: $args).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Enabled", isOn: $enabled)
                Button("Save") { save() }
            }
            Section {
                Button { test() } label: { if testing { ProgressView() } else { Text("Test connection") } }
                    .disabled(testing)
                if let testNote { Text(testNote).font(.footnote).foregroundStyle(.secondary) }
                if let problem = server.lastError, testNote == nil { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                StatusRow(title: "Secret", value: hasCredential ? "Set" : "Not set", good: hasCredential ? true : nil)
                Picker("Secret", selection: $secretKey) {
                    if server.transport == "http" { Text("Bearer token").tag("bearer") }
                    Text("Environment variable").tag("env")
                }
                if secretKey == "env" {
                    TextField("Variable name (API_KEY)", text: $secretName).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecretField(title: "Value", text: $secretValue)
                Button("Save secret") { saveSecret() }
                    .disabled(secretValue.isEmpty || (secretKey == "env" && secretName.isEmpty))
                if hasCredential {
                    Button("Remove secrets", role: .destructive) { confirmClearSecret = true }
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Write-only: stored encrypted on your Lotti Brain and never shown again.")
            }
            Section {
                if tools.isEmpty { Text("Test the connection to list the tools.").foregroundStyle(.secondary) }
                ForEach(tools, id: \.self) { tool in
                    Toggle(tool, isOn: Binding(
                        get: { confirmation[tool] ?? true },
                        set: { setConfirmation(tool, $0) }))
                }
            } header: {
                Text("Ask before using")
            } footer: {
                Text("On: Lotti proposes the call and you tap to approve. Off: it runs without asking.")
            }
            Section {
                Button("Remove server", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .task { await loadTools() }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await attempt($error) { _ = try await model.call("mcp.delete", ["id": .string(server.id)]); dismiss() } }
            }
        }
        .confirmationDialog("Remove the stored secrets of \(server.name)?", isPresented: $confirmClearSecret, titleVisibility: .visible) {
            Button("Remove secrets", role: .destructive) { clearSecret() }
        } message: {
            Text("The bearer token and environment values are deleted. A server that needs them stops working.")
        }
    }

    private func save() {
        var input: [String: JSONValue] = ["id": .string(server.id), "name": .string(name), "enabled": .bool(enabled)]
        if server.transport == "http" {
            input["url"] = .string(url)
        } else {
            input["command"] = .string(command)
            input["args"] = .array(args.split(separator: " ").map { JSONValue.string(String($0)) })
        }
        Task { await attempt($error) { _ = try await model.call("mcp.update", .object(input)) } }
    }

    private func test() {
        testing = true
        testNote = nil
        Task {
            defer { testing = false }
            await attempt($error) {
                let result = try await model.call("mcp.test", ["id": .string(server.id)])
                let found = (result["tools"]?.array ?? []).compactMap { $0.string ?? $0.text("name") }
                if !found.isEmpty { tools = Array(Set(found).union(tools)).sorted() }
                testNote = result.flag("ok") ? "Connected: \(found.count) tools." : (result.text("error") ?? "The test failed.")
                await loadTools()
            }
        }
    }

    /// The server's tools with whether each needs your tap (`mcp.tools` connects to the server).
    private func loadTools() async {
        guard let list = try? await model.call("mcp.tools", ["id": .string(server.id)]).items else { return }
        for tool in list {
            guard let name = tool.text("name") else { continue }
            if !tools.contains(name) { tools.append(name) }
            if let needs = tool["needsConfirmation"]?.boolValue { confirmation[name] = needs }
        }
        tools.sort()
    }

    private func saveSecret() {
        let key = secretKey == "env" ? "env.\(secretName.trimmingCharacters(in: .whitespaces))" : "bearer"
        let value = secretValue
        Task {
            await attempt($error) {
                _ = try await model.call("mcp.set_credential", ["id": .string(server.id), "key": .string(key), "value": .string(value)])
                secretValue = ""
                secretName = ""
                hasCredential = true
                testNote = "Secret saved."
            }
        }
    }

    private func clearSecret() {
        Task {
            await attempt($error) {
                _ = try await model.call("mcp.clear_credential", ["id": .string(server.id)])
                hasCredential = false
                testNote = "Secrets removed."
            }
        }
    }

    private func setConfirmation(_ tool: String, _ needs: Bool) {
        confirmation[tool] = needs
        Task {
            await attempt($error) {
                _ = try await model.call("mcp.set_tool_confirmation", ["id": .string(server.id), "tool": .string(tool), "needsConfirmation": .bool(needs)])
            }
        }
    }
}
