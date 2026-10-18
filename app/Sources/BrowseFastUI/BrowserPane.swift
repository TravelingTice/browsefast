import SwiftUI

struct BrowserPane: View {
    var onPick: (String) -> Void

    var body: some View {
        ZStack {
            Theme.inkDeep
            Starfield()
            RadialGradient(colors: [Theme.violet.opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: 420)
                .offset(y: -40)
            RadialGradient(colors: [Theme.violetLight.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)

            VStack(spacing: 0) {
                LogoMark()
                    .frame(width: 96, height: 96)
                    .shadow(color: Theme.violet.opacity(0.7), radius: 40)
                    .shadow(color: Theme.violetLight.opacity(0.25), radius: 12)
                    .padding(.bottom, 36)

                Text("Type what you want to do on the web")
                    .font(Theme.figtree(30, weight: 700))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .padding(.bottom, 18)

                SuggestionTicker(onPick: onPick)
            }
            .offset(y: -20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

struct SuggestionTicker: View {
    var onPick: (String) -> Void
    @State private var index = 0

    static let suggestions = [
        "Find the cheapest flights from Amsterdam to Lisbon in May",
        "Book a haircut at a barbershop near me this Saturday",
        "Compare which project management software is best for a team of 10",
        "Order my usual groceries for delivery tomorrow morning",
        "Find a highly rated Italian restaurant and reserve a table for two",
        "Cancel my unused subscriptions",
        "Summarize the reviews of the Sony WH-1000XM6",
        "Fill in my tax return details from last year",
    ]

    var body: some View {
        Button { onPick(Self.suggestions[index]) } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.violetLight)
                ZStack {
                    Text(Self.suggestions[index] + "…")
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
                .frame(height: 22)
                .clipped()
            }
            .font(Theme.figtree(16, weight: 500))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.035)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                withAnimation(.smooth(duration: 0.6)) {
                    index = (index + 1) % Self.suggestions.count
                }
            }
        }
    }
}

struct Starfield: View {
    private struct Star { var x, y, size, base, speed, phase: Double }

    private let stars: [Star] = {
        var rng = SeededRandom(seed: 7)
        return (0..<140).map { _ in
            Star(x: rng.next(), y: rng.next(),
                 size: 0.6 + rng.next() * 1.3,
                 base: 0.12 + rng.next() * 0.45,
                 speed: 0.4 + rng.next() * 1.2,
                 phase: rng.next() * .pi * 2)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for s in stars {
                    let twinkle = 0.65 + 0.35 * sin(t * s.speed + s.phase)
                    let rect = CGRect(x: s.x * size.width, y: s.y * size.height, width: s.size, height: s.size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(s.base * twinkle)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
