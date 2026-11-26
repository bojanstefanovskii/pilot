import Foundation

/// One line of the Today page. Mirrors `TodayItem`.
public struct TodayItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let why: String?
    public let url: String?
    public let source: String?
    public let effort: String?
    public let prompt: String?
    public var done: Bool?
    public var sessionId: String?
}

/// GET /api/today. Mirrors `TodayPage`.
public struct TodayPage: Codable, Sendable, Equatable {
    public let date: String
    public let updatedAt: Double
    public let summary: String?
    public var priorities: [TodayItem]
    public var reviews: [TodayItem]
    public var quickWins: [TodayItem]
    public var waiting: [TodayItem]
    public let lessons: [String]
    public let wrap: String?

    public var isEmpty: Bool { updatedAt == 0 }
}

public struct TodayItemPatch: Encodable, Sendable {
    public let done: Bool?
    public let sessionId: String?

    public init(done: Bool? = nil, sessionId: String? = nil) {
        self.done = done
        self.sessionId = sessionId
    }
}
