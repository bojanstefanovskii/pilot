import Foundation
import PilotCore
import SwiftUI

/// Free chats, like a terminal agent: questions, small requests, bug hunts. They run on the project's current
/// checkout (Ask reads it, Build edits it in place) or in the home folder, never in a worktree or clone, and stay
/// out of the Features and Quick fixes boards.
struct ChatsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @ObservedObject private var workspace: ChatsWorkspace

    init(model: AppModel, client: PilotClient) {
        self.model = model
        self.client = client
        workspace = model.chatsWorkspace
    }

    /// A chat is free when it has no isolated workspace and no mission: Ask, the current checkout, or a folder.
    static func isFree(_ session: SessionSummary) -> Bool {
        guard !session.isArchived, session.missionId == nil, !session.isMissionCoordinator,
              !session.isDiagnosticsSpecialist else { return false }
        return session.isAsk || session.projectId == nil || session.workspace == .direct
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatsTabBar(model: model, workspace: workspace, client: client)
            HairlineDivider()
            if let tab = workspace.selectedTab {
                ChatsTabContent(tab: tab, model: model, workspace: workspace, client: client)
                    .id(tab.id)
            } else {
                NewChatPane(model: model, client: client, paneId: "none") { workspace.open($0) }
                    .navigationTitle("Chats")
            }
        }
        .background(Theme.background)
        // The whole page reads like a terminal: one monospaced face for tabs, transcript and prompt.
        .fontDesign(.monospaced)
        .onAppear { if workspace.tabs.isEmpty { workspace.newTab() } }
        .onChange(of: client.sessions.count, initial: true) {
            // Before the first list arrives every chat looks gone: keep the tabs until there is one.
            guard !client.sessions.isEmpty else { return }
            workspace.prune(keeping: Set(client.sessions.lazy.filter { !$0.isArchived }.map(\.id)))
        }
    }
}

/// One tab: its panes side by side (or stacked), with the focused chat's inspector and toolbar around them.
private struct ChatsTabContent: View {
    let tab: ChatsWorkspace.Tab
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: ChatsWorkspace
    @ObservedObject var client: PilotClient

    var body: some View {
        // The inspector follows the focused pane, or the tab's first chat while a composer pane has focus, so
        // moving focus never rebuilds the panes.
        let anchor = tab.focusedPane?.sessionId.flatMap(client.session)
            ?? tab.panes.lazy.compactMap { $0.sessionId.flatMap(client.session) }.first
        if let anchor {
            SessionDetail(session: anchor, content: AnyView(panes))
        } else {
            panes.navigationTitle("New chat")
        }
    }

    @ViewBuilder private var panes: some View {
        if tab.panes.count == 1, let only = tab.panes.first {
            paneView(only)
        } else if tab.vertical {
            VSplitView { ForEach(tab.panes) { paneView($0).frame(minHeight: 160) } }
        } else {
            HSplitView { ForEach(tab.panes) { paneView($0).frame(minWidth: 280) } }
        }
    }

    private func paneView(_ pane: ChatsWorkspace.Pane) -> some View {
        ChatsPaneView(pane: pane, session: pane.sessionId.flatMap(client.session), split: tab.panes.count > 1,
                      focused: pane.id == tab.focused, model: model, workspace: workspace, client: client)
            .id(pane.id)
    }
}

private struct ChatsPaneView: View {
    let pane: ChatsWorkspace.Pane
    let session: SessionSummary?
    let split: Bool
    let focused: Bool
    let model: AppModel
    let workspace: ChatsWorkspace
    let client: PilotClient

    var body: some View {
        VStack(spacing: 0) {
            if split {
                ChatsPaneHeader(session: session, focused: focused, canSplit: workspace.canSplit,
                                signal: session.flatMap { $0.signal(unread: model.isUnread($0)) },
                                split: { vertical in
                                    workspace.focus(pane.id)
                                    workspace.split(vertical: vertical)
                                },
                                close: { workspace.closePane(pane.id) })
                HairlineDivider()
            }
            if let session {
                ChatView(session: session)
                    .id(session.id)
            } else {
                NewChatPane(model: model, client: client, paneId: pane.id) { workspace.fill(pane.id, with: $0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // Any click inside a pane focuses it, without taking the click from the transcript or composer.
        .simultaneousGesture(TapGesture().onEnded { workspace.focus(pane.id) })
    }
}

/// A split pane's title row. The focused pane's carries an accent edge, like Ghostty's focused split.
private struct ChatsPaneHeader: View {
    let session: SessionSummary?
    let focused: Bool
    let canSplit: Bool
    let signal: SessionSignal?
    let split: (Bool) -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let signal, let session { StatusMarkShape(signal: signal, background: session.isWaitingOnJobs) }
            Text(session?.title ?? "New chat")
                .font(.pilot(.label, weight: focused ? .medium : .regular))
                .foregroundStyle(focused ? Theme.foreground : Theme.mutedForeground)
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                Button { split(false) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split right (⌘D)")
                    .accessibilityLabel("Split right")
                    .disabled(!canSplit)
                Button { split(true) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split down (⌥⌘D)")
                    .accessibilityLabel("Split down")
                    .disabled(!canSplit)
                Button(action: close) { PilotSymbol(PilotIcon.dismiss, context: .inline) }
                    .help("Close pane (⌥⌘W)")
                    .accessibilityLabel("Close pane")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.faintForeground)
            .revealed(hovered || focused)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(focused ? Theme.muted : .clear)
        .overlay(alignment: .top) {
            if focused { Theme.accent.frame(height: 2) }
        }
        .onHover { hovered = $0 }
    }
}

/// The tab bar: one tab per tab, titled by its focused chat, plus a new-tab button. Tabs reorder by dragging.
private struct ChatsTabBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: ChatsWorkspace
    @ObservedObject var client: PilotClient

    var body: some View {
        // Ghostty's macOS tab bar: tabs share the width equally, the selected one is raised, + opens a tab.
        HStack(spacing: 0) {
            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                let session = tab.focusedPane?.sessionId.flatMap(client.session)
                if index > 0 { Theme.border.frame(width: 1, height: 16) }
                ChatsTabItem(title: session?.title ?? "new chat", session: session, panes: tab.panes.count,
                             index: index, selected: tab.id == workspace.selectedTabId,
                             signal: session.flatMap { $0.signal(unread: model.isUnread($0)) },
                             select: { workspace.select(tab.id) },
                             close: { workspace.closeTab(tab.id) })
                    .draggable(tab.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first else { return false }
                        workspace.move(id, before: tab.id)
                        return true
                    }
            }
            Button { workspace.newTab() } label: { PilotSymbol(PilotIcon.add, context: .inline) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 32)
                .help("New chat tab (⌘T)")
                .accessibilityLabel("New chat tab")
        }
        .frame(height: 30)
        .background(Theme.muted)
    }
}

private struct ChatsTabItem: View {
    let title: String
    let session: SessionSummary?
    let panes: Int
    let index: Int
    let selected: Bool
    let signal: SessionSignal?
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Close on the left, like Ghostty; the title stays centred.
            Button(action: close) { PilotSymbol(PilotIcon.dismiss, context: .inline) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.faintForeground)
                .revealed(hovered)
                .help("Close tab")
                .accessibilityLabel("Close \(title)")
            Spacer(minLength: 0)
            if let signal, let session { StatusMarkShape(signal: signal, background: session.isWaitingOnJobs) }
            Text(title)
                .font(.pilot(.label, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
                .lineLimit(1)
            if panes > 1 {
                Text("\(panes)")
                    .font(.pilot(.caption))
                    .foregroundStyle(Theme.faintForeground)
                    .help("\(panes) panes")
            }
            Spacer(minLength: 0)
            if index < 9 { Text("⌘\(index + 1)").font(.pilot(.caption)).foregroundStyle(Theme.faintForeground) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? Theme.background : hovered ? Theme.muted : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help(index < 9 ? "\(title) (⌘\(index + 1))" : title)
        .contextMenu { Button("Close Tab", action: close) }
    }
}

/// An empty pane, like a fresh terminal: recent chats as history above, a prompt at the bottom. Return starts the
/// chat in this pane; clicking a recent chat (or ⌘1…) resumes it here. ⇧Tab switches Ask and Build.
private struct NewChatPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    let open: (String) -> Void
    /// Project id, or "" for the home folder.
    @AppStorage("chats.projectId") private var projectId = ""
    @AppStorage("chats.build") private var build = false
    @PageState private var message: String
    @PageState private var agent: ComposerAgent?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    init(model: AppModel, client: PilotClient, paneId: String, open: @escaping (String) -> Void) {
        self.model = model
        self.client = client
        self.open = open
        _message = PageState(wrappedValue: "", "chats.message.\(paneId)")
        _agent = PageState(wrappedValue: nil, "chats.agent.\(paneId)")
    }

    private var project: Project? { client.projects.first { $0.id == projectId } }
    private var place: String { project?.name ?? "~" }

    var body: some View {
        let recent = client.sessions.filter(ChatsPage.isFree).sorted { $0.updatedAt > $1.updatedAt }.prefix(30)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("pilot — ask a question, report a bug, make a small change")
                        .foregroundStyle(Theme.foreground)
                    Text("runs on \(project == nil ? "the home folder" : "\(place)'s current checkout"), no worktree · ⇧⇥ ask/build · ⌘D split")
                        .foregroundStyle(Theme.faintForeground)
                    if !recent.isEmpty {
                        Text("recent").foregroundStyle(Theme.mutedForeground).padding(.top, 14).padding(.bottom, 2)
                        ForEach(recent) { session in
                            TerminalHistoryRow(session: session, project: client.project(session.projectId)?.name,
                                               signal: session.signal(unread: model.isUnread(session))) {
                                open(session.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            prompt
        }
        .font(.pilot(.body))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = true }
        .onAppear { promptFocused = true }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(build ? "❯" : "?")
                    .foregroundStyle(build ? Theme.accent : Theme.mutedForeground)
                    .font(.pilot(.body, weight: .semibold))
                TextField("", text: $message, prompt: Text(build ? "make a change…" : "ask anything…")
                    .foregroundStyle(Theme.faintForeground), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($promptFocused)
                    .disabled(sending)
                    .onSubmit { Task { await send() } }
                    .onKeyPress(.tab, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        build.toggle()
                        return .handled
                    }
            }
            HStack(spacing: 12) {
                Menu {
                    Button("Home folder") { projectId = "" }
                    ForEach(client.projects) { item in Button(item.name) { projectId = item.id } }
                } label: { Text(place) }
                    .menuStyle(.borderlessButton).fixedSize()
                Button(build ? "build" : "ask") { build.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(build ? Theme.accent : Theme.mutedForeground)
                    .help("Ask reads only. Build edits the current checkout in place. (⇧⇥)")
                Menu {
                    Button("No agent") { agent = nil }
                    ForEach(ComposerAgent.all) { item in
                        Button("\(item.title) — \(item.detail)") {
                            agent = item
                            build = !item.readOnly
                        }
                    }
                } label: { Text(agent.map { "agent: \($0.title)" } ?? "agent: none") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if let error { Text(error).foregroundStyle(Theme.destructive).lineLimit(1) }
                Text(sending ? "starting…" : "↵ send")
            }
            .font(.pilot(.caption))
            .foregroundStyle(Theme.faintForeground)
            .padding(.leading, 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { HairlineDivider() }
    }

    private func send() async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
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
            open(session.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A recent chat, as one line of terminal history.
private struct TerminalHistoryRow: View {
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
                Text(session.title).foregroundStyle(hovering ? Theme.accent : Theme.foreground).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(session.isAsk ? "ask" : "build") · \(project ?? URL(filePath: session.cwd).lastPathComponent) · \(RelativeDate.ago(session.updatedAt))")
                    .foregroundStyle(Theme.faintForeground)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
