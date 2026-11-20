import AppKit
import Combine
import Cue9Preview
import Foundation
import SwiftUI

struct RGB: Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var hex: String { String(format: "%02x%02x%02x", r, g, b) }
}

final class PreviewEngine: ObservableObject {
    @Published private(set) var image: CGImage?
    var frameHandler: ((CGImage) -> Void)?

    private let queue = DispatchQueue(label: "cue9.preview", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var context: OpaquePointer?
    private var pixels: UnsafeMutablePointer<UInt16>?
    private var time: Float = 0
    private var sequenceSeconds: Float = 6
    private var state: Int = 0
    private var ink: RGB = CueCatalog.defaultColor(for: "idle")
    private var background: RGB = CueCatalog.defaultBackground
    private var playing = true
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var needsFrame = true
    private var motionObserver: NSObjectProtocol?

    init() {
        context = cue9_preview_create(1)
        pixels = .allocate(capacity: 360 * 360)
        pixels?.initialize(repeating: 0, count: 360 * 360)
        motionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.needsFrame = true
            }
        }
        start()
    }

    deinit {
        timer?.cancel()
        if let motionObserver {
            NotificationCenter.default.removeObserver(motionObserver)
        }
        pixels?.deallocate()
        cue9_preview_destroy(context)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func configure(state: Int, ink: RGB, background: RGB, reset: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.state = state
            self.ink = ink
            self.background = background
            self.sequenceSeconds = Self.duration(for: state)
            if reset {
                cue9_preview_reset(self.context)
                self.time = self.reduceMotion ? 0.9 : 0
            }
            self.needsFrame = true
            if !self.playing || self.reduceMotion { self.tick() }
        }
    }

    /// The three typing takes are 5 s; every other scene stays 6 s.
    private static func duration(for state: Int) -> Float {
        switch state {
        case 0, 15, 16: return 5
        default: return 6
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [weak self] in self?.playing = playing }
    }

    private func tick() {
        guard playing, let context, let pixels else { return }
        // With Reduce Motion on, render once per state/colour change instead
        // of running the 30 fps loop.
        if reduceMotion && !needsFrame { return }
        needsFrame = false
        /* The device receives REFRESH at the end of the animation's sequence
         * (the three typing takes 5 s, everything else 6 s). The preview has to
         * do the same or the blink phase keeps accumulating and flickers. */
        if sequenceSeconds > 0 && time >= sequenceSeconds {
            cue9_preview_reset(context)
            time = 0
        }
        let dt: Float = 1.0 / 30.0
        var inkValue = cue9_rgb(r: ink.r, g: ink.g, b: ink.b)
        var backgroundValue = cue9_rgb(r: background.r, g: background.g, b: background.b)
        let rc: Int32 = withUnsafePointer(to: &inkValue) { inkPointer in
            withUnsafePointer(to: &backgroundValue) { backgroundPointer in
                cue9_preview_render(
                    context, Int32(state), time, dt,
                    inkPointer, backgroundPointer,
                    pixels, Int32(360 * 360)
                )
            }
        }
        guard rc == 0 else { return }
        time += dt

        var rgba = [UInt8](repeating: 0, count: 360 * 360 * 4)
        for i in 0..<(360 * 360) {
            let c = pixels[i]
            let r = UInt8((c >> 11) & 0x1F)
            let g = UInt8((c >> 5) & 0x3F)
            let b = UInt8(c & 0x1F)
            rgba[i * 4 + 0] = (r << 3) | (r >> 2)
            rgba[i * 4 + 1] = (g << 2) | (g >> 4)
            rgba[i * 4 + 2] = (b << 3) | (b >> 2)
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return }
        let cg = CGImage(
            width: 360, height: 360,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 360 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
        if let cg {
            DispatchQueue.main.async { [weak self] in
                self?.image = cg
                self?.frameHandler?(cg)
            }
        }
    }
}
