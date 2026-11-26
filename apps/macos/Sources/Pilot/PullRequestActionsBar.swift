import PilotCore
import SwiftUI

/// One-click requests on the chat's newest open PR, like a teammate asking the agent: resolve comments, rebase, fix
/// CI. Resolving threads on GitHub is separate and always confirmed thread by thread.
struct PullRequestActionsBar: View {
    @EndpointClient private var endpoint
    let session: SessionSummary
    @State private var sending: PullRequestAction?
    @State private var error: String?
    @State private var resolving: ResolveTarget?

    private var pullRequest: SessionPullRequest? {
        guard !session.isArchived, !session.isMissionCoordinator, !session.isReadOnlyHistory else { return nil }
        return session.linkedPullRequests.filter { $0.state == .open || $0.state == .draft }.max { $0.number < $1.number }
    }

    var body: some View {
        if let pr = pullRequest {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(PullRequestAction.allCases) { action in
                        Button(sending == action ? "\(action.title)…" : action.title) { send(action, pr) }
                            .controlSize(.small)
                            .disabled(sending != nil)
                            .help(action.help)
                    }
                    Button("Resolve threads…") { resolving = ResolveTarget(pullRequest: pr) }
                        .controlSize(.small)
                        .help("Choose which review threads to mark resolved on GitHub.")
                }
                if let error {
                    Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(item: $resolving) { target in
                ResolveThreadsSheet(sessionId: session.id, pullRequest: target.pullRequest)
            }
        }
    }

    private func send(_ action: PullRequestAction, _ pr: SessionPullRequest) {
        sending = action
        error = nil
        Task { @MainActor in
            defer { sending = nil }
            do { try await endpoint.pullRequestAction(session.id, action, url: pr.url) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ResolveTarget: Identifiable {
    let pullRequest: SessionPullRequest
    var id: String { pullRequest.url }
}

/// Lists the PR's unresolved review threads; only the checked ones are resolved on GitHub.
private struct ResolveThreadsSheet: View {
    @EndpointClient private var endpoint
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let pullRequest: SessionPullRequest
    @State private var threads: [PullRequestReviewThread]?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve review threads on #\(pullRequest.number)")
                .font(.pilot(.title, weight: .semibold))
            Text("Pilot resolves only the threads you check. Comments are written by reviewers, not by Pilot.")
                .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
            if let threads {
                if threads.isEmpty {
                    Text("No unresolved threads.").foregroundStyle(Theme.mutedForeground)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(threads) { thread in
                                Toggle(isOn: Binding(
                                    get: { selected.contains(thread.id) },
                                    set: { if $0 { selected.insert(thread.id) } else { selected.remove(thread.id) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text([thread.location, thread.author.map { "@\($0)" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.pilot(.caption, design: .monospaced))
                                            .foregroundStyle(Theme.mutedForeground)
                                        Text(thread.body).font(.pilot(.label)).lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Resolve" : "Resolve \(selected.count)") { resolve() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            do { threads = try await endpoint.reviewThreads(sessionId, url: pullRequest.url).threads }
            catch { self.error = error.localizedDescription; threads = [] }
        }
    }

    private func resolve() {
        busy = true
        error = nil
        let ids = threads?.map(\.id).filter(selected.contains) ?? []
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await endpoint.resolveReviewThreads(sessionId, url: pullRequest.url, threadIds: ids)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
