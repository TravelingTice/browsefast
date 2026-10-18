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
        case you = "You"
    }

    /// A choice the agent can't make for the user, shown as buttons in the sidebar.
    struct Question: Identifiable {
        struct Choice: Identifiable, Hashable { let option: String; let label: String; var id: String { option } }
        let id = UUID()
        let text: String
        let choices: [Choice]
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
    private(set) var question: Question?
    @ObservationIgnored private var questionContinuation: CheckedContinuation<Question.Choice, Error>?

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

    /// Called by the sidebar when the user picks one of the question's buttons.
    func choose(_ choice: Question.Choice) {
        question = nil
        questionContinuation?.resume(returning: choice)
        questionContinuation = nil
    }

    private func ask(_ question: Question) async throws -> Question.Choice {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.questionContinuation = continuation
                self.question = question
            }
        } onCancel: {
            Task { @MainActor in
                self.question = nil
                self.questionContinuation?.resume(throwing: CancellationError())
                self.questionContinuation = nil
            }
        }
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
    private struct AskOut: Decodable {
        struct Choice: Decodable { let option: String; let label: String }
        let question: String
        let choices: [Choice]
    }

    private func run(_ task: String) async {
        let started = Date()
        Log.write("agent", "Task started: \(task)")
        let claude = ClaudeClient(apiKey: KeyStore.read(.claude) ?? "")
        let jev = JevClient(apiKey: KeyStore.read(.typesafe) ?? "")
        var history: [String] = []
        var userChoices: [String] = []
        var decisions: [Decider: Int] = [:]

        do {
            // 1. Plan
            let planStep = begin(.claude, "Planning the task…")
            var plan = try await claude.json(Plan.self, system: Prompts.planner, prompt: task, schema: Prompts.planSchema)
            logClaude("Plan", plan)
            decisions[.claude, default: 0] += 1
            if plan.value.goals.isEmpty {
                Log.write("agent", "Plan had no goals, planning again")
                plan = try await claude.json(Plan.self, system: Prompts.planner,
                                             prompt: task + "\n\nReturn at least two goals.", schema: Prompts.planSchema)
                logClaude("Plan (retry)", plan)
                decisions[.claude, default: 0] += 1
            }
            let goals = plan.value.goals.isEmpty ? [Plan.Goal(goal: task, text: "")] : plan.value.goals
            finish(planStep, "Made a plan", detail: goals.enumerated()
                .map { "\($0.offset + 1). \($0.element.goal)" }.joined(separator: "\n"))

            // 2. Open the start page
            let url = URL(string: plan.value.start_url) ?? URL(string: "https://www.google.com/?hl=en")!
            let host = url.host() ?? url.absoluteString
            let navStep = begin(.claude, "Opening \(host)…")
            webView.load(URLRequest(url: url))
            try await settle()
            finish(navStep, "Navigated to \(host)")
            history.append("Navigated to \(host)")

            // 3. Act until the task is done. The plan is context for every decision, not a checklist to tick off:
            // per-goal "is this goal done?" decisions were a third of all calls and the main source of low confidence.
            var pendingTexts = goals.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let planLines = goals.map(\.goal)
            var actions = 0
            var lastAction = ""
            var repeats = 0
            // Actions already taken in an identical page state (same URL and same element list), keyed by what
            // the option does rather than its number. Single-page apps keep one URL, so the URL alone isn't enough.
            var tried: Set<String> = []
            var visits: [String: Int] = [:]            // how often each exact page state came back
            var answers: [String: String] = [:]        // question signature → the label the user picked
            var lastPage = ""
            var stopReason: String?

            work: while true {
                try Task.checkCancellation()
                if actions >= Self.maxActions {
                    stopReason = "Stopped after \(Self.maxActions) actions without finishing"
                    add(.browseFast, stopReason!, status: .failed)
                    break
                }
                actions += 1
                let goalText = pendingTexts.first ?? ""
                let page = try await snapshot()
                let pageState = "\(page.url)|\(page.elementList.hashValue)"
                visits[pageState, default: 0] += 1
                // Every model sees which page each action happened on.
                if page.url + page.title != lastPage {
                    history.append("Now on: \(page.title.isEmpty ? page.url : page.title) (\(URL(string: page.url)?.host() ?? page.url))")
                    lastPage = page.url + page.title
                }
                if visits[pageState]! >= 5 {
                    stopReason = "Stuck in a loop: the same page kept coming back"
                    add(.browseFast, stopReason!, status: .failed)
                    break work
                }
                let looping = visits[pageState]! >= 3
                if looping {
                    history.append("Loop warning: this exact page has come back \(visits[pageState]!) times. Choices already made stay made; don't redo them, move forward instead.")
                }
                let options = Prompts.options(for: page, goalText: goalText)
                    .filter { !tried.contains("\(pageState)|\($0.description)") || $0.key.hasPrefix("scroll") || $0.key == "task_done" }
                    + tabOptions()
                    + askOption(onSearchResults: Prompts.isSearchResults(page.url))
                let taskWithChoices = task + (userChoices.isEmpty ? "" : "\nThe user's choices so far: " + userChoices.joined(separator: "; "))
                let state = Prompts.state(task: taskWithChoices, plan: planLines, goalText: goalText,
                                          history: history, tabs: tabList(), page: page)

                // Decide: Claude on search results pages (choosing a website is an open judgment call);
                // elsewhere Jev first, and Claude when Jev is unsure, gives up, or keeps repeating itself.
                var decider = Decider.jev
                var choice = "stuck"
                var text: String? = goalText.isEmpty ? nil : goalText
                var reason: String?
                let onSearchResults = Prompts.isSearchResults(page.url)
                let step = begin(onSearchResults ? .claude : .jev, onSearchResults ? "Choosing a search result…" : "Deciding the next step…")

                if onSearchResults {
                    reason = "search results page, Claude picks the website"
                } else {
                    let pick = try await jev.choose(state: state, instructions: Prompts.jevInstructions, options: options)
                    let top = pick.probabilities.prefix(3).map { "\($0.option) \(String(format: "%.2f", $0.p))" }.joined(separator: ", ")
                    Log.write("agent", "Jev chose \(pick.choice) (confidence \(String(format: "%.2f", pick.confidence)), \(pick.ms) ms)",
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
                    if !onSearchResults { update(step, decider: .claude, text: "Thinking about the next step…") }
                    Log.write("agent", "Handing this step to Claude: \(reason)")
                    let schema = Prompts.decisionSchema(keys: options.map(\.key).filter { $0 != "stuck" })
                    let visibleText = (try? await webView.evaluateJavaScript("window.__browsefast.pageText()") as? String) ?? ""
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
                    finish(step, decider: decider, "The task looks done")
                    break work

                case "type":
                    guard let element else { fail(step, "Couldn't find the field to type in"); continue work }
                    if text == nil {
                        // The decision was Jev's; writing the text is a separate Claude call, so it gets its own row.
                        finish(step, decider: decider, "Chose the \(name) field to fill in")
                        let writeStep = begin(.claude, "Writing what to type…")
                        let typed = try await claude.json(Typed.self, system: Prompts.writer,
                                                          prompt: "Task: \(task)\nPlan: \(planLines.joined(separator: "; "))\nWhat happened so far:\n\(history.map { "- \($0)" }.joined(separator: "\n"))\nField: \(element.role) \"\(element.label)\"",
                                                          schema: Prompts.typedSchema)
                        logClaude("Text", typed)
                        decisions[.claude, default: 0] += 1
                        guard !typed.value.text.isEmpty else {
                            fail(writeStep, "Didn't know what to type in \(name)")
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

                case "submit":
                    guard let element else { fail(step, "Couldn't find the field"); continue work }
                    if try await perform(["kind": "submit", "id": element.id], step: step,
                                         success: "Pressed Enter in \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    history.append("Pressed Enter in \(name)")

                case "click":
                    guard let element else { fail(step, "Couldn't find what to click"); continue work }
                    let tabsBefore = browser.tabs.count
                    if try await perform(["kind": "click", "id": element.id], step: step,
                                         success: "Clicked \(name)", decider: decider) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    if browser.tabs.count > tabsBefore {
                        steps[step].text = "Clicked \(name) (opened in a new tab)"
                        history.append("Clicked \(name), which opened in a new tab (now focused)")
                    } else {
                        history.append("Clicked \(name)")
                    }

                case "ask_user":
                    // Every option, ignoring the loop guard: the user must be able to pick anything on the page.
                    let clickable = Prompts.options(for: page, goalText: "").filter { $0.key.hasPrefix("click_") }
                    guard !clickable.isEmpty else { fail(step, "Wanted to ask you something, but there was nothing to choose from"); continue work }
                    finish(step, decider: decider, "Needs your input")
                    let askStep = begin(.claude, "Writing a question for you…")
                    let asked = try await claude.json(AskOut.self, system: Prompts.asker,
                                                      prompt: state + "\n\nClickable options:\n" + clickable.map { "\($0.key): \($0.description)" }.joined(separator: "\n"),
                                                      schema: Prompts.askSchema(keys: clickable.map(\.key)))
                    logClaude("Question", asked)
                    decisions[.claude, default: 0] += 1
                    let choices = asked.value.choices.prefix(20).map { Question.Choice(option: $0.option, label: $0.label) }
                    guard !choices.isEmpty else {
                        // Usually the page is still rendering the options (a calendar animating in); look again.
                        steps.removeSubrange(step...askStep)
                        Log.write("agent", "Nothing to ask about yet, looking at the page again")
                        try await Task.sleep(for: .seconds(1))
                        continue work
                    }
                    finish(askStep, "Asked you: \(asked.value.question)")
                    let signature = choices.map(\.label).sorted().joined(separator: "|")
                    let earlier = answers[signature] ?? answers[asked.value.question]
                    if let earlier, let again = choices.first(where: { $0.label == earlier }) {
                        // Asked before with the same options: reuse the answer instead of asking again.
                        steps.removeSubrange(step...askStep)
                        let reuseStep = begin(.you, "Used your earlier choice '\(again.label)'")
                        Log.write("agent", "Reusing earlier answer '\(again.label)' for '\(asked.value.question)'")
                        guard let againID = Prompts.parse(again.option).id else { continue work }
                        if try await perform(["kind": "click", "id": againID], step: reuseStep,
                                             success: "Used your earlier choice '\(again.label)'", decider: .you) == .blocked {
                            stopReason = "blocked"; break work
                        }
                        history.append("Re-applied the user's earlier choice '\(again.label)'. This choice is now made; move on to the next step.")
                        continue work
                    }
                    let picked = try await ask(Question(text: asked.value.question, choices: choices))
                    answers[signature] = picked.label
                    answers[asked.value.question] = picked.label
                    Log.write("agent", "User answered '\(asked.value.question)' with '\(picked.label)' (\(picked.option))")
                    userChoices.append("\(asked.value.question) → \(picked.label)")
                    guard let pickedID = Prompts.parse(picked.option).id else { continue work }
                    let youStep = begin(.you, "You chose '\(picked.label)'")
                    if try await perform(["kind": "click", "id": pickedID], step: youStep,
                                         success: "You chose '\(picked.label)'", decider: .you) == .blocked {
                        stopReason = "blocked"; break work
                    }
                    history.append("Asked the user '\(asked.value.question)', they chose '\(picked.label)' and it was clicked")

                case "switch_tab":
                    guard let id, let tab = browser.tabs[safe: id - 1] else { fail(step, "That tab no longer exists"); continue work }
                    browser.select(tab)
                    finish(step, decider: decider, "Switched to tab '\(Prompts.short(tab.title))'")
                    history.append("Switched to tab \(id): \(tab.title)")
                    try await settle()

                case "close_tab":
                    guard let tab = browser.active, browser.tabs.count > 1 else { fail(step, "There's no other tab to go back to"); continue work }
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
            // Page text alone can't tell greyed-out options (like unavailable times) from real ones; the element list can.
            let finalElements = (try? await PageSnapshot.capture(from: webView))?.elementList ?? ""
            let prompt = "Task: \(task)\n\nWhat BrowseFast did:\n" + history.map { "- \($0)" }.joined(separator: "\n")
                + (stopReason.map { "\n\nStopped early: \($0)" } ?? "")
                + "\n\nFinal page: \(webView.title ?? "") (\(webView.url?.absoluteString ?? ""))"
                + "\n\nInteractive elements on screen (\"disabled\" means unavailable):\n\(finalElements)"
                + "\n\nPage text:\n\(text)"
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
            let all = Prompts.isSearchResults(webView.url?.absoluteString ?? "")
            if let page = try? await PageSnapshot.capture(from: webView, all: all), !page.elements.isEmpty || attempt == 4 {
                Log.write("page", "Snapshot of \(page.url)\(attempt > 1 ? " (attempt \(attempt))" : ""): \(page.summary)",
                          details: page.elementList + (page.text.isEmpty ? "" : "\n--- text on screen ---\n" + page.text))
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

    private func askOption(onSearchResults: Bool) -> [(key: String, description: String)] {
        onSearchResults ? [] : [("ask_user", "Ask the user: the page needs a choice the task doesn't specify (like a service, a person, gender, a date or a time)")]
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
