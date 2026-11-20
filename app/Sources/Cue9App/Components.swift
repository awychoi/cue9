import AppKit
import SwiftUI

enum Cue9Assets {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) {
            return cached
        }
        for bundle in [Bundle.module, Bundle.main] {
            if let url = bundle.url(forResource: name, withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                cache.setObject(image, forKey: name as NSString)
                return image
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("app/Sources/Cue9App/Resources/\(name).svg"),
            cwd.appendingPathComponent("brand/decided/final/\(name).svg"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                cache.setObject(image, forKey: name as NSString)
                return image
            }
        }
        return nil
    }
}

struct StageBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Cue9Theme.onStage)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

struct ColourPairSwatch: View {
    let ink: Color
    let background: Color
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(background)
            Circle()
                .fill(ink)
                .frame(width: size * 0.48, height: size * 0.48)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Cue9Theme.lineStrong, lineWidth: 1)
        )
    }
}

struct TextLink: View {
    let title: String
    var systemImage: String? = nil
    var chevron = true
    var color: Color = Cue9Theme.muted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .font(Cue9Font.font(12))
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct CheckBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isOn ? Cue9Theme.orange : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isOn ? Cue9Theme.orange : Cue9Theme.lineStrong, lineWidth: 1)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Cue9Theme.orangeInk)
                }
            }
            .frame(width: 20, height: 20)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Cue9Font.font(12.5, .medium))
            .foregroundStyle(Cue9Theme.ink)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(configuration.isPressed ? Cue9Theme.surface2 : Cue9Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Cue9Theme.lineStrong, lineWidth: 1)
            )
    }
}

struct CopySourceRow: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Text(url.absoluteString)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Cue9Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(copied ? Cue9Theme.success : Cue9Theme.soft)
                Text(copied ? "Copied" : "Copy")
                    .font(Cue9Font.font(10, .medium))
                    .foregroundStyle(copied ? Cue9Theme.success : Cue9Theme.orange)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy the plugin URL")
        .accessibilityLabel("Copy plugin URL")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
    }
}

struct MakerCredit: View {
    @Environment(\.colorScheme) private var colorScheme

    private var mark: NSImage? {
        Cue9Assets.image(colorScheme == .dark ? "abacus-mark-light" : "abacus-mark-dark")
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Cue9Theme.line)
                .frame(height: 1)
            Link(destination: URL(string: "https://wychoi.com")!) {
                HStack(spacing: 8) {
                    if let mark {
                        Image(nsImage: mark)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 20)
                    }
                    HStack(spacing: 3) {
                        Text("by")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                        Text("wychoi")
                            .font(Cue9Font.font(10.5, .medium))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                }
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("wychoi.com")
        }
        .padding(.horizontal, 4)
    }
}
