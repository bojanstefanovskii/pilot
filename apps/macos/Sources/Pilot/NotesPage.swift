import AppKit
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// A personal space like Apple Notes: Markdown notes in folders (`~/Pilot/Notes`), every artifact your chats made, and
/// your own files (`~/Pilot/Files`). Notes are plain files you own: Finder, Spotlight and agents can read them.
struct NotesPage: View {
    enum Tab: String, CaseIterable { case notes = "Notes", artifacts = "Artifacts", files = "Files" }

    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @PageState("notes.tab") private var tab: Tab = .notes

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { HairlineDivider() }
            switch tab {
            case .notes: NotesBrowser()
            case .artifacts: ArtifactsBrowser(client: client)
            case .files: FilesBrowser()
            }
        }
        .background(Theme.background)
    }
}

// MARK: Notes

/// One note file. The title is its first line, as in Apple Notes.
private struct NoteFile: Identifiable, Hashable {
    let url: URL
    let folder: String
    let title: String
    let preview: String
    let modified: Date
    var id: URL { url }
}

private enum NotesStorage {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pilot/Notes")
    static let defaultFolders = ["Notes", "Cheat codes"]

    /// Lists every note off the main thread.
    static func load() async -> (folders: [String], notes: [NoteFile]) {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            for folder in defaultFolders {
                try? manager.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            let folders = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { name in
                    var isDirectory: ObjCBool = false
                    return !name.hasPrefix(".") && manager.fileExists(atPath: root.appending(path: name).path, isDirectory: &isDirectory) && isDirectory.boolValue
                }
                .sorted { (defaultFolders.firstIndex(of: $0) ?? 99, $0) < (defaultFolders.firstIndex(of: $1) ?? 99, $1) }
            var notes: [NoteFile] = []
            for folder in folders {
                let directory = root.appending(path: folder)
                for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".md") {
                    let url = directory.appending(path: name)
                    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    let title = lines.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "New note"
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    notes.append(NoteFile(url: url, folder: folder, title: title.isEmpty ? "New note" : String(title.prefix(120)),
                                          preview: lines.dropFirst().first.map { String($0.prefix(140)) } ?? "", modified: modified))
                }
            }
            return (folders, notes.sorted { $0.modified > $1.modified })
        }.value
    }
}

private struct NotesBrowser: View {
    @PageState("notes.folders") private var folders: [String] = []
    @PageState("notes.notes") private var notes: [NoteFile] = []
    @PageState("notes.folder") private var folder = "Notes"
    @PageState("notes.search") private var search = ""
    @PageState("notes.selected") private var selected: URL? = nil
    @PageState("notes.text") private var text = ""
    @State private var saving: Task<Void, Never>?
    @State private var newFolder = ""
    @State private var addingFolder = false
    @PageState("notes.collapsed") private var collapsed: Set<String> = []

    private var shown: [NoteFile] {
        guard !search.isEmpty else { return notes }
        return notes.filter { note in
            note.title.localizedCaseInsensitiveContains(search)
                || ((try? String(contentsOf: note.url, encoding: .utf8))?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Search all notes", text: $search).textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(folders, id: \.self) { name in Button("New note in \(name)") { createNote(in: name) } }
                        Divider()
                        Button("New Folder…") { addingFolder = true }
                    } label: {
                        PilotSymbol(PilotIcon.compose, context: .toolbar)
                    } primaryAction: {
                        createNote(in: folder)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New note in \(folder). Hold for another folder.")
                }
                .padding(8)
                List(selection: Binding(get: { selected }, set: { open($0) })) {
                    ForEach(folders, id: \.self) { name in
                        let items = shown.filter { $0.folder == name }
                        if search.isEmpty || !items.isEmpty {
                            Section {
                                if !collapsed.contains(name) {
                                    ForEach(items) { note in noteRow(note) }
                                }
                            } header: {
                                Button {
                                    if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
                                } label: {
                                    HStack(spacing: 6) {
                                        PilotSymbol(collapsed.contains(name) ? PilotIcon.disclosure : PilotIcon.disclosureOpen)
                                            .foregroundStyle(Theme.faintForeground)
                                        Text(name).font(.pilot(.label, weight: .semibold)).foregroundStyle(Theme.foreground)
                                        Text("\(notes.filter { $0.folder == name }.count)")
                                            .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(NotesStorage.root) }
                        .buttonStyle(.link).font(.pilot(.caption))
                    Spacer()
                }
                .padding(10)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            .background(Theme.sidebar)

            Group {
                if selected != nil {
                    TextEditor(text: $text)
                        .font(.pilot(.body))
                        .scrollContentBackground(.hidden)
                        .padding(20)
                        .onChange(of: text) { _, value in scheduleSave(value) }
                } else {
                    Text("Select a note, or create one with the pencil.")
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
        .task {
            await reload()
            // Agents and Finder may have changed the open note while the page was away.
            if let selected, saving == nil { text = (try? String(contentsOf: selected, encoding: .utf8)) ?? text }
        }
        .onDisappear { flush() }
        .alert("New Folder", isPresented: $addingFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
    }

    private func noteRow(_ note: NoteFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.pilot(.body, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(note.modified.formatted(date: .abbreviated, time: .omitted))
                Text(note.preview).lineLimit(1)
            }
            .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
        }
        .padding(.vertical, 3)
        .tag(note.url)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Button("Move to Trash", role: .destructive) { trash(note) }
        }
    }

    private func reload() async {
        let loaded = await NotesStorage.load()
        folders = loaded.folders
        notes = loaded.notes
    }

    private func open(_ url: URL?) {
        flush()
        selected = url
        if let note = notes.first(where: { $0.url == url }) { folder = note.folder }
        text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private func scheduleSave(_ value: String) {
        guard let url = selected else { return }
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? value.write(to: url, atomically: true, encoding: .utf8)
            await reload()
        }
    }

    /// Writes a pending edit now, before switching notes.
    private func flush() {
        guard let url = selected, saving != nil else { return }
        saving?.cancel()
        try? text.write(to: url, atomically: true, encoding: .utf8)
        saving = nil
    }

    private func createNote(in name: String) {
        folder = name
        collapsed.remove(name)
        flush()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = NotesStorage.root.appending(path: folder).appending(path: "\(stamp).md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "New note\n\n".write(to: url, atomically: true, encoding: .utf8)
        Task { await reload(); open(url) }
    }

    private func createFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        newFolder = ""
        guard !name.isEmpty else { return }
        try? FileManager.default.createDirectory(at: NotesStorage.root.appending(path: name), withIntermediateDirectories: true)
        folder = name
        Task { await reload() }
    }

    private func trash(_ note: NoteFile) {
        if selected == note.url { selected = nil; text = "" }
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        Task { await reload() }
    }
}

// MARK: Artifacts

private struct ArtifactsBrowser: View {
    @ObservedObject var client: PilotClient
    @PageState("notes.artifacts") private var artifacts: [ArtifactSummary] = []
    @PageState("notes.artifactSearch") private var search = ""
    @PageState("notes.artifactSelected") private var selected: ArtifactSummary? = nil

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Search artifacts", text: $search).textFieldStyle(.roundedBorder).padding(8)
                List(selection: Binding(get: { selected?.id }, set: { id in selected = artifacts.first { $0.id == id } })) {
                    ForEach(artifacts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }, id: \.id) { artifact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artifact.title).font(.pilot(.body, weight: .semibold)).lineLimit(1)
                            Text([client.project(artifact.projectId)?.name, client.session(artifact.sessionId)?.title,
                                  RelativeDate.ago(artifact.updatedAt)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .tag(artifact.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            .background(Theme.sidebar)

            Group {
                if let selected {
                    InlineArtifactViewer(
                        reference: ArtifactReference(id: selected.id, sessionId: selected.sessionId, title: selected.title,
                                                     revision: selected.revision),
                        close: { self.selected = nil }
                    )
                    .id(selected.id)
                } else {
                    Text("Select an artifact.").foregroundStyle(Theme.mutedForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
        .task { await load() }
    }

    private func load() async {
        var all: [ArtifactSummary] = []
        for project in client.projects {
            if let list = try? await client.projectArtifacts(project.id) { all += list }
        }
        artifacts = all.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: Files

private struct FilesBrowser: View {
    nonisolated static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pilot/Files")
    @PageState("notes.files") private var files: [URL] = []
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Drop files here to keep them in \(Self.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                    .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(Self.root) }.buttonStyle(.link).font(.pilot(.caption))
            }
            .padding(12)
            List {
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(url.lastPathComponent).font(.pilot(.body)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Move to Trash", role: .destructive) {
                            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            Task { await load() }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.brand, lineWidth: 2).padding(6) }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let destination = Self.root.appending(path: url.lastPathComponent)
                    try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: url, to: destination)
                    Task { @MainActor in await load() }
                }
            }
            return true
        }
        .task { await load() }
    }

    private func load() async {
        files = await Task.detached {
            try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            return ((try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }
}
