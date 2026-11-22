import AppKit
import Cue9Preview
import Foundation
import SwiftUI

/// Renders one still frame of a face for the galleries and history lists.
/// The live stage still uses `PreviewEngine`; these small stills are only for
/// helping people recognise a face at a glance.
enum FaceThumbnailRenderer {
    private static let lock = NSLock()
    private static var cache: [String: CGImage] = [:]

    /// Synchronous on purpose: these stills are cheap, and the gallery needs
    /// them the moment a tile appears (including in the offscreen snapshot
    /// renderer, where SwiftUI tasks do not run).
    static func image(animation: String, ink: RGB, background: RGB) -> CGImage? {
        let key = "\(animation)-\(ink.hex)-\(background.hex)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        let image = render(animation: animation, ink: ink, background: background)
        if let image {
            lock.lock()
            cache[key] = image
            if cache.count > 160 {
                cache.removeAll(keepingCapacity: true)
            }
            lock.unlock()
        }
        return image
    }

    private static func render(animation: String, ink: RGB, background: RGB) -> CGImage? {
        RendererGate.run {
            guard CueCatalog.isRenderable(animation),
                  let context = cue9_preview_create(1) else { return nil }
            defer { cue9_preview_destroy(context) }

            var inkValue = cue9_rgb(r: ink.r, g: ink.g, b: ink.b)
            var backgroundValue = cue9_rgb(r: background.r, g: background.g, b: background.b)
            var pixels = [UInt16](repeating: 0, count: 360 * 360)
            let state = CueCatalog.stateIndex(animation)

            // A short warm-up gets the first expression past its blink-in. The
            // still is only for recognition; the live stage owns the real motion.
            cue9_preview_reset(context)
            for step in 0..<8 {
                let time = 0.35 + Float(step) / 30
                _ = withUnsafePointer(to: &inkValue) { inkPointer in
                    withUnsafePointer(to: &backgroundValue) { backgroundPointer in
                        cue9_preview_render(
                            context, Int32(state), time, 1.0 / 30,
                            inkPointer, backgroundPointer,
                            &pixels, Int32(360 * 360)
                        )
                    }
                }
            }

            var rgba = [UInt8](repeating: 0, count: 360 * 360 * 4)
            for index in 0..<(360 * 360) {
                let colour = pixels[index]
                let red = UInt8((colour >> 11) & 0x1F)
                let green = UInt8((colour >> 5) & 0x3F)
                let blue = UInt8(colour & 0x1F)
                rgba[index * 4 + 0] = (red << 3) | (red >> 2)
                rgba[index * 4 + 1] = (green << 2) | (green >> 4)
                rgba[index * 4 + 2] = (blue << 3) | (blue >> 2)
                rgba[index * 4 + 3] = 255
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(
                width: 360, height: 360,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 360 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }
}

/// A small round still of a face, tinted with the colours in the app.
struct FaceThumbnailView: View {
    let animation: CueAnimation
    let ink: RGB
    let background: RGB
    var size: CGFloat = 52
    var showsBorder = true

    private let image: CGImage?

    init(
        animation: CueAnimation,
        ink: RGB,
        background: RGB,
        size: CGFloat = 52,
        showsBorder: Bool = true
    ) {
        self.animation = animation
        self.ink = ink
        self.background = background
        self.size = size
        self.showsBorder = showsBorder
        self.image = FaceThumbnailRenderer.image(
            animation: animation.id,
            ink: ink,
            background: background
        )
    }

    var body: some View {
        ZStack {
            Circle().fill(background.color)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: size * 0.30, weight: .medium))
                    .foregroundStyle(ink.color.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if showsBorder {
                Circle().stroke(Cue9Theme.lineStrong, lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Convenience for callers that only have an id. Falls back to the catalogue
/// defaults when the live catalog has not arrived yet.
struct FaceThumb: View {
    @ObservedObject var model: AppModel
    let animation: String
    var size: CGFloat = 46

    private var face: CueAnimation {
        model.animation(for: animation)
            ?? CueAnimation(id: animation, label: model.animationLabel(animation), color: CueCatalog.defaultColor(for: animation))
    }

    private var ink: RGB {
        model.palette[animation] ?? CueCatalog.defaultColor(for: animation)
    }

    private var background: RGB {
        model.backgrounds[animation] ?? CueCatalog.defaultBackground
    }

    var body: some View {
        FaceThumbnailView(animation: face, ink: ink, background: background, size: size)
    }
}
