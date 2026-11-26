import PilotCore
import SwiftUI

/// Colored line diff in the code font. Long lines scroll horizontally rather than wrap.
struct DiffView: View {
    let file: FileDiff
    var showNumbers = true
    var maxLines = 600
    /// Set to let the user comment on a line; the comment goes to the chat's agent.
    var onComment: ((DiffLine, String) async throws -> Void)? = nil
    @Environment(\.pilotFonts) private var fonts
    @State private var commenting: Int?
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let lines = Array(file.lines.prefix(maxLines))
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    row(line)
                        .contextMenu {
                            if onComment != nil, line.newNumber != nil || line.oldNumber != nil {
                                Button("Comment on This Line…") { draft = ""; error = nil; commenting = index }
                            }
                        }
                        .popover(isPresented: Binding(get: { commenting == index }, set: { if !$0 { commenting = nil } }),
                                 arrowEdge: .bottom) {
                            commentEditor(line)
                        }
                }
                if file.lines.count > maxLines {
                    Text("… \(file.lines.count - maxLines) more lines")
                        .font(fonts.monoSmall)
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
            .frame(minWidth: 0, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private func commentEditor(_ line: DiffLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(file.path):\(line.newNumber ?? line.oldNumber ?? 0)")
                .font(fonts.monoSmall).foregroundStyle(Theme.mutedForeground)
            TextField("What should change here?", text: $draft, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            if let error { Text(error).font(.pilot(.caption)).foregroundStyle(Theme.destructive) }
            HStack {
                Spacer()
                Button("Cancel") { commenting = nil }
                Button(sending ? "Sending…" : "Send to Agent") {
                    guard let onComment else { return }
                    sending = true
                    Task {
                        defer { sending = false }
                        do {
                            try await onComment(line, draft)
                            commenting = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    /// The message an inline comment sends: where, the line as it reads now, and the request.
    static func commentMessage(path: String, line: DiffLine, comment: String) -> String {
        let number = line.newNumber ?? line.oldNumber ?? 0
        let side = line.newNumber == nil ? " (removed line)" : ""
        return "Review comment on \(path):\(number)\(side):\n> \(line.text)\n\n\(comment.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    @ViewBuilder private func row(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            if showNumbers {
                number(line.oldNumber)
                number(line.newNumber)
            }
            Text(marker(line.kind))
                .frame(width: 16, alignment: .center)
                .foregroundStyle(color(line.kind))
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Theme.mutedForeground : Theme.foreground)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
        .font(fonts.monoSmall)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
            .foregroundStyle(Theme.faintForeground)
    }

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private func color(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: Theme.success
        case .deletion: Theme.destructive
        default: Theme.faintForeground
        }
    }

    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: Theme.success.opacity(0.10)
        case .deletion: Theme.destructive.opacity(0.09)
        case .hunk: Theme.muted
        default: .clear
        }
    }
}

/// "+12 −3" in green and red.
struct DiffStat: View {
    let additions: Int
    let deletions: Int
    var showZero = false
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            if showZero || additions > 0 { Text("+\(additions)").foregroundStyle(Theme.success) }
            if showZero || deletions > 0 { Text("−\(deletions)").foregroundStyle(Theme.destructive) }
        }
        .font(.system(size: fontSize, weight: .medium).monospacedDigit())
    }
}
