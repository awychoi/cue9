import SwiftUI

enum ColourLayer: String, CaseIterable, Identifiable {
    case ink = "Face"
    case background = "Screen"

    var id: String { rawValue }
}

struct FacesView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    @State private var reactionID: String?
    @State private var colourLayer: ColourLayer = .ink
    @State private var showColours = false

    private var mapped: [String] { model.mapping[model.selectedAction] ?? [] }
    private var isReaction: Bool { reactionID != nil }
    private var selectedIsIncluded: Bool {
        isReaction || mapped.contains(model.selectedAnimation)
    }

    private var sections: [MomentSection] {
        FaceCopy.MomentGroup.allCases.compactMap { group in
            let items = model.actions.filter { FaceCopy.group(for: $0.id) == group }
            guard !items.isEmpty else { return nil }
            return MomentSection(group: group, actions: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: "Faces",
                subtitle: "Choose the faces cue9 shows.",
                trailing: AnyView(headerTrailing)
            )

            if model.actions.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 18) {
                    momentsList
                        .frame(width: 286)
                        .frame(maxHeight: .infinity)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(30)
        .onAppear {
            if model.selectedAction.isEmpty, let first = model.actions.first {
                model.selectAction(first.id)
            }
            ensureFaceSelection()
            syncPreview()
        }
        .onChange(of: model.selectedAction) { _, _ in
            ensureFaceSelection()
            syncPreview()
        }
        .onChange(of: model.selectedAnimation) { _, _ in
            if reactionID == nil { syncPreview() }
        }
        .onChange(of: reactionID) { _, value in
            if let value {
                model.selectAnimation(value)
                model.showPreview(animation: value, reset: true)
            }
        }
        .onExitCommand {
            if showColours {
                showColours = false
            } else if reactionID != nil {
                backToActions()
            }
        }
    }

    // MARK: - Header

    private var headerTrailing: some View {
        HStack(spacing: 12) {
            if !model.saveState.text.isEmpty {
                SaveStatusView(state: model.saveState)
            }
            if !model.actions.isEmpty {
                if let next = model.unmappedActions.first {
                    Button {
                        chooseAction(next.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(model.unmappedActions.count == 1
                                 ? "1 needs a face"
                                 : "\(model.unmappedActions.count) need a face")
                                .font(Cue9Font.font(10.5, .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Cue9Theme.warning)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Cue9Theme.warning.opacity(0.10), in: Capsule())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the next moment without a face")
                } else {
                    Pill(text: "All set", color: Cue9Theme.success)
                }
            }
        }
    }

    // MARK: - Moments list

    private var momentsList: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Moments")
                Spacer()
                Text("\(model.mappedActionCount)/\(model.actions.count)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.horizontal, 14)
            .padding(.top, 15)
            .padding(.bottom, 11)

            Divider().overlay(Cue9Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Text(section.group.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(Cue9Theme.soft)
                            .padding(.horizontal, 9)
                            .padding(.top, 13)
                            .padding(.bottom, 4)
                        ForEach(section.actions) { action in
                            momentRow(action)
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            if !model.deviceAnimations.isEmpty {
                Divider().overlay(Cue9Theme.line)
                reactionsFooter
            }
        }
        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private func momentRow(_ action: CueAction) -> some View {
        let selected = reactionID == nil && model.selectedAction == action.id
        let faces = model.mapping[action.id] ?? []
        return Button {
            chooseAction(action.id)
        } label: {
            HStack(spacing: 9) {
                if let first = faces.first, let animation = model.animation(for: first) {
                    FaceThumbnailView(
                        animation: animation,
                        ink: model.palette[first] ?? animation.color,
                        background: model.backgrounds[first] ?? CueCatalog.defaultBackground,
                        size: 29
                    )
                } else {
                    Circle()
                        .strokeBorder(
                            selected ? Cue9Theme.orange.opacity(0.6) : Cue9Theme.lineStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                        .frame(width: 29, height: 29)
                        .overlay {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Cue9Theme.soft)
                        }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label)
                        .font(Cue9Font.font(11.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                        .lineLimit(1)
                    Text(faces.isEmpty
                         ? "No face"
                         : (faces.count == 1 ? "1 face" : "\(faces.count) faces"))
                        .font(Cue9Font.font(9.5))
                        .foregroundStyle(faces.isEmpty ? Cue9Theme.warning : Cue9Theme.soft)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Cue9Theme.orange)
                } else if faces.isEmpty {
                    Circle()
                        .fill(Cue9Theme.warning)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                selected ? Cue9Theme.surface2 : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.label). \(faces.isEmpty ? "No face yet" : "\(faces.count) faces").")
        .accessibilityValue(selected ? "Selected" : "")
    }

    private var reactionsFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ON DEVICE")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Cue9Theme.soft)
            HStack(spacing: 6) {
                ForEach(model.deviceAnimations) { animation in
                    let selected = reactionID == animation.id
                    Button {
                        chooseReaction(animation.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: FaceCopy.reactionSymbol(animation.id))
                                .font(.system(size: 10, weight: .medium))
                            Text(FaceCopy.reactionTrigger(animation.id))
                                .font(Cue9Font.font(10.5, .medium))
                        }
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.muted)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            selected ? Cue9Theme.surface2 : Cue9Theme.paper,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(selected ? Cue9Theme.orange.opacity(0.65) : Cue9Theme.line, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader
            previewCard
                .padding(.top, 14)

            if isReaction {
                reactionDetails
                    .padding(.top, 16)
                Spacer(minLength: 0)
            } else {
                facePickerHeader
                    .padding(.top, 16)
                faceGrid
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity)
            }

            detailFooter
                .padding(.top, 10)
        }
    }

    private var detailTitle: String {
        if let reactionID {
            return FaceCopy.reactionHeadline(reactionID)
        }
        if FaceCopy.group(for: model.selectedAction) == .more {
            return model.selectedActionTitle
        }
        return FaceCopy.headline(model.selectedAction)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(detailTitle)
                    .font(Cue9Font.font(21, .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Cue9Theme.ink)
                if isReaction {
                    Text("DEVICE")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Cue9Theme.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Cue9Theme.orange.opacity(0.11), in: Capsule())
                }
            }
            Text(isReaction ? FaceCopy.reactionDetail(reactionID ?? "") : FaceCopy.detail(model.selectedAction))
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewCard: some View {
        HStack(alignment: .top, spacing: 16) {
            facePreview

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(model.selectedAnimationTitle)
                        .font(Cue9Font.font(15, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                        .lineLimit(1)
                    if selectedIsIncluded {
                        Pill(text: isReaction ? "On device" : "Included", color: Cue9Theme.success)
                    } else {
                        Pill(text: "Not included", color: Cue9Theme.warning)
                    }
                }

                Text(previewDetail)
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    ColourWell(
                        title: "Face",
                        color: inkBinding.wrappedValue,
                        hex: inkHex,
                        selected: colourLayer == .ink
                    ) {
                        colourLayer = .ink
                        showColours = true
                    }
                    ColourWell(
                        title: "Screen",
                        color: backgroundBinding.wrappedValue,
                        hex: backgroundHex,
                        selected: colourLayer == .background
                    ) {
                        colourLayer = .background
                        showColours = true
                    }
                }
                .popover(isPresented: $showColours, arrowEdge: .bottom) {
                    FaceColourEditor(
                        model: model,
                        layer: $colourLayer,
                        animation: model.selectedAnimation
                    )
                }

                HStack(spacing: 8) {
                    Button {
                        showOnDevice()
                    } label: {
                        HStack(spacing: 6) {
                            if model.testState == .sending {
                                ProgressView().controlSize(.mini).tint(Cue9Theme.infoInk)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Text(model.testState == .sending ? "Sending…" : "Show on cue9")
                        }
                    }
                    .buttonStyle(TestButtonStyle())
                    .disabled(!canShowOnDevice)
                    .opacity(canShowOnDevice ? 1 : 0.45)
                    .help(canShowOnDevice ? "Show this face on cue9" : testHint)
                    .keyboardShortcut(.return, modifiers: [.command])

                    if model.previewing && model.dshOnline {
                        Button {
                            model.resumeLive()
                        } label: {
                            Label("Back to live", systemImage: "arrow.uturn.left")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.testState == .sending)
                    }
                }

                TestFeedbackView(state: model.testState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private var facePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Cue9Theme.stage)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [previewTint.opacity(0.32), previewTint.opacity(0)],
                        center: .center,
                        startRadius: 6,
                        endRadius: 110
                    )
                )
                .frame(width: 190, height: 190)
            PreviewSurface(preview: model.preview)
                .frame(width: 134, height: 134)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
        }
        .frame(width: 158, height: 158)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Face preview, \(model.selectedAnimationTitle)")
    }

    private var previewTint: Color {
        (model.palette[model.selectedAnimation] ?? CueCatalog.defaultColor(for: model.selectedAnimation)).color
    }

    private var previewDetail: String {
        if let reactionID {
            return FaceCopy.reactionDetail(reactionID)
        }
        if selectedIsIncluded {
            return "Used for \(model.selectedActionTitle)."
        }
        return "Tap to include for \(model.selectedActionTitle)."
    }

    private var facePickerHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Choose faces")
                .font(Cue9Font.font(13, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Tap a face to preview. Use the circle to include.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.soft)
            Spacer()
            Text(mapped.count == 1 ? "1 selected" : "\(mapped.count) selected")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(mapped.isEmpty ? Cue9Theme.warning : Cue9Theme.soft)
        }
    }

    private var faceGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 165), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(model.mappableAnimations) { animation in
                    FacePickerTile(
                        animation: animation,
                        ink: model.palette[animation.id] ?? animation.color,
                        background: model.backgrounds[animation.id] ?? CueCatalog.defaultBackground,
                        included: mapped.contains(animation.id),
                        selected: model.selectedAnimation == animation.id,
                        onPreview: { previewFace(animation) },
                        onToggle: { toggleFace(animation) }
                    )
                }
            }
            .padding(.horizontal, 1)
            .padding(.bottom, 2)
        }
        .scrollIndicators(.never)
    }

    private var reactionDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Device reactions")
                    .font(Cue9Font.font(13, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Spacer()
                Text("ON DEVICE")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }

            HStack(spacing: 8) {
                ForEach(model.deviceAnimations) { animation in
                    let selected = model.selectedAnimation == animation.id
                    Button {
                        chooseReaction(animation.id)
                    } label: {
                        HStack(spacing: 9) {
                            FaceThumbnailView(
                                animation: animation,
                                ink: model.palette[animation.id] ?? animation.color,
                                background: model.backgrounds[animation.id] ?? CueCatalog.defaultBackground,
                                size: 42
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(FaceCopy.reactionTrigger(animation.id))
                                    .font(Cue9Font.font(12, .semibold))
                                    .foregroundStyle(Cue9Theme.ink)
                                Text(animation.label)
                                    .font(Cue9Font.font(10))
                                    .foregroundStyle(Cue9Theme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Cue9Theme.orange)
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selected ? Cue9Theme.surface : Cue9Theme.surface2,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selected ? Cue9Theme.orange.opacity(0.6) : Cue9Theme.line, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("These play from cue9's shake and touch sensors.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private var detailFooter: some View {
        Text("Changes save automatically.")
            .font(Cue9Font.font(10))
            .foregroundStyle(Cue9Theme.soft)
            .frame(height: 20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.smiling")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Cue9Theme.orange)
            Text("No moments yet")
                .font(Cue9Font.font(17, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Connect DeepSeek Harness to load them.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Open Connect") {
                section = .connect
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    // MARK: - Colour bindings

    private var inkBinding: Binding<Color> {
        Binding(
            get: {
                model.palette[model.selectedAnimation]?.color
                    ?? CueCatalog.defaultColor(for: model.selectedAnimation).color
            },
            set: { model.setInkColor($0) }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: {
                model.backgrounds[model.selectedAnimation]?.color
                    ?? CueCatalog.defaultBackground.color
            },
            set: { model.setBackgroundColor($0) }
        )
    }

    private var inkHex: String {
        model.palette[model.selectedAnimation]?.hex
            ?? CueCatalog.defaultColor(for: model.selectedAnimation).hex
    }

    private var backgroundHex: String {
        model.backgrounds[model.selectedAnimation]?.hex
            ?? CueCatalog.defaultBackground.hex
    }

    // MARK: - Actions

    private var canShowOnDevice: Bool {
        model.dshOnline
            && model.moteConnected
            && !model.selectedAnimation.isEmpty
            && model.testState != .sending
            && selectedIsIncluded
    }

    private var testHint: String {
        if !model.dshOnline { return "Connect DeepSeek Harness in Connect first." }
        if !model.moteConnected { return "cue9 isn't connected right now." }
        if !selectedIsIncluded { return "Add this face to the moment first, or pick one that's included." }
        return "Show this face on cue9"
    }

    private func showOnDevice() {
        if let reactionID {
            model.previewDeviceAnimation(reactionID)
        } else {
            model.previewAction(model.selectedAction, animation: model.selectedAnimation)
        }
    }

    private func chooseAction(_ id: String) {
        reactionID = nil
        if model.selectedAction != id {
            model.selectAction(id)
        }
        ensureFaceSelection()
        syncPreview()
    }

    private func chooseReaction(_ id: String) {
        reactionID = id
        model.selectAnimation(id)
        model.showPreview(animation: id, reset: true)
    }

    private func backToActions() {
        reactionID = nil
        ensureFaceSelection()
        syncPreview()
    }

    private func previewFace(_ animation: CueAnimation) {
        model.selectAnimation(animation.id)
        model.showPreview(animation: animation.id, reset: true)
    }

    private func toggleFace(_ animation: CueAnimation) {
        model.toggleMapping(animation.id)
    }

    private func ensureFaceSelection() {
        guard reactionID == nil else { return }
        guard !model.selectedAction.isEmpty else { return }
        let valid = model.mappableAnimations.map(\.id)
        if !valid.contains(model.selectedAnimation) {
            let firstMapped = (model.mapping[model.selectedAction] ?? []).first
            if let firstMapped {
                model.selectAnimation(firstMapped)
            } else if let first = valid.first {
                model.selectAnimation(first)
            }
        }
    }

    private func syncPreview() {
        let animation = reactionID ?? model.selectedAnimation
        guard !animation.isEmpty else { return }
        model.showPreview(animation: animation, reset: true)
    }
}

private struct MomentSection: Identifiable {
    let group: FaceCopy.MomentGroup
    let actions: [CueAction]

    var id: String { group.rawValue }
}

private struct FacePickerTile: View {
    let animation: CueAnimation
    let ink: RGB
    let background: RGB
    let included: Bool
    let selected: Bool
    let onPreview: () -> Void
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onPreview) {
                VStack(spacing: 6) {
                    FaceThumbnailView(
                        animation: animation,
                        ink: ink,
                        background: background,
                        size: 54
                    )
                    .opacity(included ? 1 : 0.7)

                    Text(animation.label)
                        .font(Cue9Font.font(10, included ? .medium : .regular))
                        .foregroundStyle(included ? Cue9Theme.ink2 : Cue9Theme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Cue9Theme.surface2 : Cue9Theme.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            selected ? Cue9Theme.orange
                                : (included ? Cue9Theme.lineStrong : Cue9Theme.line),
                            lineWidth: selected ? 1.6 : 1
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Cue9Theme.orange.opacity(hovering ? 0.35 : 0), lineWidth: 3)
                        .padding(-2)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Preview \(animation.label)")
            .accessibilityLabel("Preview \(animation.label)")
            .accessibilityValue(included ? "Included\(selected ? ", selected" : "")" : "Not included\(selected ? ", selected" : "")")

            Button(action: onToggle) {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(included ? Cue9Theme.orange : Cue9Theme.soft)
                    .padding(4)
                    .background(Cue9Theme.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(included ? "Remove \(animation.label) from this moment" : "Include \(animation.label) in this moment")
            .accessibilityLabel(included ? "Remove \(animation.label)" : "Include \(animation.label)")
        }
    }
}

private struct FaceColourEditor: View {
    @ObservedObject var model: AppModel
    @Binding var layer: ColourLayer
    let animation: String
    @Environment(\.dismiss) private var dismiss

    private var inkBinding: Binding<Color> {
        Binding(
            get: {
                model.palette[animation]?.color
                    ?? CueCatalog.defaultColor(for: animation).color
            },
            set: { model.setInkColor($0) }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: {
                model.backgrounds[animation]?.color
                    ?? CueCatalog.defaultBackground.color
            },
            set: { model.setBackgroundColor($0) }
        )
    }

    private var activeBinding: Binding<Color> {
        layer == .ink ? inkBinding : backgroundBinding
    }

    private var activeDefault: Color {
        layer == .ink
            ? CueCatalog.defaultColor(for: animation).color
            : CueCatalog.defaultBackground.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colours for “\(model.animationLabel(animation))”")
                        .font(Cue9Font.font(14, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            HStack(spacing: 6) {
                ForEach(ColourLayer.allCases) { item in
                    Button {
                        layer = item
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item == .ink ? inkBinding.wrappedValue : backgroundBinding.wrappedValue)
                                .frame(width: 14, height: 14)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Cue9Theme.lineStrong, lineWidth: 1))
                            Text(item == .ink ? "Face colour" : "Screen colour")
                                .font(Cue9Font.font(11, .medium))
                                .foregroundStyle(layer == item ? Cue9Theme.ink : Cue9Theme.muted)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(
                            layer == item ? Cue9Theme.paper : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(layer == item ? Cue9Theme.lineStrong : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            MoteColourPanel(
                color: activeBinding,
                defaultColor: activeDefault,
                title: layer == .ink ? "Face colour" : "Screen colour",
                currentAnimation: animation
            )
            .id("\(animation)-\(layer.rawValue)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Saved automatically.")
                .font(Cue9Font.font(10))
                .foregroundStyle(Cue9Theme.soft)
        }
        .padding(16)
        .frame(width: 400, height: 500)
    }
}
