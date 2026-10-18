import SwiftUI

struct AgentPanel: View {
    @Binding var draft: String
    var enabled: Bool
    @State private var messages: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composer
                .padding(14)

            Rectangle().fill(Theme.line).frame(height: 1)

            if !enabled {
                Spacer()
            } else if messages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .trailing, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .font(Theme.figtree(14, weight: 500))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceHigh))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(14)
                }
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

    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        withAnimation(.smooth(duration: 0.3)) {
            messages.append(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        draft = ""
    }
}
