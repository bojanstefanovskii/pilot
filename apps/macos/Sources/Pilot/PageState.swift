import SwiftUI

/// In-memory state of the workflow pages (Today, Sprint, Database, Notes…), kept while the app runs so leaving a
/// page and coming back shows it as it was. Only one page is mounted at a time, so a change re-renders that page
/// alone. Keep transient flags (loading, sending, running) in `@State`: a load cancelled by leaving the page must
/// never leave them stuck.
@MainActor
final class PageStateStore: ObservableObject {
    static let shared = PageStateStore()
    private(set) var values: [String: Any] = [:]

    func value<Value>(_ key: String, default initial: Value) -> Value {
        values[key] as? Value ?? initial
    }

    func set<Value>(_ key: String, _ value: Value) {
        objectWillChange.send()
        values[key] = value
    }

    /// Drops every retained page state, for tests.
    func reset() { values.removeAll() }
}

/// `@State` that outlives the view: `@PageState("sprint.projectId") private var projectId: String? = nil`.
/// Keys are namespaced by page; give pages that share a view type (Missions, Features…) distinct prefixes.
@MainActor
@propertyWrapper
struct PageState<Value>: DynamicProperty {
    @ObservedObject private var store: PageStateStore
    private let key: String
    private let initial: Value

    init(wrappedValue: Value, _ key: String) {
        self.initial = wrappedValue
        self.key = key
        self._store = ObservedObject(wrappedValue: PageStateStore.shared)
    }

    var wrappedValue: Value {
        get { store.value(key, default: initial) }
        nonmutating set { store.set(key, newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { store.value(key, default: initial) }, set: { store.set(key, $0) })
    }
}
