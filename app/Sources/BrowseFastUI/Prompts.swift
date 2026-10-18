import Foundation

/// Everything the models are told, in one place.
enum Prompts {
    static let planner = """
    You plan tasks for BrowseFast, an AI browser agent that controls a real web browser. Fast models carry out the plan by clicking and typing on pages, so goals must be concrete and visible on screen.

    First decide whether the task needs one website or several in parallel ("parallel"). Use several (2 to 4) when the task asks to research or compare multiple websites, or when comparing sites clearly helps (like prices, flights or availability). Otherwise use one.

    Return:
    - parallel: true when several sites should be researched at the same time.
    - sources: one entry per site (exactly one when not parallel, at most 4). For each:
      - name: a short site name, like "Google Flights" or "Skyscanner".
      - start_url: where to begin. For a single site where you don't know the exact website, use https://www.google.com/?hl=en and start with a search. For parallel research, use each site's own homepage or search page.
      - instruction: what to do on that site, phrased for that site.
      - goals: 2 to 6 short goals in order. Put the exact text to type for a goal in "text" (for example a search query or a city), or "" when it needs no typing. When the plan starts with a web search, always give the search phrase: just the names and place from the task (like "Kapsalon Willem Peursum Rijnsburg"), without extra words such as "availability" or "times".
    - questions: only for parallel tasks, questions every site would need answered that the task doesn't settle (for example one-way or return, or the number of passengers), each with up to 6 short choices. Set "allow_text" to true when the user may want to type their own answer, with an example in "placeholder" (otherwise false and ""). Leave the list empty if the task settles everything, and never ask what the task already says.
      When the task names a period instead of a date (like "in November" or "next week"), always ask which date, with the first choice "Every day in <period> (find the cheapest)" and allow_text true with a placeholder like "e.g. 15 November".

    BrowseFast is read-only for now: it must never book, buy, pay, subscribe or submit personal details. Plan only up to the point where the information the user wants is visible on screen.
    """

    static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "parallel": ["type": "boolean"],
            "questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "question": ["type": "string"],
                        "choices": ["type": "array", "items": ["type": "string"]],
                        "allow_text": ["type": "boolean"],
                        "placeholder": ["type": "string"],
                    ],
                    "required": ["question", "choices", "allow_text", "placeholder"],
                    "additionalProperties": false,
                ],
            ],
            "sources": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "start_url": ["type": "string"],
                        "instruction": ["type": "string"],
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
                    "required": ["name", "start_url", "instruction", "goals"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["parallel", "questions", "sources"],
        "additionalProperties": false,
    ]

    static let comparer = """
    Several BrowseFast agents researched the same task on different websites. Combine their findings into one short answer for the user.
    Lead with the best option (for example the cheapest matching flight: price, date, airline and which site), then list what each site found in one line each. Mention sites that failed and why, briefly. Only use facts from the findings; never make anything up.
    """

    static let comparisonSchema: [String: Any] = [
        "type": "object",
        "properties": ["answer": ["type": "string"]],
        "required": ["answer"],
        "additionalProperties": false,
    ]

    static let jevInstructions = "Which single action moves the browser closest to finishing the task, following the plan? Only pick results for the exact business or person named in the task; a similar name is a different one. If the page asks for a choice the task already settles (for example the person or date it names), pick that option. If the page needs a choice the task and the user's choices don't settle (like a service, gender, a date or a time), choose ask_user. Apply the user's earlier choices yourself (for example select one-way if they chose one-way) and never ask to confirm them. A calendar or date grid that shows a price under each date counts as showing the prices for that period. If the user wants every day in a period checked, use the site's month view, price calendar or flexible-dates option rather than a single date. Never reopen or redo a choice that is already made (it shows on the page or in the user's choices); in a step-by-step booking flow, move to the next step instead of going back to an earlier one. Choose task_done only when the information the task asks for is shown on this page."

    static let decider = """
    You choose the next browser action for BrowseFast when its fast model is unsure. You get the task, the plan, what was done so far, and the interactive elements on the page. Pick exactly one option key from the list.
    If the option types text, put the exact text in "text", otherwise "". Give a one-sentence reason.
    Names in the task must match exactly: a business or person with a similar name (for example a different first name) is a different one.
    If the task or the user's choices already settle a choice on the page (for example a person or date named in the task, or one-way when the user chose one-way), pick that option directly. Never ask the user to confirm something they already chose.
    A calendar or date grid that shows a price under each date counts as showing the prices for that period. If the user wants every day in a period checked, use the site's month view, price calendar or flexible-dates option; if the site has none, check a few dates spread over the period.
    If the page needs a choice that the task and the user's choices so far don't settle (like a service, a person, gender, a date or a time), pick ask_user instead of guessing.
    Never reopen or redo a choice that is already made (it shows on the page, or is in the user's choices or the history). In a step-by-step flow such as a booking wizard, move to the next step instead of going back to an earlier one or to the start.
    Never pick an action that books, buys, pays or submits personal details.
    """

    static let asker = """
    BrowseFast needs the user to make a choice on this page. Ask for the missing information itself (like which date, which service or which stylist), never about what BrowseFast should do next: "How should I proceed?" or "Should I continue?" are not allowed.
    Set "allow_text" to true when the answer may not be one of the buttons (a date, a number, a name, a place) and give an example in "placeholder"; otherwise false and "". With allow_text you may return no choices. Check the history and the user's choices first: don't ask about something that is already decided, and never ask the user to confirm an earlier choice. When the page shows options to choose from that the user hasn't picked yet (like the specific treatments inside a category they chose), always return those options. Write one short, friendly question and the choices to answer it, taken from the clickable options listed. Use each option's key exactly.
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
                "allow_text": ["type": "boolean"],
                "placeholder": ["type": "string"],
            ],
            "required": ["question", "choices", "allow_text", "placeholder"],
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
    Only report options that meet the task's conditions (for example direct flights only, or a date range); if the page doesn't show whether an option meets a condition, say so instead of assuming. Prices shown in a calendar or date grid count as found. When every day of a period was asked for, say which day is cheapest and whether the whole period was covered or only some dates.
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
        for e in page.elements.prefix(110) where !(e.states ?? []).contains("disabled") {
            // Image results lead to Google's image viewer; open the site behind them directly instead.
            // Sometimes they're the only result for a business's own website, so they must stay available.
            if e.via == "image preview of", let target = e.target {
                options.append(("open_\(e.id)", "Open \(target) (the website behind the image result \"\(e.label)\")"))
                continue
            }
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
