import SwiftUI

public struct ContentView: View {
    @State private var draft = ""

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            BrowserPane { draft = $0 }
            AgentPanel(draft: $draft)
                .frame(width: 380)
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 38)
        .background(Theme.ink)
        .ignoresSafeArea()
    }
}

#Preview(traits: .fixedLayout(width: 1440, height: 900)) {
    let _ = Theme.registerFonts()
    ContentView().preferredColorScheme(.dark)
}
