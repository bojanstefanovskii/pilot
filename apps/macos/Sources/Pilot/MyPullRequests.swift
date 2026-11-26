import AppKit
import PilotCore
import SwiftUI

/// One of the user's PRs in a project's repository. Mirrors the daemon's `MyPullRequest`.
struct MyPullRequest: Decodable, Hashable, Identifiable, Sendable {
    let number: Int
    let title: String
    let url: String
    let branch: String
    let state: String
    let reviewDecision: String?
    let checks: String?
    let updatedAt: Double
    let mergedAt: Double?
    var id: String { url }

    /// Open work that waits on the user: changes requested, or failing CI.
    var needsYou: Bool { (state == "open" || state == "draft") && (reviewDecision == "changes_requested" || checks == "failing") }
    var readyToMerge: Bool { state == "open" && reviewDecision == "approved" && checks != "failing" && checks != "pending" }
}

struct MyPullRequests: Decodable, Sendable { let pullRequests: [MyPullRequest] }

/// Every PR you opened in a project's repository, from Pilot or not: what needs you, what is open, what merged in the
/// last two weeks. A PR a chat worked on links to that chat.
struct PullRequestsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @State private var projectId: String?
    @State private var prs: [MyPullRequest] = []
    @State private var loading = false
    @State private var error: String?

    private var projects: [Project] { client.projects.filter { $0.workspace != "direct" } }
    private static let recent: Double = 14 * 86_400_000

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let open = prs.filter { $0.state == "open" || $0.state == "draft" }
        let merged = prs.filter { $0.state == "merged" && now - ($0.mergedAt ?? $0.updatedAt) < Self.recent }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("Pull requests").font(.pilot(.title, weight: .semibold))
                    Picker("Project", selection: $projectId) {
                        ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await load() } } label: { PilotSymbol(PilotIcon.refresh, context: .toolbar) }
                        .rowIconButtonStyle().disabled(loading).help("Refresh from GitHub")
                }
                if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
                section("Needs you", open.filter(\.needsYou))
                section("Ready to merge", open.filter(\.readyToMerge))
                section("Open", open.filter { !$0.needsYou && !$0.readyToMerge })
                section("Merged · last 14 days", merged)
                if prs.isEmpty, !loading, error == nil {
                    Text("No pull request of yours in this repository.").foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(24)
            .frame(maxWidth: Theme.column + 120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task(id: projectId) {
            if projectId == nil { projectId = model.selectedProjectId.flatMap { id in projects.first { $0.id == id }?.id } ?? projects.first?.id; return }
            await load()
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [MyPullRequest]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(title: title, count: items.count).padding(.bottom, 6)
                ForEach(items) { pr in row(pr) }
            }
        }
    }

    private func row(_ pr: MyPullRequest) -> some View {
        let chat = client.sessions.first { session in session.linkedPullRequests.contains { PullRequestURL.same($0.url, pr.url) } }
        return VStack(spacing: 0) {
            HairlineDivider()
            HStack(spacing: 10) {
                if let url = URL(string: pr.url) {
                    Link("#\(pr.number)", destination: url).font(.pilot(.label, weight: .medium))
                }
                Text(pr.title).font(.pilot(.body)).foregroundStyle(Theme.foreground).lineLimit(1)
                Spacer(minLength: 8)
                if pr.state == "draft" { tag("Draft", Theme.mutedForeground) }
                switch pr.reviewDecision {
                case "approved"?: tag("Approved", Theme.success)
                case "changes_requested"?: tag("Changes requested", Theme.warning)
                case "review_required"?: tag("Review required", Theme.mutedForeground)
                default: EmptyView()
                }
                switch pr.checks {
                case "failing"?: tag("CI failing", Theme.destructive)
                case "pending"?: tag("CI running", Theme.mutedForeground)
                case "passing"?: tag("CI passing", Theme.success)
                default: EmptyView()
                }
                if pr.state == "merged", let merged = pr.mergedAt {
                    Text("Merged \(RelativeDate.ago(merged))").font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                }
                if let chat {
                    Button("Open chat") { model.open(session: chat.id) }.controlSize(.small)
                }
            }
            .padding(.vertical, 9)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.pilot(.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func load() async {
        guard let projectId else { return }
        loading = true
        defer { loading = false }
        do {
            prs = try await client.myPullRequests(projectId: projectId)
            model.pullRequestsNeedingYou[projectId] = prs.filter(\.needsYou).count
            error = nil
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }
}
