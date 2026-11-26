import PilotCore
import SwiftUI

/// One quiet line per workspace script run in a chat: setup while it runs or when it failed, checks when they failed.
/// A failed run discloses the tail of its output. Passing runs say nothing, so a healthy chat shows no extra rows.
struct WorkspaceScriptsNotice: View {
    let setup: WorkspaceScriptRun?
    let checks: WorkspaceScriptRun?
    /// The workspace whose environment this squad agent shares.
    var missionEnv: String? = nil
    var isolate: (() async throws -> Void)? = nil
    @State private var isolating = false
    @State private var isolateError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let missionEnv, setup?.state != .running {
                HStack(spacing: 6) {
                    Text("Shares the mission environment of \(URL(filePath: missionEnv).lastPathComponent)")
                        .foregroundStyle(Theme.mutedForeground)
                    if let isolate {
                        Button(isolating ? "Isolating…" : "Isolate") {
                            isolating = true
                            isolateError = nil
                            Task {
                                defer { isolating = false }
                                do { try await isolate() } catch { isolateError = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.link)
                        .disabled(isolating)
                        .help("Run the full setup in this agent's own workspace and stop sharing the mission environment.")
                    }
                }
                .font(.pilot(.label))
                if let isolateError { Text(isolateError).font(.pilot(.caption)).foregroundStyle(Theme.blocked) }
            }
            if let setup, setup.state != .ok {
                RunLine(kind: "Setup", run: setup)
            }
            if let checks, checks.state == .failed {
                RunLine(kind: "Checks", run: checks)
            }
        }
    }

    private struct RunLine: View {
        let kind: String
        let run: WorkspaceScriptRun
        @State private var expanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if run.state == .running {
                        EllipsisSpinner()
                        Text("\(kind) running…")
                            .foregroundStyle(Theme.mutedForeground)
                    } else if let failed = run.failedStep {
                        PilotSymbol(PilotIcon.warning)
                            .foregroundStyle(Theme.blocked)
                        Text("\(kind) failed: \(failed.summary)")
                            .foregroundStyle(Theme.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !failed.output.isEmpty {
                            Button(expanded ? "Hide output" : "Show output") { expanded.toggle() }
                                .buttonStyle(.link)
                                .font(.pilot(.caption))
                        }
                    }
                }
                .font(.pilot(.label))
                if expanded, let failed = run.failedStep {
                    ScrollView {
                        Text(failed.output)
                            .font(.pilot(.caption, design: .monospaced))
                            .foregroundStyle(Theme.mutedForeground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.code))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// After an Ask investigation: start a Build chat that fixes what it concluded.
struct FixItButton: View {
    let start: (WorkKind) async throws -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu(busy ? "Starting fix…" : "Fix it") {
                ForEach(WorkKind.allCases, id: \.self) { kind in
                    Button(kind.title) { run(kind) }
                }
            }
            .fixedSize()
            .controlSize(.small)
            .disabled(busy)
            .help("Start a Build chat from this chat's conclusion: failing test first, then the fix and a PR.")
            if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
        }
    }

    private func run(_ kind: WorkKind) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await start(kind) } catch { self.error = error.localizedDescription }
        }
    }
}

/// A chat started from a Slack message: draft the thread reply from the agent's latest answer, edit, then send.
/// Nothing is posted until the user presses Send.
struct SlackReplyButton: View {
    @EndpointClient private var endpoint
    let sessionId: String
    let source: SessionTrackedSource
    @State private var drafting = false

    var body: some View {
        Button("Reply in Slack…") { drafting = true }
            .controlSize(.small)
            .help("Draft a reply in \(source.label) from the agent's latest answer. You review it before it is sent.")
            .sheet(isPresented: $drafting) {
                SlackReplySheet(sessionId: sessionId, source: source)
            }
    }
}

private struct SlackReplySheet: View {
    @EndpointClient private var endpoint
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let source: SessionTrackedSource
    @State private var text = ""
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply in \(source.label)").font(.pilot(.title, weight: .semibold))
            Text(source.title).font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground).lineLimit(2)
            TextEditor(text: $text)
                .font(.pilot(.body))
                .frame(minHeight: 180)
                .overlay(alignment: .topLeading) {
                    if loading { ProgressView().controlSize(.small).padding(8) }
                }
            Text("Posted in the message's thread as you. Edit it first: it was drafted from the agent's answer.")
                .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
            if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            defer { loading = false }
            if let reply = try? await endpoint.lastReply(sessionId) { text = reply }
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await endpoint.replyInSlack(itemId: source.itemId, text: text)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// In a worktree chat: ask the agent to load one production client into the workspace's local database with the
/// personal dump-client skill.
struct LoadClientButton: View {
    let send: (String) async throws -> Void
    @State private var asking = false
    @State private var clientId = ""
    @State private var busy = false
    @State private var error: String?

    static func valid(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 64
            && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var body: some View {
        Button("Load a client…") { asking = true; error = nil }
            .controlSize(.small)
            .help("Dump one client's production data into this workspace's local database (dump-client skill).")
            .popover(isPresented: $asking, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Client ID", text: $clientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.pilot(.label, design: .monospaced))
                        .frame(width: 280)
                    if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
                    HStack {
                        Spacer()
                        Button(busy ? "Sending…" : "Load") { load() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || !Self.valid(clientId))
                    }
                }
                .padding(12)
            }
    }

    private func load() {
        let id = clientId.trimmingCharacters(in: .whitespaces)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await send("Use the dump-client skill to load client \(id) into this workspace's local database, then tell me what was loaded.")
                asking = false
                clientId = ""
            } catch { self.error = error.localizedDescription }
        }
    }
}
