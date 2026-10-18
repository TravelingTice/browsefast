import Foundation
import Observation

/// Who made a decision, shown as a logo next to each step.
enum Decider: String {
    case claude = "Claude"
    case jev = "Jev"
    case browseFast = "BrowseFast"
    case you = "You"
}

enum StepStatus { case running, done, failed, blocked }

struct Step: Identifiable {
    let id = UUID()
    var decider: Decider
    var text: String
    var detail: String?
    var status: StepStatus
}

/// A choice the agent can't make for the user, shown as buttons in the sidebar.
struct Question: Identifiable {
    struct Choice: Identifiable, Hashable { let option: String; let label: String; var id: String { option } }
    let id = UUID()
    let text: String
    let choices: [Choice]
}

/// The steps of the coordinator or of one tab agent. Every finished step also goes to the session log.
@MainActor @Observable
final class Timeline {
    private(set) var steps: [Step] = []
    @ObservationIgnored let logTag: String

    init(logTag: String) { self.logTag = logTag }

    func begin(_ decider: Decider, _ text: String) -> Int {
        add(decider, text, status: .running)
        return steps.count - 1
    }

    func add(_ decider: Decider, _ text: String, detail: String? = nil, status: StepStatus) {
        steps.append(Step(decider: decider, text: text, detail: detail, status: status))
        if status != .running { Log.write(logTag, "[\(decider.rawValue)] \(text)", details: detail) }
    }

    func update(_ index: Int, decider: Decider, text: String) {
        steps[index].decider = decider
        steps[index].text = text
    }

    func finish(_ index: Int, decider: Decider? = nil, _ text: String, detail: String? = nil) {
        if let decider { steps[index].decider = decider }
        steps[index].text = text
        steps[index].detail = detail
        steps[index].status = .done
        Log.write(logTag, "[\(steps[index].decider.rawValue)] \(text)", details: detail)
    }

    func fail(_ index: Int, _ text: String) {
        steps[index].text = text
        steps[index].status = .failed
        Log.write(logTag, "[\(steps[index].decider.rawValue)] FAILED: \(text)")
    }

    func reset() { steps = [] }
    func setStatus(_ index: Int, _ status: StepStatus) { steps[index].status = status }
    func setText(_ index: Int, _ text: String) { steps[index].text = text }
    func remove(_ range: ClosedRange<Int>) { steps.removeSubrange(range) }

    func markRunningAsFailed() {
        for i in steps.indices where steps[i].status == .running { steps[i].status = .failed }
    }
}

/// One pending question at a time; the run waits until the sidebar answers it (or the run is stopped).
@MainActor @Observable
final class QuestionSlot {
    private(set) var question: Question?
    @ObservationIgnored private var continuation: CheckedContinuation<Question.Choice, Error>?

    func ask(_ question: Question) async throws -> Question.Choice {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.question = question
            }
        } onCancel: {
            Task { @MainActor in
                self.question = nil
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    func choose(_ choice: Question.Choice) {
        question = nil
        continuation?.resume(returning: choice)
        continuation = nil
    }
}
