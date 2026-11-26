import PilotCore
import SwiftUI

/// What Write summary asks to describe: a Build chat, or a whole mission through its coordinator.
enum WorkSummaryTarget: Equatable {
    case session(String)
    case mission(String)
}

extension AppModel {
    /// Sends the request, then opens the writing chat with its Artifacts tab, where the summary appears.
    func writeSummary(_ target: WorkSummaryTarget) async throws {
        let chat: String
        switch target {
        case let .session(id):
            try await client.writeSummary(sessionId: id)
            chat = id
        case let .mission(id):
            chat = try await client.writeMissionSummary(id)
        }
        open(session: chat)
        inspectorTab = .artifacts
        inspectorVisible = true
    }
}

/// Write summary, for a menu or a toolbar. Busy while the request is sent; errors show in an alert.
struct WriteSummaryButton: View {
    @EnvironmentObject private var model: AppModel
    let target: WorkSummaryTarget
    var label = "Write Summary"
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Button {
            sending = true
            Task { @MainActor in
                defer { sending = false }
                do { try await model.writeSummary(target) } catch { self.error = error.localizedDescription }
            }
        } label: {
            Label(sending ? "Asking…" : label, systemImage: "doc.text.magnifyingglass")
        }
        .disabled(sending)
        .help("Ask the agent to write what was done, as an artifact you can reopen later")
        .alert("Couldn't ask for a summary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
