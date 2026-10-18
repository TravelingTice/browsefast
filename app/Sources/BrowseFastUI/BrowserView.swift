import SwiftUI
import WebKit

// ponytail: plain WKWebView wrapper; SwiftUI's own WebView would hide the WKWebView the agent drives with scripts.
/// Shows the focused tab's web view, swapping it in when the focused tab changes.
struct BrowserView: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView, container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Small tab pills in the title bar strip. Click to focus a tab, hover to close it.
struct TabBar: View {
    let browser: Browser

    var body: some View {
        HStack(spacing: 6) {
            ForEach(browser.tabs) { tab in
                TabPill(tab: tab, isActive: tab.id == browser.activeID,
                        canClose: browser.tabs.count > 1,
                        select: { browser.select(tab) },
                        close: { browser.close(tab) })
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.2), value: browser.tabs.map(\.id))
    }
}

private struct TabPill: View {
    let tab: BrowserTab
    let isActive: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tab.isLoading ? Theme.violetLight : (isActive ? Theme.violetLight.opacity(0.5) : Theme.muted.opacity(0.4)))
                .frame(width: 6, height: 6)
            Text(tab.title)
                .font(Theme.figtree(12, weight: isActive ? 600 : 500))
                .foregroundStyle(isActive ? .white : Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if canClose && hovering {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(isActive ? Theme.surfaceHigh : Color.white.opacity(hovering ? 0.05 : 0)))
        .overlay(Capsule().strokeBorder(isActive ? Theme.violetLight.opacity(0.4) : Theme.line, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}
