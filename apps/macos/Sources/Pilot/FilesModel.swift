import AppKit
import PilotCore
import SwiftUI

/// The read-only file browser of one chat: lazily loaded workspace tree, what changed, and the open file.
/// Owned by `AppModel.fileBrowsers`, so switching inspector tabs or chats keeps expanded folders and the open file.
@MainActor
final class FilesModel: ObservableObject {
    enum Mode: String, CaseIterable { case file = "File", diff = "Diff" }

    /// One visible tree row.
    struct Row: Identifiable, Equatable {
        let entry: WorkspaceTreeEntry
        let depth: Int
        var id: String { entry.path }
    }

    /// The open file, highlighted off the main thread.
    struct Document {
        let path: String
        let text: NSAttributedString
        let lineStarts: [Int]
        let binary: Bool
        let truncated: Bool
    }

    let sessionId: String
    @Published private(set) var children: [String: [WorkspaceTreeEntry]] = [:]
    @Published private(set) var truncatedDirectories: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var filter = ""
    @Published var changedOnly = false
    @Published var mode: Mode = .file
    @Published private(set) var openPath: String?
    @Published private(set) var document: Document?
    @Published private(set) var loadingFile = false
    @Published private(set) var changed: [String: ChangedFile] = [:]
    @Published private(set) var diffs: [String: FileDiff] = [:]
    @Published private(set) var error: String?
    @Published private(set) var lastChanges: SessionChanges?
    private var refreshingChanges = false
    private var fileTask: Task<Void, Never>?

    init(sessionId: String) { self.sessionId = sessionId }

    // MARK: Tree

    var hasRoot: Bool { children[""] != nil }

    /// Expanded tree, or every loaded path matching the filter. Changed-only lists the changed files flat.
    var rows: [Row] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if changedOnly {
            return changed.keys.sorted()
                .filter { query.isEmpty || $0.lowercased().contains(query) }
                .map { Row(entry: WorkspaceTreeEntry(name: ($0 as NSString).lastPathComponent, path: $0, kind: .file), depth: 0) }
        }
        if !query.isEmpty {
            return children.values.joined()
                .filter { $0.kind == .file && $0.path.lowercased().contains(query) }
                .sorted { $0.path < $1.path }
                .prefix(500)
                .map { Row(entry: $0, depth: 0) }
        }
        var rows: [Row] = []
        func walk(_ path: String, depth: Int) {
            for entry in children[path] ?? [] {
                rows.append(Row(entry: entry, depth: depth))
                if entry.kind == .directory, expanded.contains(entry.path) { walk(entry.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return rows
    }

    /// Changed files inside a folder, for its badge.
    func changedCount(under directory: String) -> Int {
        let prefix = directory + "/"
        return changed.keys.reduce(0) { $0 + ($1.hasPrefix(prefix) ? 1 : 0) }
    }

    func loadDirectory(_ path: String, client: PilotClient) async {
        do {
            let page = try await client.tree(sessionId, path: path)
            if children[path] != page.entries { children[path] = page.entries }
            if page.truncated { truncatedDirectories.insert(path) } else { truncatedDirectories.remove(path) }
            if error != nil { error = nil }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    func toggle(_ directory: String, client: PilotClient) {
        if expanded.remove(directory) != nil { return }
        expanded.insert(directory)
        if children[directory] == nil { Task { await loadDirectory(directory, client: client) } }
    }

    /// Reloads the root and every expanded folder, so files the agent added or removed appear.
    func reloadTree(client: PilotClient) async {
        for path in [""] + expanded.sorted() where path.isEmpty || children[path] != nil {
            await loadDirectory(path, client: client)
        }
    }

    // MARK: Changes

    func refreshChanges(client: PilotClient) async {
        guard !refreshingChanges else { return }
        refreshingChanges = true
        defer { refreshingChanges = false }
        do {
            let changes = try await client.changes(sessionId)
            guard changes != lastChanges else { return }
            let treeChanged = Set(changes.files.map(\.path)) != Set(lastChanges?.files.map(\.path) ?? [])
            lastChanges = changes
            let parsed = await Task.detached(priority: .utility) {
                Dictionary(Diff.parseUnified(changes.diff).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            }.value
            changed = Dictionary(changes.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            diffs = parsed
            if treeChanged, hasRoot { await reloadTree(client: client) }
            if let openPath, changed[openPath] != nil { reopen(client: client) }
        } catch {
            // Changes are an overlay: the tree stays usable without them.
        }
    }

    // MARK: File

    func open(_ path: String, client: PilotClient) {
        if openPath != path { mode = changed[path] != nil && diffs[path] != nil ? .diff : .file }
        openPath = path
        reopen(client: client)
    }

    func close() {
        fileTask?.cancel()
        openPath = nil
        document = nil
    }

    private func reopen(client: PilotClient) {
        guard let path = openPath else { return }
        fileTask?.cancel()
        loadingFile = document?.path != path
        let palette = SyntaxPalette()
        fileTask = Task { [weak self] in
            do {
                let content = try await client.file(self?.sessionId ?? "", path: path)
                let built = await Task.detached(priority: .userInitiated) {
                    FilesModel.highlight(content, palette: palette)
                }.value
                guard !Task.isCancelled, let self, self.openPath == path else { return }
                self.document = built.document
                self.loadingFile = false
                self.error = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loadingFile = false
                if !error.isCancellation { self.error = error.localizedDescription }
            }
        }
    }

    /// Colors resolved on the main thread, then used to build the attributed text in the background.
    struct SyntaxPalette: @unchecked Sendable {
        let colors: [CodeSyntax.Kind?: NSColor]
        let font: NSFont

        @MainActor init() {
            var colors: [CodeSyntax.Kind?: NSColor] = [:]
            for kind: CodeSyntax.Kind? in [nil, .keyword, .string, .number, .comment, .literal, .function] {
                colors[kind] = NSColor(Theme.syntaxColor(kind))
            }
            self.colors = colors
            font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    private struct Built: @unchecked Sendable { let document: Document }

    nonisolated private static func highlight(_ content: SessionFileContent, palette: SyntaxPalette) -> Built {
        let source = content.binary ? "" : content.text
        let text = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: palette.font, .foregroundColor: palette.colors[nil] as Any]
        text.beginEditing()
        for token in CodeSyntax.tokens(source, language: CodeSyntax.language(forPath: content.path)) {
            var attributes = base
            attributes[.foregroundColor] = palette.colors[token.kind] ?? palette.colors[nil]
            text.append(NSAttributedString(string: token.text, attributes: attributes))
        }
        text.endEditing()
        return Built(document: Document(path: content.path, text: text, lineStarts: lineStarts(source),
                                        binary: content.binary, truncated: content.truncated))
    }

    /// UTF-16 offsets where each line starts, for the line-number gutter.
    nonisolated static func lineStarts(_ source: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        if starts.count > 1, starts.last == offset { starts.removeLast() }
        return starts
    }
}

extension AppModel {
    /// The Files pane state of a chat. Keeps the eight most recently used chats.
    func fileBrowser(for sessionId: String) -> FilesModel {
        fileBrowserOrder.removeAll { $0 == sessionId }
        fileBrowserOrder.append(sessionId)
        if let model = fileBrowsers[sessionId] { return model }
        let model = FilesModel(sessionId: sessionId)
        fileBrowsers[sessionId] = model
        while fileBrowserOrder.count > 8 { fileBrowsers[fileBrowserOrder.removeFirst()] = nil }
        return model
    }
}
