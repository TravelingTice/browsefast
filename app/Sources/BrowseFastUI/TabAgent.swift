import Foundation
import Observation
import WebKit

/// One agent working in its own tab: Jev picks each action (Claude takes over when Jev is unsure), the page
/// script carries it out, and Claude checks what was found. Several can run at once under one TaskRun.
@MainActor @Observable
final class TabAgent: Identifiable {
    enum Status { case working, done, failed }

    let id = UUID()
    let name: String
    private(set) var tab: BrowserTab
    private(set) var status: Status = .working
    private(set) var answer: String?
    private(set) var achieved = false
    let timeline: Timeline
    let questions = QuestionSlot()

    @ObservationIgnored private unowned let coordinator: TaskRun
    @ObservationIgnored private let browser: Browser
    @ObservationIgnored private let task: String
    @ObservationIgnored private let instruction: String
    @ObservationIgnored private let startURL: URL
    @ObservationIgnored private let goals: [Plan.Goal]

    static let maxActions = 25
    static let maxScrollsPerPage = 4
    static let jevConfidenceFloor = 0.5

    private var webView: WKWebView { tab.webView }

    init(name: String, tab: BrowserTab, coordinator: TaskRun, browser: Browser, task: String,
         instruction: String, startURL: URL, goals: [Plan.Goal]) {
        self.name = name
        self.tab = tab
        self.coordinator = coordinator
        self.browser = browser
        self.task = task
        self.instruction = instruction
        self.startURL = startURL
        self.goals = goals
        let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
        timeline = Timeline(logTag: "agent:\(slug.isEmpty ? "tab" : slug)")
    }

    var isWaiting: Bool { questions.question != nil }

    private struct Decision: Decodable { let option: String; let text: String; let reason: String }
    private struct Typed: Decodable { let text: String }
    private struct Verdict: Decodable { let achieved: Bool; let answer: String }
    private struct AskOut: Decodable {
        struct Choice: Decodable { let option: String; let label: String }
        let question: String
        let choices: [Choice]
    }

    private var tag: String { timeline.logTag }

    func run() async {
        let started = Date()
        let claude = ClaudeClient(apiKey: KeyStore.read(.claude) ?? "")
        let jev = JevClient(apiKey: KeyStore.read(.typesafe) ?? "")
        var history: [String] = []
        var decisions: [Decider: Int] = [:]
        let steps = timeline
        Log.write(tag, "Started on \(name): \(instruction)")

        do {
            // 1. Open the start page
            let host = startURL.host() ?? startURL.absoluteString
            let navStep = steps.begin(.claude, "Opening \(host)…")
            webView.load(URLRequest(url: startURL))
            try await settle()
            steps.finish(navStep, "Navigated to \(host)")
            history.append("Navigated to \(host)")

            // 2. Act until done. The plan is context for every decision, not a checklist to tick off.
            var pendingTexts = goals.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let planLines = goals.map(\.goal)
            var actions = 0
            var lastAction = ""
            var repeats = 0
            // Actions already taken in an identical page state (same URL and element list), keyed by what the
            // option does rather than its number. Single-page apps keep one URL, so the URL alone isn't enough.
            var tried: Set<String> = []
            var visits: [String: Int] = [:]
            var scrolls: [String: Int] = [:]
            var backwards: Set<String> = []          // "host|label" of clicks that led back to an earlier page state
            var lastClick: String?
            var lastPage = ""
            var stopReason: String?

            work: while true {
                try Task.checkCancellation()
                if actions >= Self.maxActions {
                    stopReason = "Stopped after \(Self.maxActions) actions without finishing"
                    steps.add(.browseFast, stopReason!, status: .failed)
                    break
                }
                actions += 1
                let goalText = pendingTexts.first ?? ""
                let page = try await snapshot()
                let pageState = "\(page.url)|\(page.elementList.hashValue)"
                if let click = lastClick, visits[pageState, default: 0] > 0 {
                    // That click brought back a page we'd already seen (like a wizard's "Start"): don't use it again.
                    backwards.insert(click)
                    Log.write(tag, "Click '\(click)' led back to an earlier page; not using it again")
                }
                lastClick = nil
                visits[pageState, default: 0] += 1
                if page.url + page.title != lastPage {
                    history.append("Now on: \(page.title.isEmpty ? page.url : page.title) (\(URL(string: page.url)?.host() ?? page.url))")
                    lastPage = page.url + page.title
                }
                if visits[pageState]! >= 5 {
                    stopReason = "Stuck in a loop: the same page kept coming back"
                    steps.add(.browseFast, stopReason!, status: .failed)
                    break work
                }
                if page.captcha {
                    // The agent can't (and shouldn't) solve human checks; hand it to the user in this tab.
                    let checkStep = steps.begin(.browseFast, "This site wants to check you're human")
                    steps.finish(checkStep, "This site wants to check you're human. Solve it in this tab, then continue.")
                    Log.write(tag, "Human check (CAPTCHA) on \(page.url), asking the user")
                    let picked = try await questions.ask(Question(
                        text: "\(self.name) is asking to check you're human. Open its tab, solve the check, then continue.",
                        choices: [.init(option: "continue", label: "I've solved it, continue"), .init(option: "skip", label: "Skip this site")]))
                    if picked.option == "skip" {
                        stopReason = "Skipped: the site asked for a human check"
                        steps.add(.you, "You skipped this site", status: .failed)
                        break work
                    }
                    steps.add(.you, "You solved the human check", status: .done)
                    history.append("The user solved a human check on this site")
                    visits[pageState] = 0
                    actions -= 1
                    try await settle()
                    continue work
                }
                let looping = visits[pageState]! >= 3
                if looping {
                    history.append("Loop warning: this exact page has come back \(visits[pageState]!) times. Choices already made stay made; don't redo them, move forward instead.")
                }
                let onSearchResults = Prompts.isSearchResults(page.url)
                // Scrolling isn't covered by the loop guard (every scroll changes the page), so cap it per page.
                let scrollKey = URL(string: page.url).map { ($0.host() ?? "") + $0.path } ?? page.url
                let mayScroll = scrolls[scrollKey, default: 0] < Self.maxScrollsPerPage
                let options = Prompts.options(for: page, goalText: goalText)
                    .filter { !tried.contains("\(pageState)|\($0.description)") || $0.key.hasPrefix("scroll") || $0.key == "task_done" }
                    .filter { mayScroll || !$0.key.hasPrefix("scroll") }
                    .filter { option in
                        guard let id = Prompts.parse(option.key).id, let e = page.elements.first(where: { $0.id == id }) else { return true }
                        if backwards.contains("\(URL(string: page.url)?.host() ?? "")|\(e.label)") { return false }
                        // On search results, only actual results: links leaving the search engine.
                        return !onSearchResults || option.key.hasPrefix("open_") || !option.key.hasPrefix("click_") || e.via != nil
                            || (e.href.map { !$0.hasPrefix("/") && !$0.contains("google.") } ?? false)
                    }
                    + (onSearchResults || tried.contains("\(pageState)|ask") ? [] : [("ask_user", "Ask the user: the page needs a choice the task doesn't specify (like a service, a person, gender, a date or a time)")])
                let state = Prompts.state(task: contextualTask, plan: planLines, goalText: goalText,
                                          history: history, tabs: "", page: page)

                // Decide: Claude on search results pages (choosing a website is an open judgment call);
                // elsewhere Jev first, and Claude when Jev is unsure, gives up, loops or keeps repeating itself.
                var decider = Decider.jev
                var choice = "stuck"
                var text: String? = goalText.isEmpty ? nil : goalText
                var reason: String?
                let step = steps.begin(onSearchResults ? .claude : .jev, onSearchResults ? "Choosing a search result…" : "Deciding the next step…")

                if onSearchResults {
                    reason = "search results page, Claude picks the website"
                } else {
                    let pick = try await jev.choose(state: state, instructions: Prompts.jevInstructions, options: options)
                    let top = pick.probabilities.prefix(3).map { "\($0.option) \(String(format: "%.2f", $0.p))" }.joined(separator: ", ")
                    Log.write(tag, "Jev chose \(pick.choice) (confidence \(String(format: "%.2f", pick.confidence)), \(pick.ms) ms)",
                              details: "top: \(top)\noptions: \(options.count)")
                    choice = pick.choice
                    let pageKey = "\(page.url)|\(choice)"
                    repeats = pageKey == lastAction ? repeats + 1 : 0
                    lastAction = pageKey
                    reason = looping ? "the same page came back several times (loop)"
                        : choice == "stuck" ? "Jev found no fitting action"
                        : pick.confidence < Self.jevConfidenceFloor ? "Jev was unsure (confidence \(String(format: "%.2f", pick.confidence)))"
                        : repeats >= 2 ? "Jev repeated the same action three times"
                        : nil
                }

                if let reason {
                    if !onSearchResults { steps.update(step, decider: .claude, text: "Thinking about the next step…") }
                    Log.write(tag, "Handing this step to Claude: \(reason)")
                    let schema = Prompts.decisionSchema(keys: options.map(\.key).filter { $0 != "stuck" })
                    let visibleText = (try? await webView.js("window.__browsefast.pageText()") as? String) ?? ""
                    let prompt = (onSearchResults ? Prompts.searchResultsHint + "\n\n" : "") + state
                        + "\n\nPage text (start):\n" + String(visibleText.prefix(4000))
                        + "\n\nOptions:\n" + options.filter { $0.key != "stuck" }
                        .map { "\($0.key): \($0.description)" }.joined(separator: "\n")
                    let decision = try await claude.json(Decision.self, system: Prompts.decider, prompt: prompt, schema: schema)
                    logClaude("Decision", decision)
                    decider = .claude
                    choice = decision.value.option
                    if !decision.value.text.isEmpty { text = decision.value.text }
                    repeats = 0
                }
                decisions[decider, default: 0] += 1
                if let taken = options.first(where: { $0.key == choice }) { tried.insert("\(pageState)|\(taken.description)") }

                // Act
                let (kind, id) = Prompts.parse(choice)
                let element = id.flatMap { id in page.elements.first { $0.id == id } }
                let name = element.map { "'\(Prompts.short($0.label.isEmpty ? $0.role : $0.label))'" } ?? ""

                switch kind {
                case "task_done":
                    steps.finish(step, decider: decider, "Done here")
                    break work

                case "type":
                    guard let element else { steps.fail(step, "Couldn't find the field to type in"); continue work }
                    if text == nil {
                        // The decision was Jev's; writing the text is a separate Claude call, so it gets its own row.
                        steps.finish(step, decider: decider, "Chose the \(name) field to fill in")
                        let writeStep = steps.begin(.claude, "Writing what to type…")
                        let typed = try await claude.json(Typed.self, system: Prompts.writer,
                                                          prompt: "Task: \(contextualTask)\nPlan: \(planLines.joined(separator: "; "))\nWhat happened so far:\n\(history.map { "- \($0)" }.joined(separator: "\n"))\nField: \(element.role) \"\(element.label)\"",
                                                          schema: Prompts.typedSchema)
                        logClaude("Text", typed)
                        decisions[.claude, default: 0] += 1
                        guard !typed.value.text.isEmpty else {
                            steps.fail(writeStep, "Didn't know what to type in \(name)")
                            history.append("Could not decide what to type in \(name)")
                            continue work
                        }
                        text = typed.value.text
                        try await perform(["kind": "type", "id": element.id, "text": typed.value.text], step: writeStep,
                                          success: "Filled in '\(Prompts.short(typed.value.text))' in \(name)", decider: .claude)
                    } else {
                        try await perform(["kind": "type", "id": element.id, "text": text!], step: step,
                                          success: "Filled in '\(Prompts.short(text!))' in \(name)", decider: decider)
                    }
                    history.append("Filled in '\(text ?? "")' in \(name)")
                    if text == pendingTexts.first { pendingTexts.removeFirst() }

                case "open":
                    guard let element, let target = element.target.flatMap(URL.init(string:)) else {
                        steps.fail(step, "Couldn't find that link"); continue work
                    }
                    webView.load(URLRequest(url: target))
                    steps.finish(step, decider: decider, "Opened \(target.host() ?? target.absoluteString)")
                    history.append("Opened \(target.absoluteString)")
                    try await settle()

                case "submit":
                    guard let element else { steps.fail(step, "Couldn't find the field"); continue work }
                    if try await perform(["kind": "submit", "id": element.id], step: step,
                                         success: "Pressed Enter in \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    history.append("Pressed Enter in \(name)")

                case "click":
                    guard let element else { steps.fail(step, "Couldn't find what to click"); continue work }
                    lastClick = "\(URL(string: page.url)?.host() ?? "")|\(element.label)"
                    let before = tab.id
                    if try await perform(["kind": "click", "id": element.id], step: step,
                                         success: "Clicked \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    // A link that opened in a new tab: keep working there.
                    if let opened = browser.tabs.last(where: { $0.openerID == before && $0.id != before }), !adopted.contains(opened.id) {
                        adopted.insert(opened.id)
                        tab = opened
                        steps.setText(step, "Clicked \(name) (opened in a new tab)")
                        history.append("Clicked \(name), which opened in a new tab; continuing there")
                        try await settle()
                    } else {
                        history.append("Clicked \(name)")
                    }

                case "ask_user":
                    // Every option, ignoring the loop guard: the user must be able to pick anything on the page.
                    let clickable = Prompts.options(for: page, goalText: "").filter { $0.key.hasPrefix("click_") }
                    guard !clickable.isEmpty else { steps.fail(step, "Wanted to ask you something, but there was nothing to choose from"); continue work }
                    steps.finish(step, decider: decider, "Needs your input")
                    let askStep = steps.begin(.claude, "Writing a question for you…")
                    let asked = try await claude.json(AskOut.self, system: Prompts.asker,
                                                      prompt: state + "\n\nClickable options:\n" + clickable.map { "\($0.key): \($0.description)" }.joined(separator: "\n"),
                                                      schema: Prompts.askSchema(keys: clickable.map(\.key)))
                    logClaude("Question", asked)
                    decisions[.claude, default: 0] += 1
                    let choices = asked.value.choices.prefix(20).map { Question.Choice(option: $0.option, label: $0.label) }
                    guard !choices.isEmpty else {
                        // Usually the page is still rendering the options (a calendar animating in); look again.
                        steps.remove(step...askStep)
                        tried.insert("\(pageState)|ask")
                        Log.write(tag, "Nothing to ask about here, looking at the page again without asking")
                        try await Task.sleep(for: .seconds(1))
                        continue work
                    }
                    let signature = choices.map(\.label).sorted().joined(separator: "|")
                    if let earlier = coordinator.answers[signature] ?? coordinator.answers[asked.value.question],
                       let again = choices.first(where: { $0.label == earlier }) {
                        // Asked before (here or in another tab) with the same options: reuse the answer.
                        steps.remove(step...askStep)
                        let reuseStep = steps.begin(.you, "Used your earlier choice '\(again.label)'")
                        Log.write(tag, "Reusing earlier answer '\(again.label)' for '\(asked.value.question)'")
                        guard let againID = Prompts.parse(again.option).id else { continue work }
                        if try await perform(["kind": "click", "id": againID], step: reuseStep,
                                             success: "Used your earlier choice '\(again.label)'", decider: .you) == .blocked {
                            stopReason = "blocked"; break work
                        }
                        history.append("Re-applied the user's earlier choice '\(again.label)'. This choice is now made; move on to the next step.")
                        continue work
                    }
                    steps.finish(askStep, "Asked you: \(asked.value.question)")
                    let picked = try await questions.ask(Question(text: asked.value.question, choices: choices))
                    coordinator.remember(question: asked.value.question, signature: signature, answer: picked.label)
                    Log.write(tag, "User answered '\(asked.value.question)' with '\(picked.label)' (\(picked.option))")
                    guard let pickedID = Prompts.parse(picked.option).id else { continue work }
                    let youStep = steps.begin(.you, "You chose '\(picked.label)'")
                    if try await perform(["kind": "click", "id": pickedID], step: youStep,
                                         success: "You chose '\(picked.label)'", decider: .you) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    history.append("Asked the user '\(asked.value.question)', they chose '\(picked.label)' and it was clicked")

                case "scroll_down", "scroll_up":
                    scrolls[scrollKey, default: 0] += 1
                    let up = kind == "scroll_up"
                    try await perform(["kind": "scroll", "direction": up ? "up" : "down"], step: step,
                                      success: up ? "Scrolled up" : "Scrolled down", decider: decider)
                    history.append(up ? "Scrolled up" : "Scrolled down")

                case "go_back":
                    try await perform(["kind": "back"], step: step, success: "Went back to the previous page", decider: decider)
                    history.append("Went back")

                default:
                    steps.fail(step, "Got an unknown action: \(choice)")
                }
            }

            // 3. Check what was found
            try Task.checkCancellation()
            let checkStep = steps.begin(.claude, "Checking what I found…")
            let text = (try? await webView.js("window.__browsefast.pageText()") as? String) ?? ""
            // Page text alone can't tell greyed-out options (like unavailable times) from real ones; the element list can.
            let finalElements = (try? await PageSnapshot.capture(from: webView))?.elementList ?? ""
            let prompt = "Task: \(contextualTask)\n\nWhat BrowseFast did:\n" + history.map { "- \($0)" }.joined(separator: "\n")
                + (stopReason.map { "\n\nStopped early: \($0)" } ?? "")
                + "\n\nFinal page: \(webView.title ?? "") (\(webView.url?.absoluteString ?? ""))"
                + "\n\nInteractive elements on screen (\"disabled\" means unavailable):\n\(finalElements)"
                + "\n\nPage text:\n\(text)"
            let verdict = try await claude.json(Verdict.self, system: Prompts.verifier, prompt: prompt, schema: Prompts.verdictSchema)
            logClaude("Result", verdict)
            decisions[.claude, default: 0] += 1
            steps.finish(checkStep, verdict.value.achieved ? "Found what you asked for" : "Couldn't fully finish here")
            if !verdict.value.achieved { steps.setStatus(steps.steps.count - 1, .failed) }
            achieved = verdict.value.achieved
            answer = verdict.value.answer
            status = achieved ? .done : .failed
        } catch where Task.isCancelled {
            steps.markRunningAsFailed()
            steps.add(.browseFast, "Stopped", status: .failed)
            status = .failed
        } catch {
            steps.markRunningAsFailed()
            steps.add(.browseFast, "Something went wrong: \(error.localizedDescription)", status: .failed)
            answer = "Failed: \(error.localizedDescription)"
            status = .failed
        }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.write(tag, "Ended after \(seconds) s · \(steps.steps.count) steps · decisions: Jev \(decisions[.jev] ?? 0), Claude \(decisions[.claude] ?? 0)")
    }

    @ObservationIgnored private var adopted: Set<UUID> = []

    /// The overall task, this agent's part of it, and the user's choices so far.
    private var contextualTask: String {
        var text = task
        if instruction != task { text += "\nYour part (on \(name)): \(instruction)" }
        if !coordinator.userChoices.isEmpty { text += "\nThe user's choices so far: " + coordinator.userChoices.joined(separator: "; ") }
        return text
    }

    // MARK: - Page helpers

    /// An empty page or a failed capture usually means the page is still loading (or the script isn't
    /// injected yet), so look again a few times before handing it to the models.
    private func snapshot() async throws -> PageSnapshot {
        var attempt = 1
        while true {
            let all = Prompts.isSearchResults(webView.url?.absoluteString ?? "")
            if let page = try? await PageSnapshot.capture(from: webView, all: all), !page.elements.isEmpty || page.captcha || attempt == 4 {
                Log.write(tag.replacingOccurrences(of: "agent", with: "page"),
                          "Snapshot of \(page.url)\(attempt > 1 ? " (attempt \(attempt))" : ""): \(page.summary)",
                          details: page.elementList + (page.text.isEmpty ? "" : "\n--- text on screen ---\n" + page.text))
                return page
            }
            if attempt == 4 { return try await PageSnapshot.capture(from: webView) }
            Log.write(tag, "No elements yet on \(webView.url?.absoluteString ?? "?"), waiting (attempt \(attempt))")
            attempt += 1
            try await Task.sleep(for: .milliseconds(1500))
        }
    }

    /// Waits for any navigation the last action started, then until the page stops changing
    /// (apps often animate panels and calendars in after a click).
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        var waited = 0
        while webView.isLoading && waited < 10_000 {
            try await Task.sleep(for: .milliseconds(200))
            waited += 200
        }
        _ = try? await webView.asyncJS("await window.__browsefast.waitForQuiet(); return true", timeout: 5)
        // Cookie banners cover the page; closing them is plain code, no model needed.
        if let button = try? await webView.js("window.__browsefast.dismissCookies()") as? String {
            timeline.add(.browseFast, "Closed a cookie banner ('\(Prompts.short(button, 30))')", status: .done)
            _ = try? await webView.asyncJS("await window.__browsefast.waitForQuiet(); return true", timeout: 5)
        }
    }

    @discardableResult
    private func perform(_ command: [String: Any], step: Int, success: String, decider: Decider) async throws -> StepStatus {
        let json = String(data: try JSONSerialization.data(withJSONObject: command), encoding: .utf8)!
        let raw = try await webView.js("window.__browsefast.act(\(json))") as? String ?? "{}"
        let result = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        Log.write(tag, "Action \(json) → \(raw)")
        if result["ok"] as? Bool == true {
            timeline.finish(step, decider: decider, success)
            try await settle()
            return .done
        }
        let error = result["error"] as? String ?? "unknown error"
        if result["blocked"] as? Bool == true {
            timeline.setStatus(step, .done)
            timeline.add(.browseFast, "Stopped before acting: \(error). BrowseFast doesn't book, buy or send personal details yet.", status: .blocked)
            Log.write(tag, "Blocked by the safety guard: \(error)")
            return .blocked
        }
        timeline.fail(step, "\(success) failed: \(error)")
        return .failed
    }

    private func logClaude<T>(_ what: String, _ reply: ClaudeClient.Reply<T>) {
        Log.write(tag, "Claude \(what) (\(reply.ms) ms, \(reply.inputTokens) in / \(reply.outputTokens) out tokens)", details: reply.raw)
    }
}
