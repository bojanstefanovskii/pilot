import AppKit
import PilotCore
import SwiftUI

extension Error {
    /// A superseded load (a `.task(id:)` restarted, a view left), never something to show the user.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// The result of one read-only query from the Database page.
struct DatabaseQueryResult: Decodable, Sendable {
    let columns: [String]
    let rows: [[String: JSONValue]]
    let rowCount: Int?
    let truncated: Bool
}

/// A database the user can browse. The URL stays in pilotd.
struct DatabaseConnection: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let detail: String

    var tint: Color {
        switch kind {
        case "production": Theme.destructive
        case "local": Theme.success
        default: Theme.warning
        }
    }
}

private struct DatabaseConnections: Decodable, Sendable { let connections: [DatabaseConnection] }
private struct DatabaseQueryBody: Encodable, Sendable { let connection: String; let sql: String; let maxRows: Int }

private struct DatabaseTable: Hashable {
    let schema: String
    let name: String
    var qualified: String { "\"\(schema)\".\"\(name)\"" }
}

/// A TablePlus-like browser: one-click connections (Prod reader, Local, each worktree's database) on top, tables on
/// the left, the SQL editor above the results. Everything runs in a READ ONLY transaction, at most 1,000 rows.
struct DatabasePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: PilotClient
    @PageState("database.projectId") private var projectId: String? = nil
    @PageState("database.connections") private var connections: [DatabaseConnection] = []
    @PageState("database.connection") private var connection: DatabaseConnection? = nil
    @PageState("database.tables") private var tables: [DatabaseTable] = []
    @PageState("database.tableFilter") private var tableFilter = ""
    @PageState("database.selectedTable") private var selectedTable: DatabaseTable? = nil
    @PageState("database.showStructure") private var showStructure = false
    @PageState("database.sql") private var sql = ""
    @PageState("database.result") private var result: DatabaseQueryResult? = nil
    @PageState("database.elapsed") private var elapsed: Double? = nil
    /// The project and connection whose connections and tables are loaded, so coming back does not reload them.
    @PageState("database.loadedProjectId") private var loadedProjectId: String? = nil
    @PageState("database.tablesConnectionId") private var tablesConnectionId: String? = nil
    @State private var running = false
    @State private var error: String?

    private static let tablesSQL = """
        select table_schema, table_name from information_schema.tables
        where table_schema not in ('pg_catalog', 'information_schema') order by table_schema = 'public' desc, 1, 2
        """

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if connection?.kind == "production" {
                Text("PRODUCTION · read-only")
                    .font(.pilot(.caption, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Theme.destructive)
            }
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                VSplitView {
                    editor
                        .frame(minHeight: 110, idealHeight: 170)
                    results
                        .frame(minHeight: 160)
                }
                .frame(minWidth: 400)
            }
        }
        .background(Theme.background)
        .task(id: projectId) {
            if projectId == nil { projectId = model.selectedProjectId ?? client.projects.first?.id; return }
            guard loadedProjectId != projectId || connections.isEmpty else { return }
            await loadConnections()
            loadedProjectId = projectId
        }
        .task(id: connection) {
            guard tablesConnectionId != connection?.id || tables.isEmpty else { return }
            await loadTables()
        }
    }

    // MARK: Connections

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Picker("Project", selection: $projectId) {
                ForEach(client.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
            Divider().frame(height: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(connections) { item in
                        Button { connect(item) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(item.tint).frame(width: 7, height: 7)
                                Text(item.label).font(.pilot(.label, weight: connection == item ? .semibold : .regular))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(connection == item ? Theme.tray : Color.clear))
                            .overlay(Capsule().stroke(connection == item ? item.tint.opacity(0.6) : Theme.border))
                        }
                        .buttonStyle(.plain)
                        .help("\(item.detail) · read-only")
                    }
                }
            }
            Spacer(minLength: 0)
            if let connection {
                Text(connection.detail).font(.pilot(.caption, design: .monospaced)).foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { HairlineDivider() }
    }

    // MARK: Tables

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search tables", text: $tableFilter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if connections.isEmpty, error == nil {
                Text("No database found. Pilot reads *DATABASE* URLs from the project's .env and apps/api/.env, and Settings → Databases.")
                    .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                    .padding(10)
            }
            List(selection: Binding(get: { selectedTable }, set: { if let table = $0 { open(table) } })) {
                ForEach(groupedTables, id: \.schema) { group in
                    Section(group.schema) {
                        ForEach(group.tables, id: \.self) { table in
                            Label(table.name, systemImage: "tablecells")
                                .font(.pilot(.label))
                                .lineLimit(1)
                                .tag(table)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Theme.sidebar)
    }

    private var groupedTables: [(schema: String, tables: [DatabaseTable])] {
        let filtered = tableFilter.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(tableFilter) }
        var order: [String] = []
        var bySchema: [String: [DatabaseTable]] = [:]
        for table in filtered {
            if bySchema[table.schema] == nil { order.append(table.schema) }
            bySchema[table.schema, default: []].append(table)
        }
        return order.map { ($0, bySchema[$0]!) }
    }

    // MARK: Editor and results

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { run(sql) } label: { Label(running ? "Running…" : "Run", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running || connection == nil || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("⌘↩").font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            TextEditor(text: $sql)
                .font(.pilot(.label, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.code)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if let selectedTable {
                HStack {
                    Picker("", selection: $showStructure) {
                        Text("Data").tag(false)
                        Text("Structure").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: showStructure) { _, _ in open(selectedTable) }
                    Text(selectedTable.name).font(.pilot(.label, design: .monospaced)).foregroundStyle(Theme.mutedForeground)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if let error {
                ScrollView {
                    Text(error).font(.pilot(.label, design: .monospaced)).foregroundStyle(Theme.destructive)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            } else if let result {
                ResultGrid(result: result)
            } else {
                Text(connection == nil ? "Pick a connection above." : "Pick a table, or write a query and press ⌘↩.")
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let result { Text(summary(result)) }
                Spacer()
                if running { ProgressView().controlSize(.mini) }
            }
            .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(alignment: .top) { HairlineDivider() }
        }
    }

    private func summary(_ result: DatabaseQueryResult) -> String {
        var parts = ["\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")"]
        if result.truncated { parts.append("truncated at the row or size limit") }
        if let elapsed { parts.append(String(format: "%.0f ms", elapsed * 1000)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func request<Response: Decodable>(_ body: DatabaseQueryBody?) async throws -> Response {
        guard let host = model.localHost, let projectId else { throw ClientError("pilotd is not connected") }
        return try await model.hosts.githubRequest(on: host, path: "api/projects/\(projectId)/databases/query",
                                                   body: body, method: body == nil ? "GET" : "POST")
    }

    private static func rememberedKey(_ projectId: String) -> String { "database.connection.\(projectId)" }

    private func loadConnections() async {
        connections = []
        connection = nil
        tables = []
        result = nil
        error = nil
        selectedTable = nil
        do {
            let list: DatabaseConnections = try await request(nil)
            connections = list.connections
            let remembered = projectId.flatMap { UserDefaults.standard.string(forKey: Self.rememberedKey($0)) }
            connection = list.connections.first { $0.id == remembered }
                ?? list.connections.first { $0.kind == "local" } ?? list.connections.first
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }

    private func connect(_ item: DatabaseConnection) {
        guard item != connection else { return }
        connection = item
        selectedTable = nil
        result = nil
        error = nil
        if let projectId { UserDefaults.standard.set(item.id, forKey: Self.rememberedKey(projectId)) }
    }

    private func loadTables() async {
        tables = []
        guard let connection else { return }
        do {
            let list: DatabaseQueryResult = try await request(DatabaseQueryBody(connection: connection.id, sql: Self.tablesSQL, maxRows: 1000))
            tables = list.rows.compactMap { row in
                guard let schema = row["table_schema"]?.string, let name = row["table_name"]?.string else { return nil }
                return DatabaseTable(schema: schema, name: name)
            }
            tablesConnectionId = connection.id
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }

    private func open(_ table: DatabaseTable) {
        selectedTable = table
        let query = showStructure
            ? """
              select column_name, data_type, is_nullable, column_default from information_schema.columns
              where table_schema = '\(table.schema.replacingOccurrences(of: "'", with: "''"))'
                and table_name = '\(table.name.replacingOccurrences(of: "'", with: "''"))' order by ordinal_position
              """
            : "select * from \(table.qualified) limit 200"
        if !showStructure { sql = query }
        run(query)
    }

    private func run(_ query: String) {
        guard let connection else { return }
        running = true
        error = nil
        let started = Date()
        Task {
            defer { running = false }
            do {
                result = try await request(DatabaseQueryBody(connection: connection.id, sql: query, maxRows: 1000))
                elapsed = Date().timeIntervalSince(started)
            } catch { if !error.isCancellation { self.error = error.localizedDescription; result = nil } }
        }
    }
}

/// Rows as a scrollable grid with a sticky-looking header row. Cells are selectable text.
private struct ResultGrid: View {
    let result: DatabaseQueryResult
    private let width: CGFloat = 180

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(result.columns, id: \.self) { column in
                                cell(Self.display(row[column]), muted: row[column] == nil || row[column] == .null)
                            }
                        }
                        .background(index.isMultiple(of: 2) ? Color.clear : Theme.tray)
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(result.columns, id: \.self) { column in
                            Text(column).font(.pilot(.caption, weight: .semibold))
                                .frame(width: width, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 5)
                        }
                    }
                    .background(Theme.card)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.border))
    }

    private func cell(_ text: String, muted: Bool) -> some View {
        Text(text)
            .font(.pilot(.caption, design: .monospaced))
            .foregroundStyle(muted ? Theme.faintForeground : Theme.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .textSelection(.enabled)
            .help(text)
    }

    static func display(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return "NULL"
        case let .string(text)?: return text
        case let .bool(flag)?: return flag ? "true" : "false"
        case let .number(number)?:
            return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case let value?:
            let data = try? JSONEncoder().encode(value)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}
