import SwiftUI

struct AgentPanel: View {
    @Binding var draft: String
    var enabled: Bool
    var run: AgentRun
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composer
                .padding(14)

            Rectangle().fill(Theme.line).frame(height: 1)

            if !enabled {
                Spacer()
            } else if let task = run.task {
                timeline(task)
            } else {
                emptyState
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .task(id: enabled) {
            // Also runs on first appear, before the window is key, hence the short wait.
            guard enabled else { return }
            try? await Task.sleep(for: .milliseconds(300))
            focused = true
        }
    }

    private var canSend: Bool {
        enabled && !run.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(enabled ? "Ask BrowseFast to do anything…" : "Add your API keys to start", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.figtree(15, weight: 500))
                .foregroundStyle(.white)
                .tint(Theme.violetLight)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 5)
                .disabled(!enabled)

            if run.isRunning {
                Button(action: run.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .help("Stop the task")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Theme.ink : Theme.muted.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? Theme.violetLight : Theme.surfaceHigh))
                        .animation(.easeOut(duration: 0.15), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Theme.violetLight.opacity(0.55) : Theme.line, lineWidth: 1)
        )
        .shadow(color: focused ? Theme.violet.opacity(0.35) : .clear, radius: 14)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.easeOut(duration: 0.3), value: enabled)
    }

    private func timeline(_ task: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task)
                        .font(Theme.figtree(14, weight: 500))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceHigh))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.bottom, 12)

                    ForEach(run.steps) { step in
                        StepRow(step: step)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let question = run.question {
                        QuestionCard(question: question, answer: run.choose)
                            .padding(.top, 10)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let answer = run.answer {
                        ResultCard(answer: answer)
                            .padding(.top, 10)
                            .transition(.opacity)
                    }

                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
                .animation(.smooth(duration: 0.25), value: run.steps.count)
                .animation(.smooth(duration: 0.25), value: run.answer)
                .animation(.smooth(duration: 0.25), value: run.question?.id)
            }
            .onChange(of: run.steps.count) { withAnimation { proxy.scrollTo("end") } }
            .onChange(of: run.question?.id) { withAnimation { proxy.scrollTo("end") } }
            .onChange(of: run.answer) { withAnimation { proxy.scrollTo("end") } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.violetLight.opacity(0.8))
            Text("Your agent's steps will show up here")
                .font(Theme.figtree(14, weight: 600))
                .foregroundStyle(.white.opacity(0.85))
            Text("Describe a task and BrowseFast will do it on the web for you.")
                .font(Theme.figtree(13, weight: 500))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        guard canSend else { return }
        run.start(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        draft = ""
    }
}

private struct StepRow: View {
    let step: AgentRun.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DeciderIcon(decider: step.decider)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.text)
                    .font(Theme.figtree(13.5, weight: 500))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = step.detail {
                    Text(detail)
                        .font(Theme.figtree(12.5, weight: 500))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if step.status == .running {
                ProgressView().controlSize(.mini).tint(Theme.violetLight)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(step.status == .blocked ? Theme.violet.opacity(0.12) : .clear)
        )
    }

    private var textColor: Color {
        switch step.status {
        case .running: Theme.muted
        case .failed: Theme.danger
        case .done, .blocked: .white.opacity(0.92)
        }
    }
}

struct DeciderIcon: View {
    let decider: AgentRun.Decider

    var body: some View {
        Group {
            switch decider {
            case .claude: Image(bundled: "claude").resizable().interpolation(.high)
            case .jev: Image(bundled: "typesafe").resizable().interpolation(.high)
            case .browseFast: LogoMark()
            case .you:
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 16, height: 16)
        .help(help)
    }

    private var help: String {
        switch decider {
        case .claude: "Decided by Claude Haiku"
        case .jev: "Decided by Jev"
        case .browseFast: "BrowseFast"
        case .you: "Your choice"
        }
    }
}

private struct QuestionCard: View {
    let question: AgentRun.Question
    let answer: (AgentRun.Question.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 11, weight: .bold))
                Text("Your choice").font(Theme.figtree(12, weight: 700))
            }
            .foregroundStyle(Theme.violetLight)

            Text(question.text)
                .font(Theme.figtree(14.5, weight: 600))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(question.choices) { choice in
                    ChoiceButton(label: choice.label) { answer(choice) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.violetLight.opacity(0.45), lineWidth: 1))
        .shadow(color: Theme.violet.opacity(0.3), radius: 16)
    }
}

private struct ChoiceButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.figtree(13, weight: 600))
                .foregroundStyle(hovering ? Theme.ink : .white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Theme.violetLight : Theme.surfaceHigh))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.violetLight.opacity(hovering ? 0 : 0.35), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ResultCard: View {
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .bold))
                Text("Result").font(Theme.figtree(12, weight: 700))
            }
            .foregroundStyle(Theme.violetLight)
            Text(answer)
                .font(Theme.figtree(14, weight: 500))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.violet.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.violetLight.opacity(0.35), lineWidth: 1))
    }
}
