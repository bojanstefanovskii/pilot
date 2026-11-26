import Foundation

/// One-click requests on a chat's open PR. Mirrors `PullRequestAction`.
public enum PullRequestAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case resolveComments = "resolve_comments"
    case rebaseMain = "rebase_main"
    case fixCI = "fix_ci"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .resolveComments: return "Resolve comments"
        case .rebaseMain: return "Rebase"
        case .fixCI: return "Fix CI"
        }
    }

    public var help: String {
        switch self {
        case .resolveComments: return "Ask the agent to address the PR's unresolved review comments."
        case .rebaseMain: return "Ask the agent to rebase the PR onto its base branch and push."
        case .fixCI: return "Ask the agent to read the failing checks, fix them and push."
        }
    }
}

public struct PullRequestActionRequest: Encodable, Sendable {
    public let action: PullRequestAction
    public let url: String?

    public init(action: PullRequestAction, url: String? = nil) {
        self.action = action
        self.url = url
    }
}

/// An unresolved, non-outdated review thread with its first comment. Mirrors `PullRequestReviewThread`.
public struct PullRequestReviewThread: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let path: String?
    public let line: Int?
    public let author: String?
    public let body: String
    public let url: String?

    public var location: String? {
        path.map { path in line.map { "\(path):\($0)" } ?? path }
    }
}

public struct PullRequestReviewThreads: Codable, Sendable {
    public let url: String
    public let threads: [PullRequestReviewThread]
}

public struct ResolveReviewThreadsRequest: Encodable, Sendable {
    public let url: String
    public let threadIds: [String]

    public init(url: String, threadIds: [String]) {
        self.url = url
        self.threadIds = threadIds
    }
}

/** An open PR that requests the user's review. Mirrors the daemon's `ReviewRequest`. */
public struct PullRequestReviewRequest: Codable, Hashable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let url: String
    public let branch: String
    public let author: String?
    public let updatedAt: Double
    public let isDraft: Bool?
    public var id: String { url }
}

public struct PullRequestReviewRequests: Codable, Sendable {
    public let requests: [PullRequestReviewRequest]
}

public struct ResolveReviewThreadsResponse: Decodable, Sendable {
    public let resolved: [String]
}
