import Foundation
import Observation
import WebKit

/// One task from start to finish: Claude plans, Jev picks each action (Claude takes over when Jev is unsure),
/// the page script carries it out, and Claude checks the result. Every step goes to the sidebar and the log.
@MainActor @Observable
final class AgentRun {
    enum Decider: String {
        case claude = "Claude"
        case jev = "Jev"
        case browseFast = "BrowseFast"
    }

    enum StepStatus { case running, done, failed, blocked }

    struct Step: Identifiable {
        let id = UUID()
        var decider: Decider
        var text: String
        var detail: String?
        var status: StepStatus
    }

    private(set) var task: String?
    private(set) var steps: [Step] = []
    private(set) var answer: String?
    private(set) var isRunning = false

    let browser = Browser()
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let maxActions = 25
    static let jevConfidenceFloor = 0.5

    /// The agent always works in the focused tab.
    private var webView: WKWebView { (browser.active ?? browser.newTab()).webView }

    func start(_ task: String) {
        guard !isRunning else { return }
        if browser.tabs.isEmpty { browser.newTab() }
        self.task = task
        steps = []
        answer = nil
        isRunning = true
        loop = Task {
            await run(task)
            isRunning = false
        }
    }

    func stop() {
        loop?.cancel()
    }

    // MARK: - The run

    private struct Plan: Decodable {
        struct Goal: Decodable { let goal: String; let text: String }
        let start_url: String
        let goals: [Goal]
    }

    private struct Decision: Decodable { let option: String; let text: String; let reason: String }
    private struct Typed: Decodable { let text: String }
    private struct Verdict: Decodable { let achieved: Bool; let answer: String }

    private func run(_ task: String) async {
        let started = Date()
        Log.write("agent", "Task started: \(task)")
        let claude = ClaudeClient(apiKey: KeyStore.read(.claude) ?? "")
        let jev = JevClient(apiKey: KeyStore.read(.typesafe) ?? "")
        var history: [String] = []
        var decisions: [Decider: Int] = [:]

        do {
            // 1. Plan
            let planStep = begin(.claude, "Planning the task…")
            let plan = try await claude.json(Plan.self, system: Prompts.planner, prompt: task, schema: Prompts.planSchema)
            logClaude("Plan", plan)
            decisions[.claude, default: 0] += 1
            finish(planStep, "Made a plan", detail: plan.value.goals.enumerated()
                .map { "\($0.offset + 1). \($0.element.goal)" }.joined(separator: "\n"))

            // 2. Open the start page
            let url = URL(string: plan.value.start_url) ?? URL(string: "https://www.google.com/?hl=en")!
            let host = url.host() ?? url.absoluteString
            let navStep = begin(.claude, "Opening \(host)…")
            webView.load(URLRequest(url: url))
            try await settle()
            finish(navStep, "Navigated to \(host)")
            history.append("Navigated to \(host)")

            // 3. Work through the goals
            var goalIndex = 0
            var actions = 0
            var lastAction = ""
            var repeats = 0
            // Actions already taken in an identical page state (same URL and same element list), keyed by what
            // the option does rather than its number. Single-page apps keep one URL, so the URL alone isn't enough.
            var tried: Set<String> = []
            var stopReason: String?

            goals: while goalIndex < plan.value.goals.count {
                try Task.checkCancellation()
                if actions >= Self.maxActions {
                    stopReason = "Stopped after \(Self.maxActions) actions without finishing"
                    add(.browseFast, stopReason!, status: .failed)
                    break
                }
                actions += 1
                let goal = plan.value.goals[goalIndex]
                let goalText = goal.text.trimmingCharacters(in: .whitespaces)
                let page = try await snapshot()
                let pageState = "\(page.url)|\(page.elementList.hashValue)"
                let options = Prompts.options(for: page, goalText: goalText)
                    .filter { !tried.contains("\(pageState)|\($0.description)") || $0.key.hasPrefix("scroll") || $0.key == "goal_done" }
                    + tabOptions()
                let state = Prompts.state(task: task, goal: goal.goal, goalNumber: goalIndex + 1,
                                          goalCount: plan.value.goals.count, goalText: goalText,
                                          history: history, tabs: tabList(), page: page)

                // Decide: Jev first, Claude when Jev is unsure, gives up, or keeps repeating itself.
                let step = begin(.jev, "Deciding the next step…")
                let pick = try await jev.choose(state: state, instructions: Prompts.jevInstructions, options: options)
                let top = pick.probabilities.prefix(3).map { "\($0.option) \(String(format: "%.2f", $0.p))" }.joined(separator: ", ")
                Log.write("agent", "Jev chose \(pick.choice) (confidence \(String(format: "%.2f", pick.confidence)), \(pick.ms) ms) · goal \(goalIndex + 1)/\(plan.value.goals.count): \(goal.goal)",
                          details: "top: \(top)\noptions: \(options.count)")

                var decider = Decider.jev
                var choice = pick.choice
                var text: String? = goalText.isEmpty ? nil : goalText
                let pageKey = "\(page.url)|\(choice)"
                repeats = pageKey == lastAction ? repeats + 1 : 0
                lastAction = pageKey

                let reason: String? = choice == "stuck" ? "Jev found no fitting action"
                    : pick.confidence < Self.jevConfidenceFloor ? "Jev was unsure (confidence \(String(format: "%.2f", pick.confidence)))"
                    : repeats >= 2 ? "Jev repeated the same action three times"
                    : nil
                if let reason {
                    update(step, decider: .claude, text: "Thinking about the next step…")
                    Log.write("agent", "Handing this step to Claude: \(reason)")
                    let schema = Prompts.decisionSchema(keys: options.map(\.key).filter { $0 != "stuck" })
                    let visibleText = (try? await webView.evaluateJavaScript("window.__browsefast.pageText()") as? String) ?? ""
                    let prompt = state + "\n\nVisible page text (start):\n" + String(visibleText.prefix(4000))
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
                case "goal_done":
                    finish(step, decider: decider, "Finished: \(goal.goal)")
                    history.append("Finished goal: \(goal.goal)")
                    goalIndex += 1
                    continue goals

                case "type":
                    guard let element else { fail(step, "Couldn't find the field to type in"); continue goals }
                    if text == nil {
                        // The decision was Jev's; writing the text is a separate Claude call, so it gets its own row.
                        finish(step, decider: decider, "Chose the \(name) field to fill in")
                        let writeStep = begin(.claude, "Writing what to type…")
                        let typed = try await claude.json(Typed.self, system: Prompts.writer,
                                                          prompt: "Task: \(task)\nCurrent goal: \(goal.goal)\nField: \(element.role) \"\(element.label)\"",
                                                          schema: Prompts.typedSchema)
                        logClaude("Text", typed)
                        decisions[.claude, default: 0] += 1
                        guard !typed.value.text.isEmpty else {
                            fail(writeStep, "Didn't know what to type in \(name)")
                            history.append("Could not decide what to type in \(name)")
                            continue goals
                        }
                        text = typed.value.text
                        try await perform(["kind": "type", "id": element.id, "text": typed.value.text], step: writeStep,
                                          success: "Filled in '\(Prompts.short(typed.value.text))' in \(name)", decider: .claude)
                    } else {
                        try await perform(["kind": "type", "id": element.id, "text": text!], step: step,
                                          success: "Filled in '\(Prompts.short(text!))' in \(name)", decider: decider)
                    }
                    history.append("Filled in '\(text ?? "")' in \(name)")

                case "submit":
                    guard let element else { fail(step, "Couldn't find the field"); continue goals }
                    if try await perform(["kind": "submit", "id": element.id], step: step,
                                         success: "Pressed Enter in \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break goals
                    }
                    history.append("Pressed Enter in \(name)")

                case "click":
                    guard let element else { fail(step, "Couldn't find what to click"); continue goals }
                    let tabsBefore = browser.tabs.count
                    if try await perform(["kind": "click", "id": element.id], step: step,
                                         success: "Clicked \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break goals
                    }
                    if browser.tabs.count > tabsBefore {
                        steps[step].text = "Clicked \(name) (opened in a new tab)"
                        history.append("Clicked \(name), which opened in a new tab (now focused)")
                    } else {
                        history.append("Clicked \(name)")
                    }

                case "switch_tab":
                    guard let id, let tab = browser.tabs[safe: id - 1] else { fail(step, "That tab no longer exists"); continue goals }
                    browser.select(tab)
                    finish(step, decider: decider, "Switched to tab '\(Prompts.short(tab.title))'")
                    history.append("Switched to tab \(id): \(tab.title)")
                    try await settle()

                case "close_tab":
                    guard let tab = browser.active, browser.tabs.count > 1 else { fail(step, "There's no other tab to go back to"); continue goals }
                    browser.close(tab)
                    finish(step, decider: decider, "Closed the tab '\(Prompts.short(tab.title))'")
                    history.append("Closed tab: \(tab.title)")

                case "scroll_down", "scroll_up":
                    let up = kind == "scroll_up"
                    try await perform(["kind": "scroll", "direction": up ? "up" : "down"], step: step,
                                      success: up ? "Scrolled up" : "Scrolled down", decider: decider)
                    history.append(up ? "Scrolled up" : "Scrolled down")

                case "go_back":
                    try await perform(["kind": "back"], step: step, success: "Went back to the previous page", decider: decider)
                    history.append("Went back")

                default:
                    fail(step, "Got an unknown action: \(choice)")
                }
            }

            // 4. Check the result and answer
            try Task.checkCancellation()
            let checkStep = begin(.claude, "Checking the result…")
            let text = (try? await webView.evaluateJavaScript("window.__browsefast.pageText()") as? String) ?? ""
            let prompt = "Task: \(task)\n\nWhat BrowseFast did:\n" + history.map { "- \($0)" }.joined(separator: "\n")
                + (stopReason.map { "\n\nStopped early: \($0)" } ?? "")
                + "\n\nFinal page: \(webView.title ?? "") (\(webView.url?.absoluteString ?? ""))\n\nPage text:\n\(text)"
            let verdict = try await claude.json(Verdict.self, system: Prompts.verifier, prompt: prompt, schema: Prompts.verdictSchema)
            logClaude("Result", verdict)
            decisions[.claude, default: 0] += 1
            finish(checkStep, verdict.value.achieved ? "Found what you asked for" : "Couldn't fully finish the task")
            if !verdict.value.achieved { steps[steps.count - 1].status = .failed }
            answer = verdict.value.answer
        } catch where Task.isCancelled {
            markRunningAsFailed()
            add(.browseFast, "Stopped by you", status: .failed)
            Log.write("agent", "Task stopped by the user")
        } catch {
            markRunningAsFailed()
            add(.browseFast, "Something went wrong: \(error.localizedDescription)", status: .failed)
            Log.write("agent", "Task failed: \(error.localizedDescription)")
        }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.write("agent", "Task ended after \(seconds) s · \(steps.count) steps · decisions: Jev \(decisions[.jev] ?? 0), Claude \(decisions[.claude] ?? 0)")
    }

    // MARK: - Page helpers

    /// An empty page or a failed capture usually means the page is still loading (or the script isn't
    /// injected yet), so look again a few times before handing it to the models.
    private func snapshot() async throws -> PageSnapshot {
        var attempt = 1
        while true {
            if let page = try? await PageSnapshot.capture(from: webView), !page.elements.isEmpty || attempt == 4 {
                Log.write("page", "Snapshot of \(page.url)\(attempt > 1 ? " (attempt \(attempt))" : ""): \(page.summary)",
                          details: page.elementList)
                return page
            }
            if attempt == 4 { return try await PageSnapshot.capture(from: webView) }
            Log.write("page", "No elements yet on \(webView.url?.absoluteString ?? "?"), waiting (attempt \(attempt))")
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
        _ = try? await webView.callAsyncJavaScript("await window.__browsefast.waitForQuiet(); return true",
                                                   contentWorld: .page)
        // Cookie banners cover the page; closing them is plain code, no model needed.
        if let button = try? await webView.evaluateJavaScript("window.__browsefast.dismissCookies()") as? String {
            add(.browseFast, "Closed a cookie banner ('\(Prompts.short(button, 30))')", status: .done)
            _ = try? await webView.callAsyncJavaScript("await window.__browsefast.waitForQuiet(); return true",
                                                       contentWorld: .page)
        }
    }

    private func tabOptions() -> [(key: String, description: String)] {
        guard browser.tabs.count > 1 else { return [] }
        return browser.tabs.enumerated()
            .filter { $0.element.id != browser.activeID }
            .map { ("switch_tab_\($0.offset + 1)", "Switch to tab \($0.offset + 1): \"\($0.element.title)\"") }
            + [("close_tab", "Close this tab and go back to the previous one")]
    }

    private func tabList() -> String {
        browser.tabs.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)\($0.element.id == browser.activeID ? " (current)" : "")" }
            .joined(separator: "\n")
    }

    @discardableResult
    private func perform(_ command: [String: Any], step: Int, success: String, decider: Decider) async throws -> StepStatus {
        let json = String(data: try JSONSerialization.data(withJSONObject: command), encoding: .utf8)!
        let raw = try await webView.evaluateJavaScript("window.__browsefast.act(\(json))") as? String ?? "{}"
        let result = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        Log.write("agent", "Action \(json) → \(raw)")
        if result["ok"] as? Bool == true {
            finish(step, decider: decider, success)
            try await settle()
            return .done
        }
        let error = result["error"] as? String ?? "unknown error"
        if result["blocked"] as? Bool == true {
            steps[step].status = .done
            add(.browseFast, "Stopped before acting: \(error). BrowseFast doesn't book, buy or send personal details yet.", status: .blocked)
            Log.write("agent", "Blocked by the safety guard: \(error)")
            return .blocked
        }
        fail(step, "\(success) failed: \(error)")
        return .failed
    }

    // MARK: - Steps

    private func begin(_ decider: Decider, _ text: String) -> Int {
        add(decider, text, status: .running)
        return steps.count - 1
    }

    private func add(_ decider: Decider, _ text: String, detail: String? = nil, status: StepStatus) {
        steps.append(Step(decider: decider, text: text, detail: detail, status: status))
        if status != .running { Log.write("agent", "[\(decider.rawValue)] \(text)", details: detail) }
    }

    private func update(_ index: Int, decider: Decider, text: String) {
        steps[index].decider = decider
        steps[index].text = text
    }

    private func finish(_ index: Int, decider: Decider? = nil, _ text: String, detail: String? = nil) {
        if let decider { steps[index].decider = decider }
        steps[index].text = text
        steps[index].detail = detail
        steps[index].status = .done
        Log.write("agent", "[\(steps[index].decider.rawValue)] \(text)", details: detail)
    }

    private func fail(_ index: Int, _ text: String) {
        steps[index].text = text
        steps[index].status = .failed
        Log.write("agent", "[\(steps[index].decider.rawValue)] FAILED: \(text)")
    }

    private func markRunningAsFailed() {
        for i in steps.indices where steps[i].status == .running { steps[i].status = .failed }
    }

    private func logClaude<T>(_ what: String, _ reply: ClaudeClient.Reply<T>) {
        Log.write("agent", "Claude \(what) (\(reply.ms) ms, \(reply.inputTokens) in / \(reply.outputTokens) out tokens)", details: reply.raw)
    }
}
