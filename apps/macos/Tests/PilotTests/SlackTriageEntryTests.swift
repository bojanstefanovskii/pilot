import Foundation
import PilotCore
import Testing
@testable import Pilot

private let local = HostRef(hostId: "local", daemonId: "triage-local", lineageId: "1")
private let remote = HostRef(hostId: "devbox", daemonId: "triage-remote", lineageId: "2")
private let project = Project(id: "same", name: "Repository", path: "/repo",
                              tracking: .init(slackChannels: ["C1"]), createdAt: 1)

@MainActor private func fixture() throws -> AppModel {
    let app = AppModel(projectFolderDefaults: UserDefaults(suiteName: "triage-entry-\(UUID())")!)
    app.client.loadFixture(projects: [project], sessions: [])
    app.client.loadTrackingFixture(TrackingFixture(sources: [
        TrackingSource(id: "slack", projectId: project.id, kind: .slack, label: "Slack",
                       configured: true, status: .ok),
    ]))
    try app.registerLocal(local)
    try loadClientFixture(app.client, host: local, into: app.hosts)
    return app
}

@Test @MainActor func slackTriageEntryNormalizesLocalAndRemoteProjectKeys() throws {
    let app = try fixture()
    for host in [local, remote] {
        let context = HostViewContext(host: host, hosts: app.hosts)
        let ref = context.ref(.project, project.id)
        for qualified in [false, true] {
            app.openSlackTriage(qualified ? ref.storageKey : project.id, caseId: "case", context: context)
            let key = host == local ? project.id : ref.storageKey
            #expect(app.selectedProjectId == key)
            #expect(app.slackTriageProjectId == key, "the window must select triage, not the Overview")
            #expect(app.slackTriageCaseId == "case")
            app.openProject(project.id, context: context)
            #expect(app.slackTriageProjectId == nil)
        }
    }
}
