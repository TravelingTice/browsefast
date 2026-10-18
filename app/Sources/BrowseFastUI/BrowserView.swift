import SwiftUI
import WebKit

// ponytail: plain WKWebView wrapper; SwiftUI's own WebView would hide the WKWebView we'll need for scripts and native input events.
struct BrowserView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(PageSnapshot.script)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        Log.write("browser", "Loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Log.write("browser", "Navigation started: \(webView.url?.absoluteString ?? "?")")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.write("browser", "Page loaded: \(webView.title ?? "") — \(webView.url?.absoluteString ?? "?")")
            Task { @MainActor in
                do {
                    let page = try await PageSnapshot.capture(from: webView)
                    Log.write("page", "Snapshot of \(page.url): \(page.summary)", details: page.elementList)
                } catch {
                    Log.write("page", "Snapshot failed: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.write("browser", "Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.write("browser", "Page failed to load: \(error.localizedDescription)")
        }
    }
}
