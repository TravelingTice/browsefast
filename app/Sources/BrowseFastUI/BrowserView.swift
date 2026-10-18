import SwiftUI
import WebKit

// ponytail: plain WKWebView wrapper; SwiftUI's own WebView would hide the WKWebView the agent drives with scripts.
/// Keeps every tab's web view in the window, stacked, with the focused one visible on top. Background tabs stay
/// attached so their agents keep loading and rendering pages; only the focused tab receives clicks.
struct BrowserView: NSViewRepresentable {
    let tabs: [BrowserTab]
    let activeID: UUID?

    final class Container: NSView {
        weak var active: NSView?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let active, let superview else { return nil }
            return active.hitTest(convert(point, from: superview))
        }
    }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        let wanted = Set(tabs.map { ObjectIdentifier($0.webView) })
        for view in container.subviews where !wanted.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for tab in tabs {
            let webView = tab.webView
            if webView.superview !== container {
                webView.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(webView)
                NSLayoutConstraint.activate([
                    webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    webView.topAnchor.constraint(equalTo: container.topAnchor),
                    webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            // alphaValue rather than isHidden: hidden web views get throttled by WebKit.
            webView.alphaValue = tab.id == activeID ? 1 : 0
            if tab.id == activeID { container.active = webView }
        }
    }
}

/// Tab pills in the title bar strip: favicon, title and what the tab's agent is doing.
/// A tab whose agent is waiting for your answer pulses.
struct TabBar: View {
    let browser: Browser
    let run: TaskRun

    var body: some View {
        HStack(spacing: 6) {
            ForEach(browser.tabs) { tab in
                TabPill(tab: tab, agent: run.agent(for: tab), isActive: tab.id == browser.activeID,
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
    let agent: TabAgent?
    let isActive: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    private var waiting: Bool { agent?.isWaiting == true }

    var body: some View {
        HStack(spacing: 7) {
            favicon
            Text(tab.title)
                .font(Theme.figtree(12.5, weight: isActive ? 600 : 500))
                .foregroundStyle(isActive ? .white : Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            status
            if canClose && hovering {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Capsule().fill(isActive ? Theme.surfaceHigh : Color.white.opacity(hovering ? 0.06 : 0.025)))
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: waiting ? 1.5 : 1))
        .shadow(color: waiting ? Theme.violetLight.opacity(pulse ? 0.8 : 0.15) : .clear, radius: pulse ? 12 : 4)
        .scaleEffect(waiting && pulse ? 1.04 : 1)
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(waiting ? "\(tab.title): waiting for your answer" : tab.title)
        .onChange(of: waiting, initial: true) { _, isWaiting in
            if isWaiting {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    private var borderColor: Color {
        if waiting { return Theme.violetLight.opacity(pulse ? 0.95 : 0.5) }
        return isActive ? Theme.violetLight.opacity(0.4) : Theme.line
    }

    @ViewBuilder private var favicon: some View {
        if let image = tab.favicon {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var status: some View {
        switch agent?.status {
        case .working? where waiting:
            Image(systemName: "questionmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.violetLight)
        case .working?:
            ProgressView().controlSize(.mini).tint(Theme.violetLight)
        case .done?:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.violetLight.opacity(0.8))
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger.opacity(0.85))
        case nil:
            Circle().fill(tab.isLoading ? Theme.violetLight : Theme.muted.opacity(0.4)).frame(width: 6, height: 6)
        }
    }
}
