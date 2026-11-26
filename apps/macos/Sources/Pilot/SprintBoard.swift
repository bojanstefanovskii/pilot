import AppKit
import PilotCore
import SwiftUI

/// The current Linear cycle as a Linear-style list: grouped by status, then by project, sub-issues under their
/// parent. Each row carries priority, identifier, status, title, labels, the linked chat's PR and agent state, and
/// its creation date. Start opens a chat on the ticket (Quick fix or Feature) and moves it in Linear.
struct SprintBoardView: View {
    static let windowID = "sprint"
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @State private var projectId: String?
    @State private var items: [TrackedItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var starting: String?
    @State private var collapsed: Set<String> = []

    private var projects: [Project] { client.projects.filter { !($0.tracking?.linearTeam ?? "").isEmpty } }

    /// Status groups in Linear's order: review first, then in progress, todo, backlog, done. Canceled is hidden.
    struct StatusGroup: Identifiable {
        let name: String
        let type: String
        let items: [TrackedItem]
        var id: String { name }
    }

    static func rank(_ item: TrackedItem) -> Int {
        switch item.metadata["statusType"]?.string ?? "" {
        case "started": item.status.localizedCaseInsensitiveContains("review") ? 0 : 1
        case "unstarted": 2
        case "backlog", "triage": 3
        case "completed": 4
        default: 5
        }
    }

    private var groups: [StatusGroup] {
        let visible = items.filter { $0.metadata["statusType"]?.string != "canceled" }
        let byStatus = Dictionary(grouping: visible, by: \.status)
        return byStatus.map { status, items in
            StatusGroup(name: status, type: items.first?.metadata["statusType"]?.string ?? "", items: items)
        }
        .sorted { (Self.rank($0.items[0]), $0.name) < (Self.rank($1.items[0]), $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("\(items.filter { $0.metadata["statusType"]?.string != "canceled" }.count) issues")
                    .font(.pilot(.headline, weight: .semibold))
                Picker("Project", selection: $projectId) {
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await sync() } } label: { PilotSymbol(PilotIcon.refresh, context: .toolbar) }
                    .rowIconButtonStyle()
                    .disabled(loading)
                    .help("Sync Linear now")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if let error {
                Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive).padding(.horizontal, 20)
            }
            if projects.isEmpty {
                Text("Attach a Linear team in a project's settings to see its cycle here.")
                    .foregroundStyle(Theme.mutedForeground).padding(20)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        statusHeader(group)
                        if !collapsed.contains(group.id) {
                            ForEach(projectGroups(group.items), id: \.name) { project in
                                projectHeader(project.name, count: project.items.count)
                                ForEach(nested(project.items), id: \.item.id) { entry in
                                    row(entry.item, depth: entry.depth)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
        }
        .background(Theme.background)
        .task(id: projectId) {
            if projectId == nil { projectId = projects.first?.id; return }
            await load()
        }
    }

    // MARK: Grouping

    private func projectGroups(_ items: [TrackedItem]) -> [(name: String, items: [TrackedItem])] {
        let byProject = Dictionary(grouping: items) { $0.metadata["project"]?.string ?? "" }
        return byProject.map { (name: $0.key.isEmpty ? "No project" : $0.key, items: $0.value) }
            .sorted { ($0.name == "No project" ? 1 : 0, $0.name) < ($1.name == "No project" ? 1 : 0, $1.name) }
    }

    /// Parents first, each followed by its sub-issues in the same group, indented.
    private func nested(_ items: [TrackedItem]) -> [(item: TrackedItem, depth: Int)] {
        let ids = Set(items.map(\.externalId))
        let children = Dictionary(grouping: items.filter { ids.contains($0.metadata["parentId"]?.string ?? "") }) {
            $0.metadata["parentId"]!.string!
        }
        let roots = items.filter { !ids.contains($0.metadata["parentId"]?.string ?? "") }.sorted(by: Self.newest)
        var result: [(TrackedItem, Int)] = []
        func visit(_ item: TrackedItem, _ depth: Int) {
            result.append((item, depth))
            for child in (children[item.externalId] ?? []).sorted(by: Self.newest) where depth < 4 { visit(child, depth + 1) }
        }
        roots.forEach { visit($0, 0) }
        return result
    }

    private static func newest(_ a: TrackedItem, _ b: TrackedItem) -> Bool { created(a) > created(b) }
    private static func created(_ item: TrackedItem) -> Double {
        if case let .number(value)? = item.metadata["createdAt"] { return value }
        return item.createdAt
    }

    // MARK: Rows

    private func statusHeader(_ group: StatusGroup) -> some View {
        Button {
            if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
        } label: {
            HStack(spacing: 10) {
                PilotSymbol(collapsed.contains(group.id) ? PilotIcon.disclosure : PilotIcon.disclosureOpen)
                    .foregroundStyle(Theme.faintForeground)
                    .frame(width: 12)
                StatusIcon(type: group.type, review: group.name.localizedCaseInsensitiveContains("review"))
                Text(group.name).font(.pilot(.body, weight: .semibold)).foregroundStyle(Theme.foreground)
                Text("\(group.items.count)").font(.pilot(.body)).foregroundStyle(Theme.mutedForeground)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.tray))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private func projectHeader(_ name: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.pilot(.label, weight: .medium)).foregroundStyle(Theme.foreground).lineLimit(1)
            Text("\(count)").font(.pilot(.label)).foregroundStyle(Theme.mutedForeground)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func row(_ item: TrackedItem, depth: Int) -> some View {
        SprintRow(item: item, depth: depth, session: item.sessionId.flatMap { client.session($0) },
                  unread: { model.isUnread($0) }, starting: starting == item.id,
                  start: { kind in start(item, kind: kind) },
                  startMission: { startMission(item) },
                  open: { model.open(session: $0) })
    }

    // MARK: Actions

    /// Polls the project's Linear source now, then reloads the list.
    private func sync() async {
        guard let projectId, let source = client.source(projectId: projectId, kind: .linear) else { return await load() }
        loading = true
        do { _ = try await client.pollSource(source.id) }
        catch { if !error.isCancellation { self.error = error.localizedDescription } }
        loading = false
        await load()
    }

    private func load() async {
        guard let projectId else { return }
        loading = true
        defer { loading = false }
        do {
            // The API pages at 100; a cycle rarely needs more than a few pages.
            var all: [TrackedItem] = []
            while all.count < 500 {
                let page = try await client.trackedItems(projectId: projectId, kind: .linear, limit: 100, offset: all.count)
                all += page.items
                if page.items.isEmpty || all.count >= page.total { break }
            }
            items = all
            error = nil
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }

    /// A Squad: a mission on the ticket with a coordinator that plans it and starts agents. Linked like a chat start.
    private func startMission(_ item: TrackedItem) {
        let identifier = item.metadata["identifier"]?.string ?? ""
        starting = item.id
        Task {
            defer { starting = nil }
            do {
                let detail = try await client.createMission(CreateMissionRequest(
                    projectId: item.projectId, title: "\(identifier) \(item.title)".trimmingCharacters(in: .whitespaces),
                    goal: "Deliver Linear \(identifier): \(item.title)", startCoordinator: true,
                    message: "Plan Linear \(identifier) (\(item.url)) into tasks, then start agents for them."
                ))
                _ = try await client.updateTrackedItem(item.id, TrackedItemPatch(missionId: detail.mission.id, start: true))
                await load()
            } catch { if !error.isCancellation { self.error = error.localizedDescription } }
        }
    }

    private func start(_ item: TrackedItem, kind: WorkKind) {
        let identifier = item.metadata["identifier"]?.string ?? item.title
        starting = item.id
        Task {
            defer { starting = nil }
            do {
                let spawn = SpawnRequest(projectId: item.projectId,
                                         message: "Work on Linear \(identifier): \(item.title)\n\(item.url)",
                                         mode: .build, kind: kind == .quick ? .quick : nil)
                let response = try await client.startWorkChat(StartWorkChatRequest(spawn: spawn, trackedItemId: item.id))
                if let linkError = response.linkError { error = "Chat started, but: \(linkError)" }
                await load()
            } catch { if !error.isCancellation { self.error = error.localizedDescription } }
        }
    }
}

/// One ticket line, Linear-style. Hover reveals Start (or Open chat when a chat is linked).
private struct SprintRow: View {
    let item: TrackedItem
    let depth: Int
    let session: SessionSummary?
    let unread: (SessionSummary) -> Bool
    let starting: Bool
    let start: (WorkKind) -> Void
    let startMission: () -> Void
    let open: (String) -> Void
    @State private var hovered = false

    private var done: Bool { item.metadata["statusType"]?.string == "completed" }

    var body: some View {
        HStack(spacing: 10) {
            PriorityIcon(priority: item.metadata["priority"].flatMap { if case let .number(value) = $0 { Int(value) } else { nil } })
            Text(item.metadata["identifier"]?.string ?? "")
                .font(.pilot(.label)).foregroundStyle(Theme.mutedForeground)
                .frame(width: 92, alignment: .leading)
            StatusIcon(type: item.metadata["statusType"]?.string ?? "", review: item.status.localizedCaseInsensitiveContains("review"))
            Text(item.title)
                .font(.pilot(.body, weight: depth == 0 ? .medium : .regular))
                .foregroundStyle(done ? Theme.mutedForeground : Theme.foreground)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 12)
            chips
            if let session, let signal = session.signal(unread: unread(session)) {
                StatusMarkShape(signal: signal, background: session.isWaitingOnJobs)
                    .help("Chat: \(session.title)")
            }
            trailing.frame(width: 96, alignment: .trailing)
        }
        .padding(.leading, 34 + CGFloat(depth) * 22).padding(.trailing, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(hovered ? Theme.tray : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if let url = URL(string: item.url) { Button("Open in Linear") { NSWorkspace.shared.open(url) } }
            if let session { Button("Open Chat") { open(session.id) } }
            if session == nil, item.missionId == nil, !done {
                ForEach(WorkKind.allCases, id: \.self) { kind in Button("Start as \(kind.title)") { start(kind) } }
                Button("Start as Mission") { startMission() }
            }
        }
    }

    @ViewBuilder private var chips: some View {
        let labels = Self.labels(item)
        HStack(spacing: 4) {
            if let flag = Self.flag(item: item, session: session) {
                Text(flag.title)
                    .font(.pilot(.caption, weight: .semibold))
                    .foregroundStyle(flag.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(flag.color.opacity(0.14)))
                    .help(flag.help)
            }
            ForEach(labels.prefix(3), id: \.self) { label in
                Chip { Circle().fill(Self.color(label)).frame(width: 7, height: 7); Text(label) }
            }
            if let pr = session?.latestPullRequest {
                Chip { PilotSymbol(PilotIcon.pullRequest); Text("#\(pr.number)") }
                    .onTapGesture { if let url = pr.browserURL { NSWorkspace.shared.open(url) } }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if hovered, starting {
            Text("Starting…").font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
        } else if hovered, let session {
            Button("Open chat") { open(session.id) }.controlSize(.small)
        } else if hovered, item.missionId == nil, !done {
            Menu("Start") {
                ForEach(WorkKind.allCases, id: \.self) { kind in Button(kind.title) { start(kind) } }
                Divider()
                Button("Mission (squad)") { startMission() }
            }
            .controlSize(.small).fixedSize()
        } else {
            Text(Self.date(item)).font(.pilot(.label)).foregroundStyle(Theme.mutedForeground)
        }
    }

    /// How the ticket is being worked on: a mission (squad), or the linked chat's kind.
    static func flag(item: TrackedItem, session: SessionSummary?) -> (title: String, color: Color, help: String)? {
        if item.missionId != nil { return ("Mission", Theme.brand, "Worked on by a mission: a coordinator and its agents") }
        guard let session else { return nil }
        return session.kind == .quick
            ? ("Quick fix", Theme.warning, "A Quick fix chat: light setup on the main environment")
            : ("Feature", Theme.chart1, "A Feature chat: its own worktree and full setup")
    }

    static func labels(_ item: TrackedItem) -> [String] {
        guard case let .array(values)? = item.metadata["labels"] else { return [] }
        return values.compactMap { value -> String? in value.string }
    }

    static func date(_ item: TrackedItem) -> String {
        let millis: Double
        if case let .number(value)? = item.metadata["createdAt"] { millis = value } else { millis = item.createdAt }
        return Date(timeIntervalSince1970: millis / 1000).formatted(.dateTime.month(.abbreviated).day())
    }

    /// A stable colour per label name from the shared chart palette.
    static func color(_ label: String) -> Color {
        let palette = [Theme.chart1, Theme.chart2, Theme.chart3, Theme.chart4, Theme.chart5, Theme.chart6]
        let hash = label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return label.localizedCaseInsensitiveContains("bug") ? Theme.destructive : palette[hash % palette.count]
    }
}

private struct Chip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.pilot(.caption))
            .foregroundStyle(Theme.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(Theme.border))
            .frame(maxWidth: 160)
    }
}

/// Linear's priority glyph: three bars filled by priority, a red square for urgent, a dash for none.
private struct PriorityIcon: View {
    let priority: Int?

    var body: some View {
        Group {
            switch priority ?? 0 {
            case 1:
                RoundedRectangle(cornerRadius: 2).fill(Theme.warning)
                    .overlay(Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                    .frame(width: 12, height: 12)
            case 2, 3, 4:
                let filled = 5 - (priority ?? 4)
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0 ..< 3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(index < filled ? Theme.mutedForeground : Theme.border)
                            .frame(width: 3, height: CGFloat(5 + index * 3))
                    }
                }
            default:
                Text("···").font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
            }
        }
        .frame(width: 16, height: 14)
        .help(["No priority", "Urgent", "High", "Medium", "Low"][min(max(priority ?? 0, 0), 4)])
    }
}

/// Linear-like status circle: empty for todo, dashed for backlog, half for in progress, three-quarters in green for
/// review, filled check for done.
private struct StatusIcon: View {
    let type: String
    let review: Bool

    var body: some View {
        ZStack {
            switch type {
            case "completed":
                Circle().fill(Theme.brand)
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
            case "started":
                Circle().stroke(review ? Theme.success : Theme.warning, lineWidth: 1.5)
                Circle().trim(from: 0, to: review ? 0.75 : 0.5)
                    .stroke(review ? Theme.success : Theme.warning, style: StrokeStyle(lineWidth: 3.5))
                    .rotationEffect(.degrees(-90))
                    .padding(2.5)
            case "backlog", "triage":
                Circle().stroke(Theme.faintForeground, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            default:
                Circle().stroke(Theme.mutedForeground, lineWidth: 1.5)
            }
        }
        .frame(width: 14, height: 14)
    }
}
