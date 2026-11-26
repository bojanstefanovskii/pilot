import Foundation

/// One shell command run in a chat's workspace through the user's login shell. Mirrors `WorkspaceScriptStep`.
public struct WorkspaceScriptStep: Codable, Equatable, Hashable, Sendable {
    public var command: String
    public var name: String?
    public var timeoutMs: Int?

    public init(command: String, name: String? = nil, timeoutMs: Int? = nil) {
        self.command = command
        self.name = name
        self.timeoutMs = timeoutMs
    }
}

/// Personal project scripts, kept in Pilot's settings and never in the repository. Mirrors `WorkspaceScripts`.
public struct WorkspaceScripts: Codable, Equatable, Hashable, Sendable {
    public var setup: [WorkspaceScriptStep]?
    /// Replaces setup for Quick fix chats.
    public var quickSetup: [WorkspaceScriptStep]?
    /// Replaces setup for a squad agent once its mission has a ready environment.
    public var agentSetup: [WorkspaceScriptStep]?
    public var run: String?
    public var checks: [WorkspaceScriptStep]?
    public var teardown: [WorkspaceScriptStep]?

    public init(setup: [WorkspaceScriptStep]? = nil, run: String? = nil, checks: [WorkspaceScriptStep]? = nil,
                teardown: [WorkspaceScriptStep]? = nil, quickSetup: [WorkspaceScriptStep]? = nil,
                agentSetup: [WorkspaceScriptStep]? = nil) {
        self.setup = setup
        self.agentSetup = agentSetup
        self.quickSetup = quickSetup
        self.run = run
        self.checks = checks
        self.teardown = teardown
    }

    /// Steps from a multi-line field: one command per line, blank lines and `#` comments skipped.
    public static func steps(fromLines text: String) -> [WorkspaceScriptStep] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { WorkspaceScriptStep(command: $0) }
    }

    /// Commands only (names and timeouts are not edited in Settings), empty parts as nil, so a saved value and the
    /// same value typed in the form compare equal.
    public static func normalized(_ scripts: WorkspaceScripts?) -> WorkspaceScripts {
        let setup = (scripts?.setup ?? []).map { WorkspaceScriptStep(command: $0.command) }
        let checks = (scripts?.checks ?? []).map { WorkspaceScriptStep(command: $0.command) }
        let teardown = (scripts?.teardown ?? []).map { WorkspaceScriptStep(command: $0.command) }
        let quick = (scripts?.quickSetup ?? []).map { WorkspaceScriptStep(command: $0.command) }
        let agent = (scripts?.agentSetup ?? []).map { WorkspaceScriptStep(command: $0.command) }
        let run = scripts?.run?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WorkspaceScripts(setup: setup.isEmpty ? nil : setup, run: run.isEmpty ? nil : run,
                                checks: checks.isEmpty ? nil : checks, teardown: teardown.isEmpty ? nil : teardown,
                                quickSetup: quick.isEmpty ? nil : quick, agentSetup: agent.isEmpty ? nil : agent)
    }

    /// The editable text of a step list: one command per line.
    public static func lines(_ steps: [WorkspaceScriptStep]?) -> String {
        (steps ?? []).map(\.command).joined(separator: "\n")
    }
}

public struct WorkspaceScriptResult: Codable, Equatable, Hashable, Sendable {
    public let name: String?
    public let command: String
    public let exitCode: Int
    public let durationMs: Double
    public let output: String
    public let timedOut: Bool?

    public init(name: String? = nil, command: String, exitCode: Int, durationMs: Double, output: String,
                timedOut: Bool? = nil) {
        self.name = name
        self.command = command
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.output = output
        self.timedOut = timedOut
    }

    /// `install deps (exit 1)`, `pnpm test (timed out)`.
    public var summary: String {
        let label = name ?? String(command.prefix(80))
        return timedOut == true ? "\(label) (timed out)" : "\(label) (exit \(exitCode))"
    }
}

/// The last setup or checks run in a chat's workspace. Mirrors `WorkspaceScriptRun`.
public struct WorkspaceScriptRun: Codable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable { case running, ok, failed }

    public let state: State
    public let startedAt: Double
    public let finishedAt: Double?
    public let results: [WorkspaceScriptResult]

    public init(state: State, startedAt: Double, finishedAt: Double? = nil, results: [WorkspaceScriptResult] = []) {
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
    }

    public var failedStep: WorkspaceScriptResult? {
        state == .failed ? results.last : nil
    }

    /// Whole seconds from start to finish, for a one-line chat event.
    public var seconds: Int? {
        finishedAt.map { max(0, Int((($0 - startedAt) / 1_000).rounded())) }
    }
}

/// POST /api/work/chat.
public struct StartWorkChatRequest: Encodable, Sendable {
    public let spawn: SpawnRequest
    public let trackedItemId: String?

    public init(spawn: SpawnRequest, trackedItemId: String? = nil) {
        self.spawn = spawn
        self.trackedItemId = trackedItemId
    }
}

public struct StartWorkChatResponse: Decodable, Sendable {
    public let session: SessionSummary
    /// The chat started but the item could not be linked or moved.
    public let linkError: String?
}
