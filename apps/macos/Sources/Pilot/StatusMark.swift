import PilotCore
import SwiftUI

// MARK: - Status mark

/// A row's `SessionSignal` as one still mark at the trailing edge of its first line. Each state has its own shape as
/// well as its tint, so color is never the only signal: working is a ring, needs you a filled dot, failed a filled
/// square, ready to merge a filled diamond. Quiet rows draw nothing. Nothing animates, so marks cost no frames
/// while many chats work at once.
///
/// Use `.statusMark(_:)` on a row's content. Rows wearing a mark draw no hover fill (`HoverRow` reads
/// `rowHasStatusMark`): selection stays the only row fill. A working chat whose agent waits only on background jobs
/// passes `background: true` and gets a fainter ring. The command palette passes `monochrome: true`: only states
/// that need the user keep their colour.
extension View {
    func statusMark(_ signal: SessionSignal?, background: Bool = false, monochrome: Bool = false) -> some View {
        modifier(StatusMarkModifier(signal: signal, background: background && signal == .working, monochrome: monochrome))
    }
}

extension EnvironmentValues {
    /// True inside a view wearing `statusMark`. Such rows draw no hover fill.
    var rowHasStatusMark: Bool {
        get { self[RowHasStatusMarkKey.self] }
        set { self[RowHasStatusMarkKey.self] = newValue }
    }
}

private struct RowHasStatusMarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension SessionSignal {
    /// Tint of the status mark. Attention states use the shared signal colors.
    var tint: Color {
        switch self {
        case .working: Theme.working
        case .failed: Theme.destructive
        case .needsYou: Theme.warning
        case .readyToMerge: Theme.success
        }
    }
}

/// The mark alone, for places that show a state without a row (cards, headers).
struct StatusMarkShape: View {
    let signal: SessionSignal
    var background = false
    var monochrome = false
    static let size: CGFloat = 7

    private var color: Color {
        if monochrome, signal == .working || signal == .readyToMerge { return Theme.mutedForeground }
        return signal.tint.opacity(background ? 0.55 : 1)
    }

    var body: some View {
        Group {
            switch signal {
            case .working: Circle().strokeBorder(color, lineWidth: 1.5)
            case .needsYou: Circle().fill(color)
            case .failed: RoundedRectangle(cornerRadius: 1.5).fill(color)
            case .readyToMerge: Rectangle().fill(color).rotationEffect(.degrees(45)).scaleEffect(0.8)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }
}

private struct StatusMarkModifier: ViewModifier {
    let signal: SessionSignal?
    let background: Bool
    let monochrome: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.rowHasStatusMark, true)
            .overlay(alignment: .topTrailing) {
                if let signal {
                    StatusMarkShape(signal: signal, background: background, monochrome: monochrome)
                        .padding(.top, 6)
                        .padding(.trailing, 2)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("Status: \(signal.label)\(background ? " in the background" : "")")
                }
            }
    }
}
