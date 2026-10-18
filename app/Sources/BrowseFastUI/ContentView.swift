import SwiftUI

public struct ContentView: View {
    @State private var draft = ""
    @State private var claudeKey = KeyStore.read(.claude) ?? ""
    @State private var typesafeKey = KeyStore.read(.typesafe) ?? ""
    @State private var started = KeyStore.read(.claude) != nil && KeyStore.read(.typesafe) != nil
    @State private var run = TaskRun()

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            BrowserPane {
                if run.task != nil {
                    BrowserView(tabs: run.browser.tabs, activeID: run.browser.activeID)
                        .transition(.opacity)
                } else if started {
                    IntroView { draft = $0 }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    SetupView(claudeKey: $claudeKey, typesafeKey: $typesafeKey, onStart: start)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
            }
            AgentPanel(draft: $draft, enabled: started, run: run)
                .frame(width: 380)
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 38)
        .overlay(alignment: .topLeading) {
            // Sits in the title bar strip, right of the traffic lights.
            TabBar(browser: run.browser, run: run)
                .frame(height: 38)
                .padding(.leading, 84)
        }
        .background(Theme.ink)
        .ignoresSafeArea()
        .onAppear {
            Log.write("setup", started ? "Saved keys found in the Keychain, skipping setup" : "No saved keys, showing setup screen")
        }
    }

    private func start() {
        let saved = KeyStore.save(claudeKey.trimmingCharacters(in: .whitespaces), for: .claude)
            && KeyStore.save(typesafeKey.trimmingCharacters(in: .whitespaces), for: .typesafe)
        Log.write("keys", saved ? "Both keys saved to the Keychain" : "Saving keys to the Keychain failed")
        withAnimation(.smooth(duration: 0.5)) { started = true }
    }
}

#Preview(traits: .fixedLayout(width: 1440, height: 900)) {
    let _ = Theme.registerFonts()
    ContentView().preferredColorScheme(.dark)
}
