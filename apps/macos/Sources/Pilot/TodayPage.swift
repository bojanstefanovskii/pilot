import AppKit
import PilotCore
import SwiftUI

/// The Today page: what Today Desk routines decided for the day. The user ticks items done, starts a quick win in a
/// new chat, or sets up the three routines (plan, midday refresh, wrap) that keep it current.
struct TodayView: View {
    static let windowID = "today"
    @ObservedObject var model: AppModel
    @State private var page: TodayPage?
    @State private var error: String?
    @State private var settingUp = false
    @State private var setupDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
                if let page {
                    if page.isEmpty {
                        empty
                    } else {
                        if let summary = page.summary { Text(summary).font(.pilot(.body)).foregroundStyle(Theme.foreground) }
                        section("Priorities", page.priorities, keyPath: \.priorities)
                        section("Reviews", page.reviews, keyPath: \.reviews)
                        section("Quick wins", page.quickWins, keyPath: \.quickWins)
                        section("Waiting on others", page.waiting, keyPath: \.waiting)
                        if let wrap = page.wrap {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionLabel(title: "Wrap")
                                Text(wrap).font(.pilot(.body)).textSelection(.enabled)
                            }
                        }
                    }
                    if !page.lessons.isEmpty {
                        DisclosureGroup("Lessons (\(page.lessons.count))") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(page.lessons, id: \.self) { Text("· \($0)").font(.pilot(.label)) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                        .font(.pilot(.label))
                        .foregroundStyle(Theme.mutedForeground)
                    }
                } else if error == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(24)
            .frame(maxWidth: Theme.column, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .frame(minWidth: 520, minHeight: 480)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.pilot(.title, weight: .semibold))
                if let page, page.updatedAt > 0 {
                    Text("Updated \(Date(timeIntervalSince1970: page.updatedAt / 1000).formatted(date: .omitted, time: .shortened))")
                        .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                }
            }
            Spacer()
            Button { Task { await load() } } label: { PilotSymbol(PilotIcon.update, context: .toolbar) }
                .rowIconButtonStyle()
                .help("Reload")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing planned yet today.").foregroundStyle(Theme.foreground)
            Text("Three routines keep this page current on weekdays: plan at 8:30, refresh at 13:00, wrap at 18:00. They run the today-plan and today-wrap skills in read-only chats.")
                .font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(setupDone ? "Routines created" : settingUp ? "Creating…" : "Set up routines") { setUpRoutines() }
                    .disabled(settingUp || setupDone)
                Button("Plan now") { planNow() }
                    .help("Start the plan routine once, now.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TodayItem], keyPath: WritableKeyPath<TodayPage, [TodayItem]>) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(title: title, count: items.count)
                    .padding(.bottom, 6)
                ForEach(items) { item in
                    TodayRow(item: item, toggle: { toggle(item, keyPath) }, start: item.prompt == nil ? nil : { start(item) })
                }
            }
        }
    }

    private func load() async {
        do {
            let next = try await model.client.today()
            if page != next { page = next }
            error = nil
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }

    private func toggle(_ item: TodayItem, _ keyPath: WritableKeyPath<TodayPage, [TodayItem]>) {
        guard let date = page?.date else { return }
        let done = item.done != true
        if let index = page?[keyPath: keyPath].firstIndex(where: { $0.id == item.id }) {
            page?[keyPath: keyPath][index].done = done
        }
        Task {
            do { _ = try await model.client.patchTodayItem(item.id, date: date, TodayItemPatch(done: done)) }
            catch { self.error = error.localizedDescription; await load() }
        }
    }

    /// Opens the main window's composer with the item's prompt, so the user picks the project and kind.
    private func start(_ item: TodayItem) {
        guard let prompt = item.prompt else { return }
        let message = [prompt, item.url].compactMap { $0 }.joined(separator: "\n\n")
        _ = model.newSession(in: nil, message: message)
    }

    private static let routines: [(title: String, cron: String, message: String)] = [
        ("Today · plan", "30 8 * * 1-5", "Run the today-plan skill: decide my day and write it with today_write."),
        ("Today · midday", "0 13 * * 1-5", "Run the today-plan skill for the midday refresh."),
        ("Today · wrap", "0 18 * * 1-5", "Run the today-wrap skill: close my day with today_write."),
    ]

    private static func spawn(_ message: String, title: String) -> SpawnRequest {
        var request = SpawnRequest(cwd: FileManager.default.homeDirectoryForCurrentUser.path, message: message,
                                   title: title, mode: .ask)
        request.todayDesk = true
        return request
    }

    private func setUpRoutines() {
        settingUp = true
        error = nil
        Task {
            defer { settingUp = false }
            do {
                for routine in Self.routines {
                    _ = try await model.client.createSchedule(ScheduleRequest(
                        title: routine.title, cron: routine.cron,
                        target: .chat(Self.spawn(routine.message, title: routine.title), trackedItemId: nil)
                    ))
                }
                setupDone = true
            } catch { if !error.isCancellation { self.error = error.localizedDescription } }
        }
    }

    private func planNow() {
        error = nil
        Task {
            do { _ = try await model.client.spawn(Self.spawn(Self.routines[0].message, title: "Today · plan")) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct TodayRow: View {
    let item: TodayItem
    let toggle: () -> Void
    let start: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HairlineDivider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: toggle) {
                    PilotSymbol(item.done == true ? PilotIcon.complete : PilotIcon.todo)
                        .foregroundStyle(item.done == true ? Theme.mutedForeground : Theme.foreground)
                }
                .buttonStyle(.plain)
                .help(item.done == true ? "Mark not done" : "Mark done")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.pilot(.body, weight: .medium))
                        .strikethrough(item.done == true)
                        .foregroundStyle(item.done == true ? Theme.mutedForeground : Theme.foreground)
                    if let why = item.why {
                        Text(why).font(.pilot(.label)).foregroundStyle(Theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if let source = item.source {
                            if let link = item.url.flatMap(URL.init(string:)) {
                                Link(source, destination: link).font(.pilot(.caption))
                            } else {
                                Text(source).font(.pilot(.caption)).foregroundStyle(Theme.mutedForeground)
                            }
                        }
                        if let effort = item.effort {
                            Text(effort).font(.pilot(.caption)).foregroundStyle(Theme.faintForeground)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let start, item.done != true {
                    Button("Start", action: start)
                        .controlSize(.small)
                        .opacity(hovered ? 1 : 0.6)
                        .help("Open a new chat with this item's prompt")
                }
            }
            .padding(.vertical, 9)
        }
        .onHover { hovered = $0 }
    }
}
