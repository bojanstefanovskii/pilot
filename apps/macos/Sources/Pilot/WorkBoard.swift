import PilotCore
import SwiftUI

/// The work in progress of one kind as a grid of cards: Missions, Quick fixes or Features. A card names its ticket
/// when the work started from one, its state, its PR and when it last moved. Click opens the chat or mission.
struct WorkBoardView: View {
    enum Kind: String { case missions, quickFixes, features }

    let kind: Kind
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @ObservedObject private var pageStates = PageStateStore.shared
    /// Done chats the user deleted from the board, newline-separated. Their history stays in the Archive.
    @AppStorage("workBoard.deletedChats") private var deletedChats = ""
    @State private var deleting: SessionSummary?
    @State private var deleteError: String?
    /// How long finished work stays on the board.
    static let doneWindow: Double = 30 * 24 * 3600 * 1000

    private var title: String {
        switch kind {
        case .missions: "Missions"
        case .quickFixes: "Quick fixes"
        case .features: "Features"
        }
    }

    /// Shown by default and remembered per board while the app runs.
    private var showDone: Binding<Bool> {
        let key = "workBoard.\(kind.rawValue).showDone"
        return Binding(get: { pageStates.value(key, default: true) }, set: { pageStates.set(key, $0) })
    }

    private var since: Double { Date().timeIntervalSince1970 * 1000 - Self.doneWindow }

    /// Build chats of this kind, mission members excluded: they belong to their mission's card.
    private var kindChats: [SessionSummary] {
        client.sessions.filter { session in
            guard session.projectId != nil, !session.isAsk, session.missionId == nil,
                  !session.isMissionCoordinator, !ChatsPage.isFree(session) else { return false }
            return kind == .quickFixes ? session.kind == .quick : session.kind != .quick
        }
    }

    private var chats: [SessionSummary] {
        kindChats.filter { !$0.isArchived && !$0.isDone }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Chats whose PRs merged on GitHub or whose Linear ticket closed. Both archive the chat automatically, so they
    /// come from the archive too.
    private var doneChats: [SessionSummary] {
        let deleted = Set(deletedChats.split(separator: "\n").map(String.init))
        let since = since
        let done: [(session: SessionSummary, at: Double)] = kindChats.compactMap { session in
            guard !deleted.contains(session.id), let at = session.doneAt, at >= since else { return nil }
            return (session, at)
        }
        return done.sorted { $0.at > $1.at }.map(\.session)
    }

    /// Archives the chat if needed, removes its worktree now and takes it off the board. The conversation stays
    /// readable in the Archive.
    private func delete(_ session: SessionSummary) async {
        do {
            if !session.isArchived { _ = try await client.archive(session.id) }
            // Clone workspaces cannot be reclaimed; they are pruned on their own. Leaving the board still applies.
            try? await client.reclaimWorkspace(session.id)
            let ids = (deletedChats.split(separator: "\n").map(String.init) + [session.id]).suffix(500)
            deletedChats = ids.joined(separator: "\n")
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var missions: [Mission] {
        client.missions.filter { $0.archivedAt == nil && !Self.isDone($0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var doneMissions: [Mission] {
        client.missions.filter { $0.archivedAt == nil && Self.isDone($0) && ($0.completedAt ?? $0.updatedAt) >= since }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    static func isDone(_ mission: Mission) -> Bool { mission.status == .done || mission.completedAt != nil }

    private var doneCount: Int { kind == .missions ? doneMissions.count : doneChats.count }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.pilot(.title, weight: .semibold))
                    Text("\(kind == .missions ? missions.count : chats.count)")
                        .font(.pilot(.title)).foregroundStyle(Theme.mutedForeground)
                    Spacer()
                    Toggle("Show done", isOn: showDone).toggleStyle(.checkbox)
                }
                if (kind == .missions ? missions.isEmpty : chats.isEmpty) {
                    Text(emptyText).foregroundStyle(Theme.mutedForeground)
                }
                grid(done: false)
                if showDone.wrappedValue, doneCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.done)
                        Text("Done").font(.pilot(.body, weight: .semibold))
                        Text("\(doneCount)").foregroundStyle(Theme.mutedForeground)
                        Text("· last 30 days").font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
                    }
                    .padding(.top, 8)
                    grid(done: true)
                }
            }
            .padding(24)
        }
        .background(Theme.background)
        .confirmationDialog("Delete \"\(deleting?.trackedSource?.title ?? deleting?.title ?? "")\"?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let session = deleting { Task { await delete(session) } }
                deleting = nil
            }
        } message: {
            Text("Its worktree is removed now and it leaves this board. The conversation stays in the Archive.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
    }

    private func grid(done: Bool) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            if kind == .missions {
                ForEach(done ? doneMissions : missions) { mission in
                    MissionCard(mission: mission, client: client, done: done) { model.openMission(mission.id) }
                }
            } else {
                ForEach(done ? doneChats : chats) { session in
                    ChatCard(session: session, signal: done ? nil : session.signal(unread: model.isUnread(session)),
                             done: done) { model.open(session: session.id) }
                        .contextMenu {
                            if done {
                                Button("Delete…", role: .destructive) { deleting = session }
                            }
                        }
                }
            }
        }
    }

    private var emptyText: String {
        switch kind {
        case .missions: "No mission running. Start one from a ticket in Sprint (Start → Mission)."
        case .quickFixes: "No Quick fix running. Pick Quick fix in the composer or from a ticket."
        case .features: "No Feature running. Start one from the composer or a ticket in Sprint."
        }
    }
}

/// The card frame shared by chats and missions.
private struct WorkCard<Content: View>: View {
    var done = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
                // Done work keeps the card neutral and wears a violet leading edge, like a merged PR.
                .overlay(alignment: .leading) {
                    if done {
                        UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card, bottomLeadingRadius: Theme.Radius.card)
                            .fill(Theme.done).frame(width: 3)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(hovered ? Theme.mutedForeground.opacity(0.4) : done ? Theme.done.opacity(0.35) : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ChatCard: View {
    let session: SessionSummary
    let signal: SessionSignal?
    var done = false
    let open: () -> Void

    var body: some View {
        WorkCard(done: done, action: open) {
            HStack(spacing: 6) {
                if let source = session.trackedSource {
                    Text(source.label).font(.pilot(.caption, weight: .medium)).foregroundStyle(Theme.mutedForeground)
                }
                Spacer(minLength: 4)
                if let signal { StatusMarkShape(signal: signal, background: session.isWaitingOnJobs) }
            }
            Text(session.trackedSource?.title ?? session.title)
                .font(.pilot(.body, weight: .medium)).foregroundStyle(Theme.foreground)
                .lineLimit(3).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(stateText).font(.pilot(.caption, weight: done ? .medium : .regular))
                    .foregroundStyle(done ? Theme.done : signal?.tint ?? Theme.mutedForeground)
                if let pr = session.latestPullRequest {
                    Label("#\(pr.number)", icon: PilotIcon.pullRequest).font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
                Text(RelativeDate.ago(done ? session.doneAt ?? session.updatedAt : session.updatedAt))
                    .font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
            }
        }
    }

    private var stateText: String {
        if done { return session.isMerged ? "Merged" : "Done in Linear" }
        return switch signal {
        case .working?: "Working"
        case .needsYou?: "Needs you"
        case .failed?: "Failed"
        case .readyToMerge?: "Ready to merge"
        case nil: session.latestPullRequest == nil ? "Idle" : "In review"
        }
    }
}

private struct MissionCard: View {
    let mission: Mission
    @ObservedObject var client: PilotClient
    var done = false
    let open: () -> Void

    var body: some View {
        WorkCard(done: done, action: open) {
            HStack(spacing: 6) {
                Text(client.project(mission.projectId)?.name ?? "").font(.pilot(.caption, weight: .medium))
                    .foregroundStyle(Theme.mutedForeground)
                Spacer(minLength: 4)
                if (mission.needsYouCount ?? 0) > 0 { StatusMarkShape(signal: .needsYou) }
            }
            Text(mission.title).font(.pilot(.body, weight: .medium)).foregroundStyle(Theme.foreground)
                .lineLimit(3).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let total = mission.tasksTotal, total > 0 {
                let done = mission.tasksDone ?? 0
                ProgressView(value: Double(done), total: Double(total)).progressViewStyle(.linear)
                    .tint(self.done ? Theme.done : Theme.brand)
                HStack {
                    Text(self.done ? "Done · \(done)/\(total) tasks" : "\(done)/\(total) tasks").font(.pilot(.caption))
                        .foregroundStyle(self.done ? Theme.done : Theme.mutedForeground)
                    Spacer()
                    if let reason = mission.needsYouReason {
                        Text(reason).font(.pilot(.caption)).foregroundStyle(Theme.warning).lineLimit(1)
                    }
                }
            } else {
                Text(done ? "Done" : "Planning").font(.pilot(.caption, weight: done ? .medium : .regular))
                    .foregroundStyle(done ? Theme.done : Theme.mutedForeground)
            }
        }
    }
}
