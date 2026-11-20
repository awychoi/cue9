import AppKit
import SwiftUI

struct PreviewSurface: NSViewRepresentable {
    let preview: PreviewEngine

    func makeNSView(context: Context) -> PreviewImageView {
        let view = PreviewImageView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        view.setImage(preview.image)
        preview.frameHandler = { [weak view] image in
            view?.setImage(image)
        }
        return view
    }

    func updateNSView(_ nsView: PreviewImageView, context: Context) {
        if nsView.image == nil { nsView.setImage(preview.image) }
    }

    static func dismantleNSView(_ nsView: PreviewImageView, coordinator: ()) {
        // Leave the handler in place only while this view is alive.
        nsView.image = nil
    }
}

final class PreviewImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleAxesIndependently
        animates = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ cgImage: CGImage?) {
        guard let cgImage else {
            image = nil
            return
        }
        let next = NSImage(cgImage: cgImage, size: NSSize(width: 360, height: 360))
        if image !== next {
            image = next
        }
    }
}
