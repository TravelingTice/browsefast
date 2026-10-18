import Foundation
import Observation

/// What Claude decides up front: one site or several in parallel, questions every site would need answered,
/// and what each tab agent should do.
struct Plan: Decodable {
    struct Goal: Decodable { let goal: String; let text: String }
    struct SharedQuestion: Decodable { let question: String; let choices: [String] }
    struct Source: Decodable { let name: String; let start_url: String; let instruction: String; let goals: [Goal] }
    let parallel: Bool
    let questions: [SharedQuestion]
    let sources: [Source]
}

/// The coordinator of one task. It plans, asks questions that apply to every site once, runs one TabAgent per
/// site (up to four at a time, each in its own tab), and compares what they found.
@MainActor @Observable
final class TaskRun {
    let browser = Browser()
    let timeline = Timeline(logTag: "task")
    let questions = QuestionSlot()
    private(set) var task: String?
    private(set) var agents: [TabAgent] = []
    private(set) var answer: String?
    private(set) var isRunning = false

    /// Shared by all tab agents, so an answer given in one tab is reused in the others.
    @ObservationIgnored private(set) var answers: [String: String] = [:]
    @ObservationIgnored private(set) var userChoices: [String] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var runNumber = 0

    static let maxTabs = 4

    func start(_ task: String) {
        guard !isRunning else { return }
        if browser.tabs.isEmpty { browser.newTab() }
        self.task = task
        agents = []
        answer = nil
        answers = [:]
        userChoices = []
        timeline.reset()
        isRunning = true
        runNumber += 1
        let number = runNumber
        loop = Task {
            await coordinate(task)
            if runNumber == number { isRunning = false }
        }
    }

    /// Stops right away in the UI, even if a page or model call underneath is still finishing.
    func stop() {
        loop?.cancel()
        guard isRunning else { return }
        isRunning = false
        timeline.markRunningAsFailed()
        for agent in agents { agent.timeline.markRunningAsFailed() }
        Log.write("task", "Stop pressed")
    }

    func agent(for tab: BrowserTab) -> TabAgent? { agents.first { $0.tab.id == tab.id } }

    func remember(question: String, signature: String, answer: String) {
        answers[signature] = answer
        answers[question] = answer
        userChoices.append("\(question) → \(answer)")
    }

    private struct Comparison: Decodable { let answer: String }

    private func coordinate(_ task: String) async {
        let started = Date()
        Log.write("task", "Task started: \(task)")
        let claude = ClaudeClient(apiKey: KeyStore.read(.claude) ?? "")

        do {
            // 1. Plan: one site or several
            let planStep = timeline.begin(.claude, "Planning the task…")
            let reply = try await claude.json(Plan.self, system: Prompts.planner, prompt: task, schema: Prompts.planSchema)
            Log.write("task", "Claude Plan (\(reply.ms) ms, \(reply.inputTokens) in / \(reply.outputTokens) out tokens)", details: reply.raw)
            let plan = reply.value
            var sources = Array(plan.sources.prefix(Self.maxTabs))
            if sources.isEmpty {
                sources = [Plan.Source(name: "Google", start_url: "https://www.google.com/?hl=en", instruction: task, goals: [])]
            }
            let parallel = plan.parallel && sources.count > 1
            timeline.finish(planStep, parallel ? "Made a plan: \(sources.count) sites in parallel" : "Made a plan",
                            detail: parallel ? sources.map { "• \($0.name): \($0.instruction)" }.joined(separator: "\n")
                                             : sources[0].goals.enumerated().map { "\($0.offset + 1). \($0.element.goal)" }.joined(separator: "\n"))

            // 2. Questions every site needs answered, asked once before the tabs start
            for shared in plan.questions where !shared.choices.isEmpty {
                timeline.add(.claude, "Asked you: \(shared.question)", status: .done)
                let choices = shared.choices.prefix(20).map { Question.Choice(option: $0, label: $0) }
                let picked = try await questions.ask(Question(text: shared.question, choices: Array(choices)))
                remember(question: shared.question, signature: choices.map(\.label).sorted().joined(separator: "|"), answer: picked.label)
                timeline.add(.you, "You chose '\(picked.label)'", status: .done)
            }

            // 3. One tab agent per site, all running at the same time
            agents = sources.enumerated().map { index, source in
                let tab = index == 0 ? (browser.active ?? browser.newTab()) : browser.newTab(focus: false)
                return TabAgent(name: source.name, tab: tab, coordinator: self, browser: browser, task: task,
                                instruction: parallel ? source.instruction : task,
                                startURL: URL(string: source.start_url) ?? URL(string: "https://www.google.com/?hl=en")!,
                                goals: source.goals.isEmpty ? [Plan.Goal(goal: source.instruction, text: "")] : source.goals)
            }
            if parallel { timeline.add(.browseFast, "Opened \(agents.count) tabs, one per site", status: .done) }
            await withTaskGroup(of: Void.self) { group in
                for agent in agents { group.addTask { @MainActor in await agent.run() } }
            }
            try Task.checkCancellation()

            // 4. One site: its answer is the answer. Several: compare them.
            if !parallel {
                answer = agents.first?.answer
            } else {
                let compareStep = timeline.begin(.claude, "Comparing what each site found…")
                let findings = agents.map { "Site: \($0.name)\nFinished: \($0.achieved ? "yes" : "no")\nFound: \($0.answer ?? "nothing")" }
                    .joined(separator: "\n\n")
                let prompt = "Task: \(task)\n"
                    + (userChoices.isEmpty ? "" : "User's choices: \(userChoices.joined(separator: "; "))\n")
                    + "\nFindings per site:\n\n\(findings)"
                let compared = try await claude.json(Comparison.self, system: Prompts.comparer, prompt: prompt, schema: Prompts.comparisonSchema)
                Log.write("task", "Claude Comparison (\(compared.ms) ms, \(compared.inputTokens) in / \(compared.outputTokens) out tokens)", details: compared.raw)
                timeline.finish(compareStep, "Compared \(agents.count) sites")
                answer = compared.value.answer
            }
        } catch where Task.isCancelled {
            timeline.markRunningAsFailed()
            timeline.add(.browseFast, "Stopped by you", status: .failed)
        } catch {
            timeline.markRunningAsFailed()
            timeline.add(.browseFast, "Something went wrong: \(error.localizedDescription)", status: .failed)
        }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.write("task", "Task ended after \(seconds) s · \(agents.count) tab agent(s)")
    }
}
