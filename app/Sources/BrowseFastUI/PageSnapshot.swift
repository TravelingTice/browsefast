import Foundation
import WebKit

/// What the agent sees of a page: the interactive elements in view, numbered.
struct PageSnapshot: Decodable {
    struct Element: Decodable {
        let id: Int
        let role: String
        let label: String
        let rect: [Int]
        var value: String?
        var states: [String]?
        var inputType: String?
        var href: String?
        var via: String?
        var target: String?
        var options: [String]?
    }

    let url: String
    let title: String
    let viewport: [Int]
    let scroll: [Int]
    let elements: [Element]
    let text: String
    let captcha: Bool
    let offscreenAbove: Int
    let offscreenBelow: Int
    let ms: Int

    static let script = WKUserScript(
        source: try! String(contentsOf: Bundle.module.url(forResource: "elements", withExtension: "js")!, encoding: .utf8),
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    @MainActor
    static func capture(from webView: WKWebView, all: Bool = false) async throws -> PageSnapshot {
        let json = try await webView.js("window.__browsefast.snapshot({ all: \(all) })") as? String ?? ""
        return try JSONDecoder().decode(PageSnapshot.self, from: Data(json.utf8))
    }

    /// The compact list handed to Jev, e.g. `[3] textbox "Search" value="flights" focused`.
    var elementList: String {
        var lines = elements.map { e -> String in
            var line = "[\(e.id)] \(e.role)"
            if let t = e.inputType { line += "(\(t))" }
            line += " \"\(e.label)\""
            if let v = e.value { line += " value=\"\(v)\"" }
            if let o = e.options, !o.isEmpty { line += " options=[\(o.map { "\"\($0)\"" }.joined(separator: ", "))]" }
            if let h = e.href { line += " → " + (e.via.map { "\($0) " } ?? "") + h }
            if let s = e.states, !s.isEmpty { line += " " + s.joined(separator: " ") }
            return line
        }
        if offscreenAbove > 0 { lines.insert("(\(offscreenAbove) more elements above, scroll up to see them)", at: 0) }
        if offscreenBelow > 0 { lines.append("(\(offscreenBelow) more elements below, scroll down to see them)") }
        return lines.joined(separator: "\n")
    }

    var summary: String {
        "\(elements.count) elements in view, \(offscreenAbove) above, \(offscreenBelow) below · scroll \(scroll[0])/\(scroll[1]) · viewport \(viewport[0])×\(viewport[1]) · \(ms) ms"
    }
}
