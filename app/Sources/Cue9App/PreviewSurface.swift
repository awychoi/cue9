import SwiftUI

/// Draws the engine's current frame at whatever size SwiftUI asks for.
/// Keeping this as a regular SwiftUI image fixes the proportions when the
/// same face is shown small (the studio preview) and large (the Now stage).
struct PreviewSurface: View {
    @ObservedObject var preview: PreviewEngine

    var body: some View {
        ZStack {
            Color.black
            if let image = preview.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
        }
        .clipped()
    }
}
