import SwiftUI

struct NowView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    @State private var localPreview: String?

    private var stageAnimation: String? {
        if let localPreview, !localPreview.isEmpty, CueCatalog.isRenderable(localPreview) {
            return localPreview
        }
        if let live = model.liveAnimation, CueCatalog.isRenderable(live) {
            return live
        }
        if !model.dshOnline, CueCatalog.isRenderable("offline") {
            return "offline"
        }
        return model.idleFace.isEmpty ? nil : model.idleFace
    }

    private var stageTint: Color {
        guard let stageAnimation else { return Cue9Theme.orange }
        return (model.palette[stageAnimation] ?? CueCatalog.defaultColor(for: stageAnimation)).color
    }

    private var stageFaceTitle: String {
        guard let stageAnimation else { return "No face" }
        return model.animationLabel(stageAnimation)
    }

    private var stagePresentation: StagePresentation {
        let mode: String
        let color: Color
        if localPreview != nil {
            mode = "On this Mac"
            color = Cue9Theme.orange
        } else if model.previewing && model.dshOnline {
            mode = "On cue9"
            color = Cue9Theme.orange
        } else if model.dshOnline {
            mode = "Following DeepSeek"
            color = Cue9Theme.success
        } else {
            mode = "Preview only"
            color = Cue9Theme.warning
        }

        let badge: String
        switch mode {
        case "On this Mac": badge = "PREVIEW"
        case "On cue9": badge = "ON CUE9"
        case "Following DeepSeek": badge = "LIVE"
        default: badge = "OFFLINE"
        }

        let detail: String
        if localPreview != nil {
            detail = "\(stageFaceTitle) · just in this app"
        } else if model.previewing && model.dshOnline {
            detail = "\(stageFaceTitle) · playing from Faces"
        } else if let action = model.liveAction, model.dshOnline {
            detail = FaceCopy.short(action)
        } else if model.dshOnline {
            detail = "\(stageFaceTitle) · waiting for DeepSeek"
        } else {
            detail = "Connect DeepSeek Harness to go live"
        }

        return StagePresentation(
            badge: badge,
            badgeColor: color,
            mode: mode,
            modeColor: color,
            detail: detail,
            tint: stageTint
        )
    }

    private var subtitle: String {
        if !model.dshOnline {
            return model.everConnected
                ? "DeepSeek Harness is not connected."
                : "Not connected."
        }
        return "Following DeepSeek Harness."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: "Now",
                subtitle: subtitle,
                trailing: AnyView(headerTrailing)
            )

            HStack(alignment: .top, spacing: 18) {
                CompanionStage(
                    model: model,
                    presentation: stagePresentation,
                    maxFaceSize: 400,
                    onOpenConnect: { section = .connect }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                liveRail
                    .frame(width: 330)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(30)
        .onAppear { syncStage() }
        .onChange(of: localPreview) { _, _ in syncStage() }
        .onChange(of: model.liveAnimation) { _, _ in
            if localPreview == nil { syncStage() }
        }
        .onChange(of: model.dshOnline) { _, _ in
            if localPreview == nil { syncStage() }
        }
        .onChange(of: model.previewing) { _, _ in
            if localPreview == nil { syncStage() }
        }
    }

    private var headerTrailing: some View {
        Button {
            section = model.animations.isEmpty ? .connect : .faces
        } label: {
            Label(model.animations.isEmpty ? "Connect" : "Edit faces",
                  systemImage: model.animations.isEmpty ? "link" : "face.smiling")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help(model.animations.isEmpty ? "Connect DeepSeek Harness" : "Open the face studio")
    }

    private var statusText: String {
        if !model.dshOnline { return model.isReconnecting ? "Reconnecting" : "Offline" }
        if model.previewing { return "Previewing" }
        return "Connected"
    }

    private var statusColor: Color {
        if !model.dshOnline { return Cue9Theme.warning }
        return model.previewing ? Cue9Theme.orange : Cue9Theme.success
    }

    // MARK: - Right rail

    private var liveRail: some View {
        VStack(spacing: 16) {
            nowCard
            recentCard
                .frame(maxHeight: .infinity)
        }
    }

    private var nowCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Right now")
                    Spacer(minLength: 6)
                    Pill(text: statusText, color: statusColor)
                }

                Text(nowTitle)
                    .font(Cue9Font.font(19, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                Text(nowDetail)
                    .font(Cue9Font.font(11.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                if let actionTitle = nowActionTitle {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .semibold))
                        Text(actionTitle)
                            .font(Cue9Font.font(10.5, .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Cue9Theme.soft)
                    .padding(.top, 10)
                }

                nowActions
                    .padding(.top, 12)

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.vertical, 14)

                if shelfFaces.isEmpty {
                    Text("Connect DeepSeek Harness to see faces.")
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(Cue9Theme.soft)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Preview a face")
                            .font(Cue9Font.font(11.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink2)
                        Spacer()
                        Button {
                            surpriseMe()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Random")
                                    .font(Cue9Font.font(10, .medium))
                            }
                            .foregroundStyle(Cue9Theme.orange)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show a random face in the app")
                    }

                                        faceShelf
                        .padding(.top, 10)
                }
            }
        }
    }

    private var nowTitle: String {
        if model.previewing && model.dshOnline && localPreview == nil {
            return "Preview on cue9"
        }
        if let localPreview {
            return "Previewing “\(model.animationLabel(localPreview))”"
        }
        if !model.dshOnline {
            return model.isReconnecting ? "Looking for DeepSeek…" : "cue9 is offline"
        }
        if let action = model.liveAction {
            if FaceCopy.group(for: action) == .more {
                return model.actionLabel(action)
            }
            return FaceCopy.headline(action)
        }
        return "All quiet"
    }

    private var nowDetail: String {
        if model.previewing && model.dshOnline && localPreview == nil {
            let animation = model.liveAnimationTitle ?? "a face"
            return "\(animation) is shown on cue9. Return to live when finished."
        }
        if localPreview != nil {
            if model.dshOnline {
                return "Preview only. DeepSeek is still running."
            }
            return "Preview only. Connect DeepSeek Harness to go live."
        }
        if !model.dshOnline {
            return model.everConnected
                ? "DeepSeek Harness is not responding."
                : "Connect DeepSeek Harness to start."
        }
        if let action = model.liveAction {
            return FaceCopy.detail(action)
        }
        return "Waiting for DeepSeek."
    }

    private var nowActionTitle: String? {
        if model.previewing && model.dshOnline && localPreview == nil {
            if let animation = model.liveAnimationTitle { return animation }
        }
        if localPreview != nil { return nil }
        if model.liveAction != nil, let animation = model.liveAnimationTitle {
            return "Showing “\(animation)”"
        }
        return nil
    }

    @ViewBuilder
    private var nowActions: some View {
        if localPreview != nil {
            Button {
                localPreview = nil
            } label: {
                Label("Back to live", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if model.previewing && model.dshOnline {
            Button {
                model.resumeLive()
            } label: {
                Label("Back to live", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.testState == .sending)
        } else if !model.dshOnline {
            HStack(spacing: 8) {
                Button {
                    Task { await model.retryConnection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Open Connect") {
                    section = .connect
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        } else {
            Button {
                section = .faces
            } label: {
                Label("Edit faces", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - Face shelf

    private var shelfFaces: [CueAnimation] {
        var ids: [String] = []
        if let action = model.liveAction {
            ids.append(contentsOf: model.mapping[action] ?? [])
        }
        ids.append(contentsOf: model.mapping[model.selectedAction] ?? [])
        ids.append(contentsOf: model.mappableAnimations.map(\.id))
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        return unique.prefix(4).compactMap { model.animation(for: $0) }
    }

    private var faceShelf: some View {
        HStack(spacing: 8) {
            ForEach(shelfFaces) { animation in
                ShelfFaceButton(
                    animation: animation,
                    ink: model.palette[animation.id] ?? animation.color,
                    background: model.backgrounds[animation.id] ?? CueCatalog.defaultBackground,
                    selected: localPreview == animation.id
                ) {
                    localPreview = animation.id
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 76)
    }

    private func surpriseMe() {
        let choices = shelfFaces.map(\.id).filter { $0 != localPreview }
        guard let pick = choices.randomElement() else { return }
        localPreview = pick
    }

    // MARK: - Recent

    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Recently")
                    Spacer()
                    Text(model.recentCues.isEmpty ? "—" : "LAST \(min(model.recentCues.count, 6))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Cue9Theme.soft)
                }

                if model.recentCues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No activity yet")
                            .font(Cue9Font.font(12.5, .medium))
                            .foregroundStyle(Cue9Theme.ink2)
                        Text("Recent activity will appear here.")
                            .font(Cue9Font.font(11))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 18)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.recentCues.prefix(6).enumerated()), id: \.element.id) { index, cue in
                                if index > 0 {
                                    Divider().overlay(Cue9Theme.line)
                                }
                                recentRow(cue)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 4)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 10)

                Text("History stays on this Mac.")
                    .font(Cue9Font.font(10))
                    .foregroundStyle(Cue9Theme.soft)
                    .padding(.top, 9)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func recentRow(_ cue: CueEvent) -> some View {
        Button {
            if CueCatalog.isRenderable(cue.animation) {
                localPreview = cue.animation
            }
        } label: {
            HStack(alignment: .center, spacing: 9) {
                FaceThumb(model: model, animation: cue.animation, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FaceCopy.short(cue.action))
                        .font(Cue9Font.font(11.5, .medium))
                        .foregroundStyle(Cue9Theme.ink2)
                        .lineLimit(1)
                    Text(model.animationLabel(cue.animation))
                        .font(Cue9Font.font(10))
                        .foregroundStyle(Cue9Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(cue.ageText)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Preview \(model.animationLabel(cue.animation))")
        .accessibilityLabel("\(FaceCopy.short(cue.action)), \(model.animationLabel(cue.animation)), \(cue.ageText) ago")
    }

    private func syncStage() {
        guard let stageAnimation else { return }
        model.showPreview(animation: stageAnimation, reset: true)
    }
}


private struct ShelfFaceButton: View {
    let animation: CueAnimation
    let ink: RGB
    let background: RGB
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                FaceThumbnailView(
                    animation: animation,
                    ink: ink,
                    background: background,
                    size: 42
                )
                .overlay {
                    if selected {
                        Circle().stroke(Cue9Theme.orange, lineWidth: 2)
                    }
                }

                Text(animation.label)
                    .font(Cue9Font.font(8.5, .medium))
                    .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 62)
                    .frame(minHeight: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Preview \(animation.label)")
        .accessibilityLabel("Preview \(animation.label) in this app")
    }
}
