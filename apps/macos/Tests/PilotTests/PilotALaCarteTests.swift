import Foundation
import PilotCore
import Testing
@testable import Pilot

@Test @MainActor func pageStateOutlivesItsViewAndKeepsKeysApart() {
    let store = PageStateStore.shared
    store.reset()
    defer { store.reset() }
    #expect(store.value("sprint.projectId", default: String?.none) == nil)
    store.set("sprint.projectId", Optional("p1"))
    store.set("database.sql", "select 1")
    #expect(store.value("sprint.projectId", default: String?.none) == "p1")
    #expect(store.value("database.sql", default: "") == "select 1")
    #expect(store.value("database.projectId", default: String?.none) == nil)
}

@Test @MainActor func backReturnsToTheWorkflowPageYouLeft() throws {
    let app = AppModel(projectFolderDefaults: UserDefaults(suiteName: "workflow-\(UUID())")!)
    try app.registerLocal(HostRef(hostId: "local", daemonId: "daemon", lineageId: "lineage"))
    app.client.loadFixture(projects: [Project(id: "p1", name: "One", path: "/tmp/one", createdAt: 1)], sessions: [
        SessionSummary(id: "a", title: "A", cwd: "/tmp/one", projectId: "p1", createdAt: 1, updatedAt: 1, state: "idle"),
    ])
    app.showWorkflow(.sprint)
    app.showWorkflow(.database)
    app.open(session: "a")
    app.goBack()
    #expect(app.showingUsage && app.workflowPage == .database)
    app.goBack()
    #expect(app.showingUsage && app.workflowPage == .sprint)
}

@Test func chatsAreDoneWhenGitHubMergedTheirPullRequests() {
    func chat(_ state: PullRequestState, mergedAt: Double? = nil) -> SessionSummary {
        SessionSummary(id: "c", title: "C", cwd: "/tmp", createdAt: 1, updatedAt: 5, state: "idle",
                       pullRequest: SessionPullRequest(number: 1, url: "https://github.com/a/b/pull/1", title: "PR",
                                                       state: state, mergedAt: mergedAt, checkedAt: 1))
    }
    #expect(chat(.merged, mergedAt: 42).doneAt == 42)
    #expect(chat(.merged).isDone)
    #expect(!chat(.open).isDone)
    #expect(!chat(.closed).isDone)
    #expect(!SessionSummary(id: "n", title: "N", cwd: "/tmp", createdAt: 1, updatedAt: 1, state: "idle").isDone)
}

@Test func lineStartsCountEveryLineForTheGutter() {
    #expect(FilesModel.lineStarts("") == [0])
    #expect(FilesModel.lineStarts("a\nbc\n") == [0, 2])
    #expect(FilesModel.lineStarts("a\n\nb") == [0, 2, 3])
}

@Test @MainActor func workflowPagesReopenTheChatOpenedFromThemLikeTabs() throws {
    let app = AppModel(projectFolderDefaults: UserDefaults(suiteName: "workflow-tabs-\(UUID())")!)
    try app.registerLocal(HostRef(hostId: "local", daemonId: "daemon", lineageId: "lineage"))
    app.client.loadFixture(projects: [Project(id: "p1", name: "One", path: "/tmp/one", createdAt: 1)], sessions: [
        SessionSummary(id: "feature", title: "F", cwd: "/tmp/one", projectId: "p1", createdAt: 1, updatedAt: 1, state: "idle"),
    ])
    app.showWorkflow(.features)
    app.open(session: "feature")
    #expect(app.isWorkflowTabSelected(.features))
    app.showWorkflow(.chats)
    #expect(app.workflowPage == .chats)
    app.showWorkflow(.features)
    #expect(app.selectedSessionId == "feature" && app.isWorkflowTabSelected(.features))
    // Selecting the tab again goes back to its board.
    app.showWorkflow(.features)
    #expect(app.workflowPage == .features && app.selectedSessionId == nil)
}
