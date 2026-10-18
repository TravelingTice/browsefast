import Foundation

/// Everything the models are told, in one place.
enum Prompts {
    static let planner = """
    You plan tasks for BrowseFast, an AI browser agent that controls a real web browser. A fast model carries out each goal by clicking and typing on the page, so goals must be concrete and visible on screen.

    Return:
    - start_url: where to begin. Use https://www.google.com/?hl=en and start with a search goal, unless you are sure of the exact website.
    - goals: 2 to 6 short goals in order, each reachable from the previous one with a few clicks. Put the exact text to type for a goal in "text" (for example a search query), or "" when the goal needs no typing.

    BrowseFast is read-only for now: it must never book, buy, pay, subscribe or submit personal details. If the task asks for that, plan only up to the point where the options are visible (for example the available times) and stop there. The last goal should be that the information the user wants is visible on screen.
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

    static let jevInstructions = "Which single action moves the browser closest to finishing the task, following the plan? Only pick results for the exact business or person named in the task; a similar name is a different one. If the page asks for a choice the task already settles (for example the person or date it names), pick that option. If the page needs a choice the task and the user's choices don't settle (like a service, gender, a date or a time), choose ask_user. Never reopen or redo a choice that is already made (it shows on the page or in the user's choices); in a step-by-step booking flow, move to the next step instead of going back to an earlier one. Choose task_done only when the information the task asks for is shown on this page."

    static let decider = """
    You choose the next browser action for BrowseFast when its fast model is unsure. You get the task, the plan, what was done so far, and the interactive elements on the page. Pick exactly one option key from the list.
    If the option types text, put the exact text in "text", otherwise "". Give a one-sentence reason.
    Names in the task must match exactly: a business or person with a similar name (for example a different first name) is a different one.
    If the task or the user's choices already settle a choice on the page (for example a person or date named in the task), pick that option directly.
    If the page needs a choice that the task and the user's choices so far don't settle (like a service, a person, gender, a date or a time), pick ask_user instead of guessing.
    Never reopen or redo a choice that is already made (it shows on the page, or is in the user's choices or the history). In a step-by-step flow such as a booking wizard, move to the next step instead of going back to an earlier one or to the start.
    Never pick an action that books, buys, pays or submits personal details.
    """

    static let asker = """
    BrowseFast needs the user to make a choice on this page. Check the history and the user's choices first: don't ask about something that is already decided. Write one short, friendly question and the choices to answer it, taken from the clickable options listed. Use each option's key exactly.
    Include every option on the page that answers the question (for example all the treatments, or all available dates), up to 20. Don't drop options based on assumptions about the user; that is their choice to make. Leave out only options that don't answer the question, like navigation or close buttons.
    Keep the site's own wording for each label so it matches the page, only tidying it up (for example "Mon 19 Oct" instead of "19 (Mon Oct 19 2026)").
    """

    static func askSchema(keys: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "question": ["type": "string"],
                "choices": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["option": ["type": "string", "enum": keys], "label": ["type": "string"]],
                        "required": ["option", "label"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["question", "choices"],
            "additionalProperties": false,
        ]
    }

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
    Options marked "disabled" in the element list are unavailable (for example booked time slots): never report them as available.
    Set "achieved" to true only if the final page itself shows the information the user asked for (for example a list of available times), not just a step, tab or button that leads to it. In "answer", write a short, direct reply to the user using facts from the page (for example the available times). If the task isn't achieved, say briefly what was found and what's missing. Never make up information that isn't on the page.
    """

    static let verdictSchema: [String: Any] = [
        "type": "object",
        "properties": ["achieved": ["type": "boolean"], "answer": ["type": "string"]],
        "required": ["achieved", "answer"],
        "additionalProperties": false,
    ]

    // MARK: - Jev input

    static func state(task: String, plan: [String], goalText: String,
                      history: [String], tabs: String, page: PageSnapshot) -> String {
        var lines = ["Task: \(task)", "Plan:"] + plan.enumerated().map { "\($0.offset + 1). \($0.element)" }
        if !goalText.isEmpty { lines.append("Next text to type from the plan: \"\(goalText)\"") }
        lines.append("Everything done so far, in order:")
        lines += history.suffix(40).map { "- \($0)" }
        if tabs.contains("\n") { lines += ["", "Open tabs:", tabs] }
        lines.append("")
        lines.append("Page: \(page.title) (\(page.url))")
        lines.append(page.elementList)
        if !page.text.isEmpty { lines += ["", "Text visible on screen:", page.text] }
        return lines.joined(separator: "\n")
    }

    /// Picking a website from search results is an open judgment call, so it goes to Claude instead of Jev.
    static func isSearchResults(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host() else { return false }
        let engines = ["google.", "bing.com", "duckduckgo.com", "search.yahoo.", "ecosia.org", "startpage.com"]
        guard engines.contains(where: { host.contains($0) }) else { return false }
        if host.contains("duckduckgo.com") { return (u.path == "/" || u.path == "/html") && u.query?.contains("q=") == true }
        return u.path == "/search" || u.path.hasPrefix("/search/")
    }

    static let searchResultsHint = """
    This is a search results page, and the list includes every result on it, also those further down. Pick the business's or person's own website: check the exact name and place, and look at where each link goes (its domain usually contains the business name, like kapsalonwillempeursum.nl). Marketplaces and directories (Fresha, Treatwell, Yelp, 1Kapper, Booksy and similar) are only a fallback when no own website is listed. Don't pick map previews or ads.
    """

    static let textRoles: Set<String> = ["textbox", "searchbox", "email", "tel", "url", "number"]

    /// Every element becomes one option (or two for text fields), plus page-level actions. Jev allows 255.
    static func options(for page: PageSnapshot, goalText: String) -> [(key: String, description: String)] {
        var options: [(key: String, description: String)] = []
        // Image previews (Google's /imgres) are never the right click; the same site has a normal result link.
        for e in page.elements.prefix(110) where !(e.states ?? []).contains("disabled") && e.via != "image preview of" {
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
            ("task_done", "Everything the task asks for is shown on this page right now"),
            ("stuck", "None of these actions helps with the task"),
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
