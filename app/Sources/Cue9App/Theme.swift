import AppKit
import CoreText
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case system
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .system: return nil
        case .dark: return .dark
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Cue9Weight {
    case regular, medium, semibold, bold, black
}

enum Cue9Font {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        var urls: [URL] = []
        for bundle in [Bundle.module, Bundle.main] {
            if let url = bundle.url(forResource: "InterVariable", withExtension: "ttf") {
                urls.append(url)
            }
            if let fontURLs = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
                urls.append(contentsOf: fontURLs)
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("app/Sources/Cue9App/Resources/InterVariable.ttf"))
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ size: CGFloat, _ weight: Cue9Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "InterVariable"
        case .medium: name = "InterVariable-Medium"
        case .semibold: name = "InterVariable-SemiBold"
        case .bold: name = "InterVariable-Bold"
        case .black: name = "InterVariable-Black"
        }
        return .custom(name, size: size)
    }
}

enum Cue9Theme {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let paper = adaptive(light: 0xFAF8F3, dark: 0x0D0D0B)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x151512)
    static let surface2 = adaptive(light: 0xF3F0E8, dark: 0x1D1D18)
    static let ink = adaptive(light: 0x0E0E0C, dark: 0xF7F4EC)
    static let ink2 = adaptive(light: 0x3D3A33, dark: 0xDED9CD)
    static let muted = adaptive(light: 0x6E6A61, dark: 0xB5B0A4)
    static let soft = adaptive(light: 0x746E62, dark: 0x9A9487)
    static let line = adaptive(light: 0xE4E0D7, dark: 0x2A2A24)
    static let lineStrong = adaptive(light: 0xC9C4B8, dark: 0x3D3D34)
    static let orange = adaptive(light: 0xFF6A00, dark: 0xFF7A1A)
    static let orangeSoft = adaptive(light: 0xFFF1E6, dark: 0x2A1A0C)
    static let success = adaptive(light: 0x2E7D5B, dark: 0x6CC79B)
    static let warning = adaptive(light: 0xA66A12, dark: 0xE0B16A)
    static let danger = adaptive(light: 0xC2412D, dark: 0xF08A78)
    static let info = adaptive(light: 0x2F6BFF, dark: 0x7DA0FF)

    static let orangeInk = Color(hex: 0x0E0E0C)
    static let infoInk = adaptive(light: 0xFFFFFF, dark: 0x0E0E0C)
    static let stage = Color(hex: 0x000909)
    static let onStage = Color(hex: 0xDED9CD)
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: Cue9Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cue9Theme.radius, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Cue9Theme.muted)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Cue9Theme.muted

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(Cue9Font.font(11, .medium))
                .foregroundStyle(Cue9Theme.ink2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }
}

struct Cue9TextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(Cue9Font.font(13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: Cue9Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cue9Theme.radiusSmall, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
    }
}

struct WindowAppearanceSetter: NSViewRepresentable {
    let appearance: AppearanceMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let nsAppearance = appearance.nsAppearance
            window.appearance = nsAppearance
            window.contentView?.appearance = nsAppearance
        }
    }
}
