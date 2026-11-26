import PilotCore
import SwiftUI

/// Open chats as tabs, Ghostty-style: every chat you open gets a tab above the conversation, so several stay one
/// click (or ⌘1…⌘9, ⌘⇧[ and ⌘⇧]) away. Local chats only. Kept across launches; bounded to `limit` tabs.
@MainActor
final class ChatTabs: ObservableObject {
    static let limit = 12
    private static let key = "chatTabs.open"
    @Published private(set) var ids: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Array((defaults.stringArray(forKey: Self.key) ?? []).prefix(Self.limit))
    }

    /// A chat was opened: it gets a tab after the current one, or keeps its own. The oldest other tab goes past `limit`.
    func opened(_ id: String, after current: String?) {
        guard !ids.contains(id) else { return }
        var next = ids
        let index = current.flatMap { next.firstIndex(of: $0) }.map { $0 + 1 } ?? next.endIndex
        next.insert(id, at: index)
        while next.count > Self.limit, let drop = next.firstIndex(where: { $0 != id }) { next.remove(at: drop) }
        set(next)
    }

    /// Closes a tab and returns the tab to show instead when it was the selected one: its right neighbour, else its left.
    @discardableResult
    func close(_ id: String) -> String? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        var next = ids
        next.remove(at: index)
        set(next)
        return next.isEmpty ? nil : next[min(index, next.count - 1)]
    }

    func neighbour(of id: String?, offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return ids.first }
        return ids[(index + offset + ids.count) % ids.count]
    }

    private func set(_ next: [String]) {
        ids = next
        defaults.set(next, forKey: Self.key)
    }
}

extension AppModel {
    func selectChatTab(offset: Int) {
        if let id = chatTabs.neighbour(of: selectedSessionId, offset: offset) { open(session: id) }
    }

    func selectChatTab(at index: Int) {
        guard chatTabs.ids.indices.contains(index) else { return }
        open(session: chatTabs.ids[index])
    }

    func closeChatTab(_ id: String) {
        let replacement = chatTabs.close(id)
        guard selectedSessionId == id else { return }
        if let replacement { open(session: replacement) } else { selectedSessionId = nil }
    }
}

/// The tab strip above a chat. Quiet like Linear: the selected tab is a raised card, others are plain text, and a
/// tab's close button shows on hover. Each tab carries its chat's status mark, so working and waiting chats stand out.
struct ChatTabStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var client: PilotClient

    var body: some View {
        let byId = Dictionary(client.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = tabs.ids.compactMap { byId[$0] }
        // Shown once there is another tab than the chat on screen.
        if sessions.contains(where: { $0.id != model.selectedSessionId }) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                ChatTab(session: session, index: index, selected: session.id == model.selectedSessionId,
                                        signal: session.signal(unread: model.isUnread(session)),
                                        select: { model.open(session: session.id) },
                                        close: { model.closeChatTab(session.id) })
                                    .id(session.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedSessionId, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                HairlineDivider()
            }
            .background(Theme.background)
        }
    }
}

private struct ChatTab: View {
    let session: SessionSummary
    let index: Int
    let selected: Bool
    let signal: SessionSignal?
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let signal { StatusMarkShape(signal: signal, background: session.isWaitingOnJobs) }
            Text(session.trackedSource.map { $0.label.isEmpty ? session.title : "\($0.label) · \(session.title)" } ?? session.title)
                .font(.pilot(.label, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: close) { PilotSymbol(PilotIcon.dismiss, context: .inline) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.faintForeground)
                .revealed(hovered || selected)
                .help("Close tab (⌥⌘W)")
                .accessibilityLabel("Close \(session.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.card : hovered ? Theme.muted : .clear)
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.border : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .help(index < 9 ? "\(session.title) (⌘\(index + 1))" : session.title)
        .contextMenu {
            Button("Close Tab", action: close)
        }
    }
}

/// Tab keys, in the Window menu: like Ghostty and Safari.
struct ChatTabCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Show Next Chat Tab") { model.selectChatTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Chat Tab") { model.selectChatTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Close Chat Tab") { if let id = model.selectedSessionId { model.closeChatTab(id) } }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(model.selectedSessionId == nil)
            ForEach(1...9, id: \.self) { number in
                Button("Show Chat Tab \(number)") { model.selectChatTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}
