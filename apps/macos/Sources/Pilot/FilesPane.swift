import AppKit
import PilotCore
import SwiftUI

/// The Files inspector: a light, read-only IDE for the chat's workspace. A tree with changed files marked, a filter,
/// and the open file with syntax colors and line numbers, or its diff. Nothing here edits: changes go through the agent.
struct FilesPane: View {
    @Environment(\.hostViewContext) private var hostContext
    @Environment(\.repositoryPollingVisible) private var windowVisible
    @EnvironmentObject private var app: AppModel
    @EndpointClient private var endpoint
    let session: SessionSummary
    @ObservedObject var model: FilesModel

    private var pollingKey: RepositoryPollingKey {
        RepositoryPollingKey(visible: windowVisible, state: session.state, updatedAt: session.updatedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let path = model.openPath { fileHeader(path) } else { treeHeader }
            Rectangle().fill(Theme.border).frame(height: 1)
            if let error = model.error {
                Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if model.openPath != nil { fileBody } else { tree }
        }
        .background(Theme.background)
        .task { if !model.hasRoot { await model.loadDirectory("", client: endpoint) } }
        .task(id: pollingKey) {
            guard pollingKey.enabled else { return }
            while !Task.isCancelled {
                await model.refreshChanges(client: endpoint)
                do { try await Task.sleep(for: .seconds(RepositoryPolling.interval(working: session.isWorking, fullDiff: true))) }
                catch { return }
            }
        }
    }

    // MARK: Tree

    private var treeHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                PilotSymbol(PilotIcon.search, context: .inline).foregroundStyle(Theme.faintForeground)
                TextField("Filter files", text: $model.filter)
                    .textFieldStyle(.plain).font(.pilot(.label))
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { PilotSymbol(PilotIcon.clearField, context: .inline) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.faintForeground)
                }
            }
            Picker("", selection: $model.changedOnly) {
                Text("All").tag(false)
                Text(model.changed.isEmpty ? "Changed" : "Changed \(model.changed.count)").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    @ViewBuilder private var tree: some View {
        let rows = model.rows
        if !model.hasRoot {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            Text(model.changedOnly ? "No changed files." : model.filter.isEmpty ? "Empty workspace." : "No loaded file matches.")
                .font(.pilot(.label)).foregroundStyle(Theme.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FileTreeRow(row: row, expanded: model.expanded.contains(row.entry.path),
                                    change: model.changed[row.entry.path],
                                    changedInside: row.entry.kind == .directory ? model.changedCount(under: row.entry.path) : 0,
                                    showsPath: model.changedOnly || !model.filter.isEmpty) {
                            if row.entry.kind == .directory { model.toggle(row.entry.path, client: endpoint) }
                            else { model.open(row.entry.path, client: endpoint) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: File

    private func fileHeader(_ path: String) -> some View {
        HStack(spacing: 6) {
            Button { model.close() } label: { PilotSymbol(PilotIcon.back, context: .inline) }
                .buttonStyle(.borderless).help("Back to files")
            VStack(alignment: .leading, spacing: 0) {
                Text((path as NSString).lastPathComponent).font(.pilot(.label, weight: .medium)).lineLimit(1)
                let directory = (path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory).font(.pilot(.small)).foregroundStyle(Theme.faintForeground)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let change = model.changed[path] {
                DiffStat(additions: change.additions, deletions: change.deletions)
                if model.diffs[path] != nil {
                    Picker("", selection: $model.mode) {
                        ForEach(FilesModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                }
            }
            Menu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                if let url = localURL(path) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open in Default App") { NSWorkspace.shared.open(url) }
                }
            } label: { PilotSymbol(PilotIcon.more, context: .inline) }
                .menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    @ViewBuilder private var fileBody: some View {
        if let path = model.openPath, model.mode == .diff, let diff = model.diffs[path] {
            ScrollView([.vertical, .horizontal]) {
                DiffView(file: diff, maxLines: 4000).padding(.vertical, 6)
            }
        } else if let document = model.document, document.path == model.openPath {
            if document.binary {
                notice("This file cannot be shown as text.")
            } else {
                VStack(spacing: 0) {
                    CodeTextView(document: document)
                    if document.truncated { notice("Showing the first 512 KB of this file.").frame(height: 28) }
                }
            }
        } else if model.loadingFile {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            notice("This file could not be opened.")
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only a local chat's files are on this Mac.
    private func localURL(_ path: String) -> URL? {
        guard hostContext == nil || hostContext?.host == app.localHost, !session.cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: session.cwd).appending(path: path)
    }
}

/// A tree row, Linear-quiet: chevron, name, and a colored letter when the file changed.
private struct FileTreeRow: View {
    let row: FilesModel.Row
    let expanded: Bool
    let change: ChangedFile?
    let changedInside: Int
    let showsPath: Bool
    let action: () -> Void
    @State private var hovered = false

    private var isDirectory: Bool { row.entry.kind == .directory }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "")
                    .font(.pilot(.micro, weight: .semibold)).foregroundStyle(Theme.faintForeground).frame(width: 10)
                Image(systemName: isDirectory ? "folder" : "doc")
                    .font(.pilot(.caption)).foregroundStyle(isDirectory ? Theme.mutedForeground : Theme.faintForeground)
                    .frame(width: 14)
                Text(row.entry.name).font(.pilot(.label)).lineLimit(1)
                    .foregroundStyle(change.map { Self.tint($0.status) } ?? Theme.foreground)
                if showsPath {
                    let directory = (row.entry.path as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(directory).font(.pilot(.small)).foregroundStyle(Theme.faintForeground)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if let change {
                    Text(Self.letter(change.status)).font(.pilot(.small, weight: .semibold))
                        .foregroundStyle(Self.tint(change.status)).help(change.status.capitalized)
                } else if changedInside > 0 {
                    Circle().fill(Theme.warning.opacity(0.8)).frame(width: 5, height: 5)
                        .help("\(changedInside) changed file\(changedInside == 1 ? "" : "s") inside")
                }
            }
            .padding(.leading, 10 + CGFloat(row.depth) * 12)
            .padding(.trailing, 12)
            .frame(height: 24)
            .background(hovered ? Theme.mutedForeground.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    static func letter(_ status: String) -> String {
        switch status {
        case "added", "untracked": "A"
        case "deleted": "D"
        case "renamed": "R"
        default: "M"
        }
    }

    static func tint(_ status: String) -> Color {
        switch status {
        case "added", "untracked": Theme.pullRequestOpen
        case "deleted": Theme.destructive
        default: Theme.warning
        }
    }
}

/// Read-only code view: TextKit, non-contiguous layout and no wrapping, so large files scroll smoothly.
/// ⌘F opens the find bar.
private struct CodeTextView: NSViewRepresentable {
    let document: FilesModel.Document

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isRichText = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let ruler = LineNumberRuler(textView: text)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        apply(to: scroll, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { apply(to: scroll, coordinator: context.coordinator) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to scroll: NSScrollView, coordinator: Coordinator) {
        guard coordinator.shown !== document.text, let text = scroll.documentView as? NSTextView else { return }
        let samePath = coordinator.path == document.path
        let origin = scroll.contentView.bounds.origin
        coordinator.shown = document.text
        coordinator.path = document.path
        text.textStorage?.setAttributedString(document.text)
        coordinator.ruler?.lineStarts = document.lineStarts
        // A refresh of the same file (the agent edited it) keeps the reading position.
        if samePath { scroll.contentView.scroll(to: origin) } else { text.scrollToBeginningOfDocument(nil) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    final class Coordinator {
        var shown: NSAttributedString?
        var path: String?
        var ruler: LineNumberRuler?
    }
}

/// Line numbers drawn only for the visible lines.
private final class LineNumberRuler: NSRulerView {
    var lineStarts: [Int] = [0] {
        didSet {
            let digits = max(3, String(lineStarts.count).count)
            ruleThickness = CGFloat(digits) * 7.5 + 14
            needsDisplay = true
        }
    }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.background).setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text = clientView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer,
              let length = text.textStorage?.length else { return }
        let visible = text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // First line starting at or before the first visible character.
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= characters.location { low = mid + 1 } else { high = mid }
        }
        var line = max(0, low - 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.faintForeground)]
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters), lineStarts[line] < max(length, 1) {
            let glyph = layout.glyphIndexForCharacter(at: min(lineStarts[line], max(length - 1, 0)))
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }
}
