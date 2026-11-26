import AppKit
import PilotCore
import SwiftUI

/// Workflow pages of the main window, listed at the top of the sidebar.
enum WorkflowPage: String, Hashable {
    case today, chats, sprint, reviews, routines, database, missions, quickFixes, features, pullRequests, notes
}

/// PRs that wait on the user's review, per project. "Test this PR" opens a Build chat on the PR's branch that tries
/// it the way a reviewer would, without pushing or commenting.
struct ReviewsView: View {
    static let windowID = "reviews"
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @State private var projectId: String?
    @State private var requests: [PullRequestReviewRequest] = []
    @State private var loading = false
    @State private var error: String?
    @State private var testing: Int?

    private var projects: [Project] { client.projects.filter { $0.workspace != "direct" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reviews").font(.pilot(.title, weight: .semibold))
                Picker("Project", selection: $projectId) {
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { PilotSymbol(PilotIcon.update, context: .toolbar) }
                    .rowIconButtonStyle()
                    .help("Reload")
            }
            if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
            if requests.isEmpty, !loading, error == nil {
                Text("No pull request waits on your review.").foregroundStyle(Theme.mutedForeground)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(requests) { request in row(request) }
                }
            }
        }
        .padding(20)
        .background(Theme.background)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { if projectId == nil { projectId = projects.first?.id } }
        .task(id: projectId) { await load() }
    }

    private func row(_ request: PullRequestReviewRequest) -> some View {
        VStack(spacing: 0) {
            HairlineDivider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let url = URL(string: request.url) {
                            Link("#\(request.number)", destination: url).font(.pilot(.label, weight: .medium))
                        }
                        Text(request.title).font(.pilot(.body)).foregroundStyle(Theme.foreground).lineLimit(1)
                    }
                    Text([request.author.map { "@\($0)" }, request.branch, request.isDraft == true ? "draft" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
                Button(testing == request.number ? "Starting…" : "Test this PR") { test(request) }
                    .controlSize(.small)
                    .disabled(testing != nil)
                    .help("Open a chat on this PR's branch that runs and tries it, without pushing or commenting.")
            }
            .padding(.vertical, 9)
        }
    }

    private func load() async {
        guard let projectId else { return }
        loading = true
        defer { loading = false }
        do {
            requests = try await client.reviewRequests(projectId: projectId)
            error = nil
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }

    private func test(_ request: PullRequestReviewRequest) {
        guard let projectId else { return }
        testing = request.number
        Task {
            defer { testing = nil }
            do {
                let session = try await client.testPullRequest(projectId: projectId, number: request.number)
                model.open(session: session.id)
            } catch { if !error.isCancellation { self.error = error.localizedDescription } }
        }
    }
}

/// Every pending schedule, recurring routines first, with their next run and last outcome.
struct RoutinesView: View {
    static let windowID = "routines"
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient

    private var items: [ScheduledItem] {
        client.schedules
            .filter { $0.state == .pending || $0.state == .failed }
            .sorted { ($0.cron != nil ? 0 : 1, $0.at ?? .infinity) < ($1.cron != nil ? 0 : 1, $1.at ?? .infinity) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routines").font(.pilot(.title, weight: .semibold))
            Text("Recurring routines and scheduled chats. Create one from Send later in any composer, with Repeat.")
                .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
            if items.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(Theme.mutedForeground)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        ScheduledItemRow(item: item, detail: detail(item)) { id in
                            model.open(session: id)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.background)
        .frame(minWidth: 560, minHeight: 380)
    }

    private func detail(_ item: ScheduledItem) -> String {
        var parts: [String] = []
        if let runs = item.runs, runs > 0 { parts.append("\(runs) run\(runs == 1 ? "" : "s")") }
        if let error = item.error { parts.append("Last run: \(error)") }
        return parts.isEmpty ? ScheduleText.detail(item) : parts.joined(separator: " · ")
    }
}
