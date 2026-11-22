import Foundation
import SwiftUI

struct CueAnimation: Identifiable, Hashable {
    let id: String
    let label: String
    let color: RGB
    /// Sensor-triggered faces: previewable and colourable, never mapped.
    var deviceOnly: Bool = false
}

struct CueAction: Identifiable, Hashable {
    let id: String
    let label: String
    let defaultMap: [String]
}

struct CueEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let action: String
    let animation: String
    let date: Date

    init(id: UUID = UUID(), action: String, animation: String, date: Date = Date()) {
        self.id = id
        self.action = action
        self.animation = animation
        self.date = date
    }

    /// Compact age for the small live lists: now, 13m, 2h, 1d.
    var ageText: String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

enum CueCatalog {
    /// The C++ preview renderer's fixed state order. Actions and their labels
    /// come from the plugin; this only says which scenes the app can draw.
    static let rendererOrder = [
        "work", "idle", "curious", "thinking", "search", "read", "wait",
        "sleep", "wake", "approval", "mcq", "retry", "done", "offline", "hub",
        "workCrazy", "workAnnoyed", "dizzy", "toolCall", "runCmd", "stroked",
    ]

    static let animationColors: [String: RGB] = [
        "work": RGB(r: 100, g: 224, b: 236),
        "idle": RGB(r: 144, g: 223, b: 209),
        "curious": RGB(r: 189, g: 164, b: 245),
        "thinking": RGB(r: 152, g: 183, b: 243),
        "search": RGB(r: 121, g: 222, b: 208),
        "read": RGB(r: 161, g: 213, b: 233),
        "wait": RGB(r: 228, g: 187, b: 122),
        "sleep": RGB(r: 144, g: 158, b: 220),
        "wake": RGB(r: 242, g: 209, b: 143),
        "approval": RGB(r: 241, g: 189, b: 104),
        "mcq": RGB(r: 173, g: 188, b: 255),
        "retry": RGB(r: 238, g: 169, b: 141),
        "done": RGB(r: 165, g: 230, b: 155),
        "offline": RGB(r: 147, g: 165, b: 177),
        "hub": RGB(r: 241, g: 183, b: 128),
        "workCrazy": RGB(r: 100, g: 224, b: 236),
        "workAnnoyed": RGB(r: 100, g: 224, b: 236),
        "dizzy": RGB(r: 230, g: 168, b: 245),
        "toolCall": RGB(r: 122, g: 216, b: 245),
        "runCmd": RGB(r: 126, g: 240, b: 181),
        "stroked": RGB(r: 255, g: 158, b: 199),
    ]

    static let defaultBackground = RGB(r: 5, g: 10, b: 14)

    static func stateIndex(_ id: String) -> Int {
        rendererOrder.firstIndex(of: id) ?? 0
    }

    static func isRenderable(_ id: String) -> Bool {
        rendererOrder.contains(id)
    }

    static func defaultColor(for id: String) -> RGB {
        animationColors[id] ?? RGB(r: 147, g: 165, b: 177)
    }

    static var defaultPalette: [String: RGB] {
        animationColors
    }
}

extension RGB {
    var swiftUIColor: Color { color }
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: UInt8((ns.redComponent * 255).rounded()),
            g: UInt8((ns.greenComponent * 255).rounded()),
            b: UInt8((ns.blueComponent * 255).rounded())
        )
    }
}

enum CuePaths {
    static var support: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/cue9", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var mapping: URL { support.appendingPathComponent("mapping.json") }
    /// App-owned colour store. The plugin's palette.json/backgrounds.json are
    /// only a mirror it keeps for the firmware.
    static var palette: URL { support.appendingPathComponent("colours.json") }
    static var paletteBackup: URL { support.appendingPathComponent("colours.backup.json") }
    static var backgrounds: URL { support.appendingPathComponent("colour-backgrounds.json") }
    static var backgroundsBackup: URL { support.appendingPathComponent("colour-backgrounds.backup.json") }
    static var legacyPalette: URL { support.appendingPathComponent("palette.json") }
    static var legacyBackgrounds: URL { support.appendingPathComponent("backgrounds.json") }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var catalog: URL { support.appendingPathComponent("catalog.json") }
    static var piSummary: URL { support.appendingPathComponent("pi.json") }
    static var dshPort: URL { support.appendingPathComponent("dsh.json") }

    static var firmware: URL? {
        Bundle.module.url(forResource: "firmware", withExtension: "bin")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("renderer/out/device/pip_live-te.bin")
    }
}

enum ShellFinish: String, CaseIterable, Identifiable {
    case white
    case charcoal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Warm white"
        case .charcoal: return "Charcoal"
        }
    }

    var assetName: String {
        switch self {
        case .white: return "cat-shell-white"
        case .charcoal: return "cat-shell-charcoal"
        }
    }

    var swatch: Color {
        switch self {
        case .white: return Color(hex: 0xF3EEE4)
        case .charcoal: return Color(hex: 0x3D4145)
        }
    }
}

struct ColourPreset: Identifiable, Hashable {
    let name: String
    let hex: UInt32

    var id: UInt32 { hex }
    var color: Color { Color(hex: hex) }
    var rgb: RGB { RGB(color: color) }
}

extension CueCatalog {
    /// Small, explicit palette for the colour editor. Kept to 15 so it
    /// reflows into three rows when the inspector gets tight.
    static let colourPresets: [ColourPreset] = [
        ColourPreset(name: "Chalk", hex: 0xF7F4EC),
        ColourPreset(name: "Ink", hex: 0x11110F),
        ColourPreset(name: "Orange", hex: 0xFF6A00),
        ColourPreset(name: "Apricot", hex: 0xF2B880),
        ColourPreset(name: "Coral", hex: 0xF26B5E),
        ColourPreset(name: "Rose", hex: 0xFF7D9A),
        ColourPreset(name: "Magenta", hex: 0xD95CF0),
        ColourPreset(name: "Violet", hex: 0xB9A3FF),
        ColourPreset(name: "Indigo", hex: 0x6062FF),
        ColourPreset(name: "Sky", hex: 0x17B7F3),
        ColourPreset(name: "Cyan", hex: 0x0BE8FF),
        ColourPreset(name: "Teal", hex: 0x2EC4A6),
        ColourPreset(name: "Green", hex: 0x55D66B),
        ColourPreset(name: "Lime", hex: 0xC4E36A),
        ColourPreset(name: "Slate", hex: 0x93A5B1),
    ]
}

enum SaveState: Equatable {
    case idle
    case savedLocally
    case sent
    case pending
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .savedLocally: return "Saved on this Mac"
        case .sent: return "Sent to DSH"
        case .pending: return "Saved · sync pending"
        case .failed: return "Save failed"
        }
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

enum TestState: Equatable {
    case idle
    case sending
    case sent
    case failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .sending: return "Sending to mote…"
        case .sent: return "Shown on mote"
        case .failed(let message): return message
        }
    }
}
