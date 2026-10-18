import Foundation
import Observation
import WebKit

@MainActor @Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let webView: WKWebView
    var title = "New tab"
    var isLoading = false
    var favicon: NSImage?
    /// The tab whose link opened this one, so its agent can follow it here.
    let openerID: UUID?
    @ObservationIgnored fileprivate var delegate: TabDelegate?
    @ObservationIgnored fileprivate var titleObservation: NSKeyValueObservation?

    init(webView: WKWebView, openerID: UUID? = nil) {
        self.webView = webView
        self.openerID = openerID
    }
}

/// The open tabs. Links that open a new window become a new, focused tab.
@MainActor @Observable
final class Browser {
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeID: UUID?

    var active: BrowserTab? { tabs.first { $0.id == activeID } }

    @ObservationIgnored private let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(PageSnapshot.script)
        return config
    }()

    /// Pass the configuration WebKit hands over for a popup; it must be used for that web view.
    @discardableResult
    func newTab(configuration: WKWebViewConfiguration? = nil, openedBy opener: BrowserTab? = nil, focus: Bool = true) -> BrowserTab {
        let tab = BrowserTab(webView: WKWebView(frame: .zero, configuration: configuration ?? self.configuration), openerID: opener?.id)
        let delegate = TabDelegate(tab: tab, browser: self)
        tab.delegate = delegate
        tab.webView.navigationDelegate = delegate
        tab.webView.uiDelegate = delegate
        tab.titleObservation = tab.webView.observe(\.title) { webView, _ in
            Task { @MainActor in
                if let title = webView.title, !title.isEmpty { tab.title = title }
            }
        }
        tabs.append(tab)
        if focus || activeID == nil { activeID = tab.id }
        Log.write("browser", "Opened tab \(tabs.count)\(focus ? "" : " in the background")")
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tab.id != activeID else { return }
        activeID = tab.id
        Log.write("browser", "Switched to tab \(number(of: tab)): \(tab.title)")
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        Log.write("browser", "Closed tab \(index + 1): \(tab.title)")
        tabs.remove(at: index)
        if activeID == tab.id { activeID = tabs[safe: index]?.id ?? tabs.last?.id }
    }

    func number(of tab: BrowserTab) -> Int { (tabs.firstIndex { $0.id == tab.id } ?? 0) + 1 }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: BrowserTab?
    private weak var browser: Browser?

    @MainActor init(tab: BrowserTab, browser: Browser) {
        self.tab = tab
        self.browser = browser
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in tab?.isLoading = true }
        Log.write("browser", "Navigation started: \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            tab?.isLoading = false
            await loadFavicon(for: webView)
        }
        Log.write("browser", "Page loaded: \(webView.title ?? "") — \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in tab?.isLoading = false }
        Log.write("browser", "Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in tab?.isLoading = false }
        Log.write("browser", "Page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        Log.write("browser", "Link opens in a new tab: \(navigationAction.request.url?.absoluteString ?? "?")")
        return MainActor.assumeIsolated {
            // Only take focus when the link was in the tab you're looking at; agents work in background tabs.
            browser?.newTab(configuration: configuration, openedBy: tab, focus: tab?.id == browser?.activeID).webView
        }
    }

    @MainActor private func loadFavicon(for webView: WKWebView) async {
        let js = "(document.querySelector('link[rel~=\"icon\"][href$=\".png\"], link[rel~=\"icon\"], link[rel=\"apple-touch-icon\"]') || {}).href || (location.origin + '/favicon.ico')"
        guard let href = try? await webView.evaluateJavaScript(js) as? String, let url = URL(string: href),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data), image.isValid else { return }
        tab?.favicon = image
    }

    func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let tab, let browser { browser.close(tab) }
        }
    }
}
