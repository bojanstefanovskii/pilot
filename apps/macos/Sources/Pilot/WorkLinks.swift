import PilotCore
import SwiftUI

/// A chat's links out, side by side like its Linear badge: the GitHub pull request and its preview deployment.
struct WorkLinks: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 6) {
            if let pr = session.latestPullRequest { PullRequestLink(pullRequest: pr) }
            PreviewLink(urls: session.previewURLs)
        }
    }
}

/// Opens the PR's preview deployment. With several (app, API…), the badge opens the first and a menu lists them all.
struct PreviewLink: View {
    let urls: [URL]

    var body: some View {
        if let first = urls.first {
            Group {
                if urls.count > 1 {
                    Menu {
                        ForEach(urls, id: \.self) { url in
                            Button(url.host() ?? url.absoluteString) { BrowserLinkOpener.shared.open(url) }
                        }
                    } label: { label } primaryAction: {
                        BrowserLinkOpener.shared.open(first)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                } else {
                    Button { BrowserLinkOpener.shared.open(first) } label: { label }
                        .buttonStyle(.plain)
                }
            }
            .fixedSize()
            .help("Open preview: \(first.host() ?? first.absoluteString)")
            .accessibilityLabel("Open preview deployment")
            .contextMenu {
                ForEach(urls, id: \.self) { url in
                    Button("Copy \(url.host() ?? "link")") { MessageCopyButton.copy(url.absoluteString) }
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            PilotSymbol(PilotIcon.openExternal)
            Text("Preview")
        }
        .font(.pilot(.small, weight: .medium))
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.muted))
        .contentShape(Rectangle())
    }
}
