import AppKit
import SwiftUI

struct StagePresentation: Equatable {
    var badge: String
    var badgeColor: Color
    var mode: String
    var modeColor: Color
    var detail: String
    var tint: Color
}

/// The dark, round stage used to show cue9's face. It only draws the preview
/// engine; whoever owns the page decides which face is loaded.
struct CompanionStage: View {
    @ObservedObject var model: AppModel
    let presentation: StagePresentation
    var maxFaceSize: CGFloat = 430
    var onOpenConnect: (() -> Void)?

    @AppStorage("showDeviceShell") private var shellOn = true
    @AppStorage("shellFinish") private var shellFinishRaw = ShellFinish.white.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var finish: ShellFinish {
        ShellFinish(rawValue: shellFinishRaw) ?? .white
    }

    private var shellImage: NSImage? {
        Cue9Assets.image(finish.assetName)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x000807), Cue9Theme.stage, Color(hex: 0x061110)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [presentation.tint.opacity(0.28), presentation.tint.opacity(0)],
                        center: .center,
                        startRadius: 30,
                        endRadius: 300
                    )
                )
                .frame(width: 580, height: 580)
                .blur(radius: 34)
                .offset(y: 8)
                .accessibilityHidden(true)

            stageBody
                .padding(.top, 44)
                .padding(.horizontal, 16)
                .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            StageBadge(text: presentation.badge, color: presentation.badgeColor)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            if model.animations.isEmpty == false {
                shellMenu
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            stageFooter
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    @ViewBuilder
    private var stageBody: some View {
        if model.animations.isEmpty {
            emptyStage
        } else if shellOn, let shellImage {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / 480, geo.size.height / 580)
                ZStack {
                    Image(nsImage: shellImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 480 * scale, height: 580 * scale)
                        .scaleEffect(reduceMotion ? 1 : (breathing ? 1.004 : 0.998))
                        .accessibilityHidden(true)
                    faceView(size: 360 * scale)
                        .offset(y: 10 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { geo in
                let size = min(maxFaceSize, geo.size.width, geo.size.height)
                faceView(size: max(80, size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func faceView(size: CGFloat) -> some View {
        PreviewSurface(preview: model.preview)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var emptyStage: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.smiling.inverse")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.72))
            Text("No faces yet")
                .font(Cue9Font.font(16, .semibold))
                .foregroundStyle(Cue9Theme.onStage)
            Text("Connect DeepSeek Harness to load them.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.64))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            if let onOpenConnect {
                Button("Open Connect") { onOpenConnect() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
        }
    }

    private var shellMenu: some View {
        Menu {
            Toggle("Show the shell", isOn: $shellOn)
            Divider()
            Section("Shell colour in this app") {
                ForEach(ShellFinish.allCases) { item in
                    Button {
                        shellFinishRaw = item.rawValue
                        if !shellOn { shellOn = true }
                    } label: {
                        Label(item.title, systemImage: item == finish ? "checkmark" : item.swatchSymbol)
                    }
                }
            }
            Divider()
            Text("Preview only.")
        } label: {
            HStack(spacing: 7) {
                CatMark()
                    .fill(Cue9Theme.onStage.opacity(shellOn ? 0.92 : 0.5))
                    .frame(width: 15, height: 14)
                Text("Shell")
                    .font(Cue9Font.font(11, .medium))
                    .foregroundStyle(Cue9Theme.onStage.opacity(shellOn ? 0.92 : 0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Cue9Theme.onStage.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Color(hex: 0x141412), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Preview settings. This doesn't change the real cue9.")
        .accessibilityLabel("Preview settings")
    }

    private var stageFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(presentation.modeColor)
                .frame(width: 6, height: 6)
            Text(presentation.mode)
                .font(Cue9Font.font(10.5, .medium))
                .foregroundStyle(Cue9Theme.onStage)
            Text("·")
                .font(Cue9Font.font(10))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.42))
            Text(presentation.detail)
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.60))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Color(hex: 0x141412), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private var accessibilityLabel: String {
        "cue9 face. \(presentation.mode). \(presentation.detail)."
    }
}

extension ShellFinish {
    var swatchSymbol: String {
        switch self {
        case .white: return "circle"
        case .charcoal: return "circle.fill"
        }
    }
}

struct CatMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.minY + h * 0.58
        let r = min(w, h) * 0.27
        path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        path.move(to: CGPoint(x: cx - r * 1.12, y: cy - r * 0.38))
        path.addLine(to: CGPoint(x: cx - r * 0.92, y: cy - r * 1.62))
        path.addLine(to: CGPoint(x: cx - r * 0.08, y: cy - r * 0.98))
        path.closeSubpath()
        path.move(to: CGPoint(x: cx + r * 1.12, y: cy - r * 0.38))
        path.addLine(to: CGPoint(x: cx + r * 0.92, y: cy - r * 1.62))
        path.addLine(to: CGPoint(x: cx + r * 0.08, y: cy - r * 0.98))
        path.closeSubpath()
        return path
    }
}
