import Foundation
import PilotCore
import SwiftUI

/// Free chats, like a terminal agent: questions, small requests, bug hunts. They run on the project's current
/// checkout (Ask reads it, Build edits it in place) or in the home folder, never in a worktree or clone, and stay
/// out of the Features and Quick fixes boards.
struct ChatsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    /// Project id, or "" for the home folder.
    @AppStorage("chats.projectId") private var projectId = ""
    @AppStorage("chats.build") private var build = false
    @PageState("chats.message") private var message = ""
    @PageState("chats.agent") private var agent: ComposerAgent? = nil
    @State private var sending = false
    @State private var error: String?
    @PageState("chats.search") private var search = ""

    /// A chat is free when it has no isolated workspace and no mission: Ask, the current checkout, or a folder.
    static func isFree(_ session: SessionSummary) -> Bool {
        guard !session.isArchived, session.missionId == nil, !session.isMissionCoordinator,
              !session.isDiagnosticsSpecialist else { return false }
        return session.isAsk || session.projectId == nil || session.workspace == .direct
    }

    private var chats: [SessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return client.sessions
            .filter(Self.isFree)
            .filter { query.isEmpty || $0.title.lowercased().contains(query) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var project: Project? { client.projects.first { $0.id == projectId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chats").font(.pilot(.title, weight: .semibold))
                Text("\(chats.count)").font(.pilot(.title)).foregroundStyle(Theme.mutedForeground)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            composer
            if chats.isEmpty {
                Text(search.isEmpty ? "No chat yet. Ask anything above: it runs on the current checkout, no worktree."
                                    : "No chat matches.")
                    .foregroundStyle(Theme.mutedForeground)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chats) { session in
                        FreeChatRow(session: session, project: client.project(session.projectId)?.name,
                                    signal: session.signal(unread: model.isUnread(session))) {
                            model.open(session: session.id)
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(24)
        .background(Theme.background)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $message)
                .font(.pilot(.body))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Ask a question, report a bug, make a small change…")
                            .foregroundStyle(Theme.faintForeground).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Picker("Where", selection: $projectId) {
                    Text("Home folder").tag("")
                    ForEach(client.projects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                Picker("Mode", selection: $build) {
                    Text("Ask").tag(false)
                    Text("Build").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Ask reads only. Build edits the current checkout in place, like a terminal agent.")
                Menu {
                    Button("No agent") { agent = nil }
                    ForEach(ComposerAgent.all) { item in
                        Button("\(item.title) — \(item.detail)") {
                            agent = item
                            build = !item.readOnly
                        }
                    }
                } label: {
                    Text(agent?.title ?? "Agent")
                }
                .fixedSize()
                Spacer()
                if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive).lineLimit(2) }
                Button(sending ? "Starting…" : "Send") { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func send() async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        error = nil
        defer { sending = false }
        let project = project
        let request = SpawnRequest(
            projectId: project?.id,
            cwd: project == nil ? FileManager.default.homeDirectoryForCurrentUser.path : nil,
            message: (agent.map { "Use the \($0.skill) skill.\n\n" } ?? "") + text,
            mode: build ? .build : .ask,
            workspace: build && project != nil ? .direct : nil
        )
        do {
            let session = try await client.spawn(request)
            message = ""
            agent = nil
            model.open(session: session.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FreeChatRow: View {
    let session: SessionSummary
    let project: String?
    let signal: SessionSignal?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if let signal { StatusMarkShape(signal: signal, background: session.isWaitingOnJobs) }
                }
                .frame(width: 12)
                Text(session.title).font(.pilot(.body)).foregroundStyle(Theme.foreground).lineLimit(1)
                Spacer(minLength: 8)
                Text(session.isAsk ? "Ask" : "Build")
                    .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                Text(project ?? URL(filePath: session.cwd).lastPathComponent)
                    .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                Text(RelativeDate.ago(session.updatedAt))
                    .font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.muted : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
