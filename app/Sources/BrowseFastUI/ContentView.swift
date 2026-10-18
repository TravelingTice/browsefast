import SwiftUI

public struct ContentView: View {
    @State private var draft = ""
    @State private var claudeKey = KeyStore.read(.claude) ?? ""
    @State private var typesafeKey = KeyStore.read(.typesafe) ?? ""
    @State private var started = KeyStore.read(.claude) != nil && KeyStore.read(.typesafe) != nil

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            BrowserPane {
                if started {
                    IntroView { draft = $0 }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    SetupView(claudeKey: $claudeKey, typesafeKey: $typesafeKey, onStart: start)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
            }
            AgentPanel(draft: $draft, enabled: started)
                .frame(width: 380)
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 38)
        .background(Theme.ink)
        .ignoresSafeArea()
    }

    private func start() {
        KeyStore.save(claudeKey.trimmingCharacters(in: .whitespaces), for: .claude)
        KeyStore.save(typesafeKey.trimmingCharacters(in: .whitespaces), for: .typesafe)
        withAnimation(.smooth(duration: 0.5)) { started = true }
    }
}

#Preview(traits: .fixedLayout(width: 1440, height: 900)) {
    let _ = Theme.registerFonts()
    ContentView().preferredColorScheme(.dark)
}
