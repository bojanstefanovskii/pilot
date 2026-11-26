import PilotCore
import SwiftUI

/// The work in progress of one kind as a grid of cards: Missions, Quick fixes or Features. A card names its ticket
/// when the work started from one, its state, its PR and when it last moved. Click opens the chat or mission.
struct WorkBoardView: View {
    enum Kind: String { case missions, quickFixes, features }

    let kind: Kind
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @State private var showDone = false

    private var title: String {
        switch kind {
        case .missions: "Missions"
        case .quickFixes: "Quick fixes"
        case .features: "Features"
        }
    }

    /// Build chats of this kind, mission members excluded: they belong to their mission's card.
    private var chats: [SessionSummary] {
        client.sessions
            .filter { session in
                guard !session.isArchived, session.projectId != nil, !session.isAsk, session.missionId == nil,
                      !session.isMissionCoordinator, !ChatsPage.isFree(session) else { return false }
                return kind == .quickFixes ? session.kind == .quick : session.kind != .quick
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var missions: [Mission] {
        client.missions
            .filter { $0.archivedAt == nil && (showDone || $0.completedAt == nil) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.pilot(.title, weight: .semibold))
                    Text("\(kind == .missions ? missions.count : chats.count)")
                        .font(.pilot(.title)).foregroundStyle(Theme.mutedForeground)
                    Spacer()
                    if kind == .missions { Toggle("Show completed", isOn: $showDone).toggleStyle(.checkbox) }
                }
                if (kind == .missions ? missions.isEmpty : chats.isEmpty) {
                    Text(emptyText).foregroundStyle(Theme.mutedForeground)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    if kind == .missions {
                        ForEach(missions) { mission in MissionCard(mission: mission, client: client) { model.openMission(mission.id) } }
                    } else {
                        ForEach(chats) { session in
                            ChatCard(session: session, signal: session.signal(unread: model.isUnread(session))) {
                                model.open(session: session.id)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.background)
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
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(hovered ? Theme.mutedForeground.opacity(0.4) : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ChatCard: View {
    let session: SessionSummary
    let signal: SessionSignal?
    let open: () -> Void

    var body: some View {
        WorkCard(action: open) {
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
                Text(stateText).font(.pilot(.caption)).foregroundStyle(signal?.tint ?? Theme.mutedForeground)
                if let pr = session.latestPullRequest {
                    Label("#\(pr.number)", icon: PilotIcon.pullRequest).font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
                Text(RelativeDate.ago(session.updatedAt))
                    .font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
            }
        }
    }

    private var stateText: String {
        switch signal {
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
    let open: () -> Void

    var body: some View {
        WorkCard(action: open) {
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
                ProgressView(value: Double(done), total: Double(total)).progressViewStyle(.linear).tint(Theme.brand)
                HStack {
                    Text("\(done)/\(total) tasks").font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                    Spacer()
                    if let reason = mission.needsYouReason {
                        Text(reason).font(.pilot(.caption)).foregroundStyle(Theme.warning).lineLimit(1)
                    }
                }
            } else {
                Text(mission.completedAt == nil ? "Planning" : "Completed").font(.pilot(.caption))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }
}
