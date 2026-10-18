import Foundation

/// Everything the models are told, in one place.
enum Prompts {
    static let planner = """
    You plan tasks for BrowseFast, an AI browser agent that controls a real web browser. A fast model carries out each goal by clicking and typing on the page, so goals must be concrete and visible on screen.

    Return:
    - start_url: where to begin. Use https://www.google.com/?hl=en and start with a search goal, unless you are sure of the exact website.
    - goals: 2 to 6 short goals in order, each reachable from the previous one with a few clicks. Put the exact text to type for a goal in "text" (for example a search query), or "" when the goal needs no typing.

    BrowseFast is read-only for now: it must never book, buy, pay, subscribe or submit personal details. If the task asks for that, plan only up to the point where the options are visible (for example the available times) and stop there. The last goal should be that the information the user wants is visible on screen.
    If the site needs a choice the task doesn't specify (like a date), pick the earliest available option.
    """

    static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "start_url": ["type": "string"],
            "goals": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["goal": ["type": "string"], "text": ["type": "string"]],
                    "required": ["goal", "text"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["start_url", "goals"],
        "additionalProperties": false,
    ]

    static let jevInstructions = "Which single action moves the browser closest to the current goal? Only pick results for the exact business or person named in the task; a similar name is a different one. Choose goal_done only if the current goal is already achieved on this page."

    static let decider = """
    You choose the next browser action for BrowseFast when its fast model is unsure. You get the task, the current goal, what was done so far, and the interactive elements on the page. Pick exactly one option key from the list.
    If the option types text, put the exact text in "text", otherwise "". Give a one-sentence reason.
    Names in the task must match exactly: a business or person with a similar name (for example a different first name) is a different one.
    Never pick an action that books, buys, pays or submits personal details.
    """

    static func decisionSchema(keys: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "option": ["type": "string", "enum": keys],
                "text": ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["option", "text", "reason"],
            "additionalProperties": false,
        ]
    }

    static let writer = """
    Write the exact text BrowseFast should type into a web page field to move the task forward. Return only that text in "text".
    Never invent personal details such as names, phone numbers, email addresses or addresses. If the field needs those and the task doesn't provide them, return "".
    """

    static let typedSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
        "additionalProperties": false,
    ]

    static let verifier = """
    You check the outcome of a BrowseFast task. You get the task, what BrowseFast did, and the text of the final page.
    Set "achieved" to whether the page shows what the user asked for. In "answer", write a short, direct reply to the user using facts from the page (for example the available times). If the task isn't achieved, say briefly what was found and what's missing. Never make up information that isn't on the page.
    """

    static let verdictSchema: [String: Any] = [
        "type": "object",
        "properties": ["achieved": ["type": "boolean"], "answer": ["type": "string"]],
        "required": ["achieved", "answer"],
        "additionalProperties": false,
    ]

    // MARK: - Jev input

    static func state(task: String, goal: String, goalNumber: Int, goalCount: Int, goalText: String,
                      history: [String], tabs: String, page: PageSnapshot) -> String {
        var lines = ["Task: \(task)", "Current goal (\(goalNumber) of \(goalCount)): \(goal)"]
        if !goalText.isEmpty { lines.append("Text to type for this goal: \"\(goalText)\"") }
        lines.append("Done so far:")
        lines += history.suffix(12).map { "- \($0)" }
        if tabs.contains("\n") { lines += ["", "Open tabs:", tabs] }
        lines.append("")
        lines.append("Page: \(page.title) (\(page.url))")
        lines.append(page.elementList)
        return lines.joined(separator: "\n")
    }

    static let textRoles: Set<String> = ["textbox", "searchbox", "email", "tel", "url", "number"]

    /// Every element becomes one option (or two for text fields), plus page-level actions. Jev allows 255.
    static func options(for page: PageSnapshot, goalText: String) -> [(key: String, description: String)] {
        var options: [(key: String, description: String)] = []
        for e in page.elements.prefix(110) where !(e.states ?? []).contains("disabled") {
            var name = "\(e.role) \"\(e.label)\""
            if (e.states ?? []).contains("image") { name = "image " + name }
            if textRoles.contains(e.role) || (e.role == "combobox" && e.options == nil && e.value != nil) {
                options.append(("type_\(e.id)", goalText.isEmpty ? "Type into \(name)" : "Type \"\(goalText)\" into \(name)"))
                if let value = e.value, !value.isEmpty {
                    options.append(("submit_\(e.id)", "Press Enter in \(name) (currently \"\(value)\") to submit or search"))
                }
            } else {
                options.append(("click_\(e.id)", "Click \(name)" + (e.href.map { " (" + (e.via ?? "goes to") + " \($0))" } ?? "")))
            }
        }
        if page.scroll[0] < page.scroll[1] - 5 { options.append(("scroll_down", "Scroll down to see more of the page")) }
        if page.scroll[0] > 5 { options.append(("scroll_up", "Scroll up")) }
        options += [
            ("go_back", "Go back to the previous page"),
            ("goal_done", "The current goal is already achieved on this page"),
            ("stuck", "None of these actions helps with the current goal"),
        ]
        return options
    }

    /// "click_12" → ("click", 12); "scroll_down" → ("scroll_down", nil)
    static func parse(_ option: String) -> (kind: String, id: Int?) {
        if let underscore = option.lastIndex(of: "_"), let id = Int(option[option.index(after: underscore)...]) {
            return (String(option[..<underscore]), id)
        }
        return (option, nil)
    }

    static func short(_ text: String, _ max: Int = 50) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }
}
