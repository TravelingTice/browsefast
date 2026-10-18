import SwiftUI

struct SetupView: View {
    @Binding var claudeKey: String
    @Binding var typesafeKey: String
    var onStart: () -> Void

    @FocusState private var focus: SetupField?
    @State private var checking = false
    @State private var claudeError: String?
    @State private var typesafeError: String?

    private var keysFilled: Bool {
        !claudeKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !typesafeKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var canStart: Bool { keysFilled && !checking }

    var body: some View {
        VStack(spacing: 0) {
            LogoMark()
                .frame(width: 64, height: 64)
                .shadow(color: Theme.violet.opacity(0.7), radius: 30)
                .padding(.bottom, 28)

            Text("Set up BrowseFast")
                .font(Theme.figtree(30, weight: 700))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            Text("BrowseFast is free and open source. Add your own API keys to get started. They're stored securely in your Mac's Keychain.")
                .font(Theme.figtree(15, weight: 500))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.bottom, 32)

            VStack(spacing: 18) {
                KeyField(
                    title: "Claude API key",
                    link: ("Get a key", URL(string: "https://platform.claude.com/settings/keys")!),
                    placeholder: "Paste your Claude key",
                    text: $claudeKey,
                    field: .claude,
                    focus: $focus,
                    error: claudeError
                ) {
                    Image(bundled: "claude")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                .onSubmit { focus = .typesafe }

                KeyField(title: "TypeSafe API key",
                         link: ("Get a key", URL(string: "https://console.typesafe.ai")!),
                         placeholder: "Paste your TypeSafe key",
                         text: $typesafeKey, field: .typesafe, focus: $focus,
                         error: typesafeError) {
                    Image(bundled: "typesafe")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                }
                .onSubmit(start)

                Button(action: start) {
                    HStack(spacing: 8) {
                        if checking {
                            ProgressView().controlSize(.small).tint(Theme.ink)
                        }
                        Text(checking ? "Checking keys…" : "Start")
                    }
                        .font(Theme.figtree(16, weight: 700))
                        .foregroundStyle(keysFilled ? Theme.ink : Theme.muted.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(keysFilled ? Theme.violetLight : Theme.surfaceHigh)
                        )
                        .shadow(color: keysFilled ? Theme.violet.opacity(0.55) : .clear, radius: 18)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .animation(.easeOut(duration: 0.2), value: keysFilled)
                .padding(.top, 8)
            }
            .frame(width: 420)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            focus = .claude
        }
        .onChange(of: claudeKey) { claudeError = nil }
        .onChange(of: typesafeKey) { typesafeError = nil }
    }

    private func start() {
        guard canStart else { return }
        checking = true
        Log.write("keys", "Checking API keys with Anthropic and TypeSafe")
        Task {
            async let claude = KeyValidator.checkClaude(claudeKey.trimmingCharacters(in: .whitespaces))
            async let typesafe = KeyValidator.checkTypeSafe(typesafeKey.trimmingCharacters(in: .whitespaces))
            let (c, t) = await (claude, typesafe)
            Log.write("keys", c.map { "Claude key rejected: \($0)" } ?? "Claude key accepted")
            Log.write("keys", t.map { "TypeSafe key rejected: \($0)" } ?? "TypeSafe key accepted")
            checking = false
            withAnimation(.easeOut(duration: 0.2)) {
                claudeError = c
                typesafeError = t
            }
            if c == nil && t == nil {
                onStart()
            } else {
                focus = c != nil ? .claude : .typesafe
            }
        }
    }
}

private enum SetupField { case claude, typesafe }

private struct KeyField<Icon: View>: View {
    let title: String
    let link: (String, URL)?
    let placeholder: String
    @Binding var text: String
    let field: SetupField
    var focus: FocusState<SetupField?>.Binding
    var error: String?
    @ViewBuilder var icon: Icon

    private var focused: Bool { focus.wrappedValue == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(Theme.figtree(13, weight: 600))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if let link {
                    Link(destination: link.1) {
                        HStack(spacing: 3) {
                            Text(link.0)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                        }
                        .font(Theme.figtree(13, weight: 600))
                        .foregroundStyle(Theme.violetLight)
                    }
                    .focusable(false)
                }
            }

            HStack(spacing: 12) {
                icon
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.figtree(15, weight: 500))
                    .foregroundStyle(.white)
                    .tint(Theme.violetLight)
                    .focused(focus, equals: field)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.2), value: focused)

            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(error)
                        .font(Theme.figtree(13, weight: 500))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.danger)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var borderColor: Color {
        if error != nil { return Theme.danger.opacity(0.8) }
        return focused ? Theme.violetLight.opacity(0.55) : Theme.line
    }
}
