import Foundation
import PilotCore
import SwiftUI

/// The Chats page as a terminal workspace, Ghostty-style: chats open as horizontal tabs, and a tab splits into up to
/// four panes side by side (or stacked) so several chats stay visible at once. An empty pane is a new-chat composer.
/// Kept across launches; panes whose chat is gone close on the next prune.
@MainActor
final class ChatsWorkspace: ObservableObject {
    struct Pane: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var sessionId: String?
    }

    struct Tab: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var panes: [Pane]
        /// Stacked top to bottom instead of side by side. Set by the first split.
        var vertical = false
        var focused: String

        init(sessionId: String? = nil) {
            let pane = Pane(sessionId: sessionId)
            panes = [pane]
            focused = pane.id
        }

        var focusedPane: Pane? { panes.first { $0.id == focused } ?? panes.first }
    }

    private struct Saved: Codable {
        var tabs: [Tab]
        var selected: String?
    }

    static let tabLimit = 12
    static let paneLimit = 4
    private static let key = "chats.workspace"
    @Published private(set) var tabs: [Tab]
    @Published private(set) var selectedTabId: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        tabs = Array((saved?.tabs ?? []).filter { !$0.panes.isEmpty }.prefix(Self.tabLimit))
        selectedTabId = saved?.selected
        if selectedTab == nil { selectedTabId = tabs.first?.id }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabId } }
    var focusedSessionId: String? { selectedTab?.focusedPane?.sessionId }
    /// Chats on screen in the selected tab.
    var visibleSessionIds: [String] { selectedTab?.panes.compactMap(\.sessionId) ?? [] }

    /// Shows a chat: the tab or pane already holding it, else the focused empty pane, else a new tab.
    func open(_ sessionId: String) {
        if let tab = tabs.first(where: { $0.panes.contains { $0.sessionId == sessionId } }),
           let pane = tab.panes.first(where: { $0.sessionId == sessionId }) {
            update(tab.id) { $0.focused = pane.id }
            selectedTabId = tab.id
            save()
            return
        }
        if let tab = selectedTab, let pane = tab.focusedPane, pane.sessionId == nil {
            fill(pane.id, with: sessionId)
            return
        }
        append(Tab(sessionId: sessionId))
    }

    func fill(_ paneId: String, with sessionId: String) {
        guard let tab = tabs.first(where: { $0.panes.contains { $0.id == paneId } }) else { return open(sessionId) }
        update(tab.id) { tab in
            guard let index = tab.panes.firstIndex(where: { $0.id == paneId }) else { return }
            tab.panes[index].sessionId = sessionId
            tab.focused = paneId
        }
        selectedTabId = tab.id
        save()
    }

    func newTab() { append(Tab()) }

    /// Splits the focused pane, opening an empty pane (a composer) beside or below it.
    func split(vertical: Bool) {
        guard let tab = selectedTab, tab.panes.count < Self.paneLimit else { return }
        update(tab.id) { tab in
            if tab.panes.count == 1 { tab.vertical = vertical }
            let pane = Pane()
            let index = tab.panes.firstIndex { $0.id == tab.focused }.map { $0 + 1 } ?? tab.panes.endIndex
            tab.panes.insert(pane, at: index)
            tab.focused = pane.id
        }
        save()
    }

    var canSplit: Bool { (selectedTab?.panes.count ?? Self.paneLimit) < Self.paneLimit }

    func focus(_ paneId: String) {
        guard let tab = selectedTab, tab.focused != paneId else { return }
        update(tab.id) { $0.focused = paneId }
        save()
    }

    /// Closes a pane, and its tab with the last one. Focus moves to the neighbour.
    func closePane(_ paneId: String) {
        guard let tab = tabs.first(where: { $0.panes.contains { $0.id == paneId } }) else { return }
        guard tab.panes.count > 1 else { return closeTab(tab.id) }
        update(tab.id) { tab in
            guard let index = tab.panes.firstIndex(where: { $0.id == paneId }) else { return }
            tab.panes.remove(at: index)
            if tab.focused == paneId { tab.focused = tab.panes[min(index, tab.panes.count - 1)].id }
        }
        save()
    }

    /// Closes the focused pane: Ghostty's close, which takes the tab with its last pane.
    func closeFocused() {
        if let pane = selectedTab?.focusedPane { closePane(pane.id) }
    }

    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabId == id { selectedTabId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        save()
    }

    func select(_ id: String) {
        guard selectedTabId != id, tabs.contains(where: { $0.id == id }) else { return }
        selectedTabId = id
        save()
    }

    func select(at index: Int) {
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    func selectNeighbour(offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == selectedTabId } ?? 0
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// Moves focus to the next or previous pane of the selected tab.
    func focusNeighbourPane(offset: Int) {
        guard let tab = selectedTab, tab.panes.count > 1,
              let index = tab.panes.firstIndex(where: { $0.id == tab.focused }) else { return }
        focus(tab.panes[(index + offset + tab.panes.count) % tab.panes.count].id)
    }

    func move(_ id: String, before target: String) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: tabs.firstIndex { $0.id == target } ?? tabs.endIndex)
        save()
    }

    /// Drops panes whose chat no longer exists (archived or deleted), and tabs left empty.
    func prune(keeping live: Set<String>) {
        var next = tabs
        for index in next.indices {
            next[index].panes.removeAll { $0.sessionId.map { !live.contains($0) } ?? false }
            if !next[index].panes.contains(where: { $0.id == next[index].focused }), let first = next[index].panes.first {
                next[index].focused = first.id
            }
        }
        next.removeAll { $0.panes.isEmpty }
        guard next != tabs else { return }
        tabs = next
        if selectedTab == nil { selectedTabId = tabs.first?.id }
        save()
    }

    private func append(_ tab: Tab) {
        var next = tabs
        let index = next.firstIndex { $0.id == selectedTabId }.map { $0 + 1 } ?? next.endIndex
        next.insert(tab, at: index)
        while next.count > Self.tabLimit, let drop = next.firstIndex(where: { $0.id != tab.id }) { next.remove(at: drop) }
        tabs = next
        selectedTabId = tab.id
        save()
    }

    private func update(_ id: String, _ change: (inout Tab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        change(&tab)
        if tab != tabs[index] { tabs[index] = tab }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(tabs: tabs, selected: selectedTabId)) { defaults.set(data, forKey: Self.key) }
    }
}

extension AppModel {
    var isShowingChatsWorkspace: Bool { showingUsage && workflowPage == .chats }

    /// The chat inspector keys act on: the selected chat, or the focused pane on the Chats page.
    var focusedChat: SessionSummary? {
        selectedSession ?? (isShowingChatsWorkspace ? chatsWorkspace.focusedSessionId.flatMap(client.session) : nil)
    }

    /// A chat on screen: the selected chat, or a pane of the Chats page's selected tab.
    func isChatOnScreen(_ id: String) -> Bool {
        selectedSessionId == id || (isShowingChatsWorkspace && chatsWorkspace.visibleSessionIds.contains(id))
    }

    /// Workspace commands bring the Chats page forward first.
    func chatsWorkspaceAction(_ action: (ChatsWorkspace) -> Void) {
        if !isShowingChatsWorkspace { showWorkflowBoard(.chats) }
        action(chatsWorkspace)
    }
}

/// Tab, split and pane keys, in the Window menu: Ghostty's where they are free (⌘T, ⌘D, ⌘1…⌘9, ⌘⇧[ and ⌘⇧]);
/// panes move with ⌥⌘← and ⌥⌘→ because ⌘[ and ⌘] are Back and Forward.
struct ChatsWorkspaceCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("New Chat Tab") { model.chatsWorkspaceAction { $0.newTab() } }
                .keyboardShortcut("t", modifiers: .command)
            Button("Split Right") { model.chatsWorkspaceAction { $0.split(vertical: false) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.isShowingChatsWorkspace)
            Button("Split Down") { model.chatsWorkspaceAction { $0.split(vertical: true) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!model.isShowingChatsWorkspace)
            Button("Close Pane") { model.chatsWorkspace.closeFocused() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(!model.isShowingChatsWorkspace)
            Button("Focus Next Pane") { model.chatsWorkspace.focusNeighbourPane(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.isShowingChatsWorkspace)
            Button("Focus Previous Pane") { model.chatsWorkspace.focusNeighbourPane(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.isShowingChatsWorkspace)
            Divider()
            Button("Show Next Chat Tab") { model.chatsWorkspaceAction { $0.selectNeighbour(offset: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Chat Tab") { model.chatsWorkspaceAction { $0.selectNeighbour(offset: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button("Show Chat Tab \(number)") { model.chatsWorkspaceAction { $0.select(at: number - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}
