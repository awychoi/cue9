import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static func write(model: AppModel, section: AppSection, appearance: AppearanceMode, to path: String) {
        Cue9Font.register()

        let defaults = UserDefaults.standard
        let previousAppearance = defaults.string(forKey: "appearance")
        defaults.set(appearance.rawValue, forKey: "appearance")
        defer {
            if let previousAppearance {
                defaults.set(previousAppearance, forKey: "appearance")
            } else {
                defaults.removeObject(forKey: "appearance")
            }
        }

        let view = RootView(model: model, initialSection: section)
            .frame(width: 1280, height: 800)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hosting.appearance = appearance.nsAppearance ?? NSApp.effectiveAppearance
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

