import SwiftUI
import CoreText

public enum Theme {
    static let violetLight = Color(hex: 0x9B74FF)
    static let violet = Color(hex: 0x5201FC)
    static let ink = Color(hex: 0x0B0B12)
    static let inkDeep = Color(hex: 0x07070C)
    static let surface = Color(hex: 0x15151F)
    static let surfaceHigh = Color(hex: 0x1D1D2A)
    static let line = Color(hex: 0x24243A)
    static let muted = Color(hex: 0x9A9AB0)
    static let danger = Color(hex: 0xFF6B81)

    public static func registerFonts() {
        for name in ["Figtree", "Figtree-Italic"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // Figtree ships as a variable font, so weight is set on the 'wght' axis directly.
    static func figtree(_ size: CGFloat, weight: CGFloat = 500, italic: Bool = false) -> Font {
        let wghtAxis = 0x77676874
        var descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Figtree",
            .variation: [NSFontDescriptor.AttributeName(rawValue: String(wghtAxis)): weight] as Any,
        ])
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        let font = NSFont(descriptor: descriptor, size: size)
            .map { NSFont(descriptor: $0.fontDescriptor.addingAttributes([.variation: [wghtAxis: weight]]), size: size) ?? $0 }
        return font.map(Font.init) ?? .system(size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct LogoMark: View {
    var color: Color = Theme.violetLight

    var body: some View {
        Image(nsImage: NSImage(contentsOf: Bundle.module.url(forResource: "logo", withExtension: "png")!)!)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
    }
}
