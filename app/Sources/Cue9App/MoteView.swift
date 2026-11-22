import SwiftUI

struct MoteView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    @State private var tab: MoteTab = .mapping
    @State private var colourLayer: ColourLayer = .ink
    @State private var inspectorOpen = false
    @State private var showUnmapped = false
    @State private var showActionPicker = false
    @State private var showAnimationPicker = false
    @AppStorage("showDeviceShell") private var shellOn = true
    @AppStorage("shellFinish") private var shellFinishRaw = ShellFinish.white.rawValue
    @Namespace private var returnLiveNamespace

    private var finish: ShellFinish {
        ShellFinish(rawValue: shellFinishRaw) ?? .white
    }

    private var mapped: [String] { model.mapping[model.selectedAction] ?? [] }
    private var mappedCount: Int { mapped.count }
    private var selectedIsDeviceOnly: Bool { model.isDeviceOnly(model.selectedAnimation) }
    private var isUnmapped: Bool { mapped.isEmpty }
    private var unmappedCount: Int { model.actions.count - model.mappedActionCount }

    private var colourAction: String? {
        model.actionUsing(model.selectedAnimation)
    }

    private var shellImage: NSImage? {
        Cue9Assets.image(finish.assetName)
    }

    private var stageKind: StageKind {
        if model.animations.isEmpty { return .empty }
        if !inspectorOpen && model.dshOnline {
            if let live = model.liveAnimation, CueCatalog.isRenderable(live) {
                return .live
            }
            return .waiting
        }
        return .localPreview
    }

    private var showingFace: Bool {
        switch stageKind {
        case .live, .localPreview: return true
        case .empty, .waiting: return false
        }
    }

    private var canTestMapping: Bool {
        model.dshOnline
            && model.usbConnected
            && !model.selectedAction.isEmpty
            && !model.selectedAnimation.isEmpty
            && mappedCount > 0
            && model.testState != .sending
    }

    private var canTestColour: Bool {
        model.dshOnline
            && model.usbConnected
            && (colourAction != nil || selectedIsDeviceOnly)
            && model.testState != .sending
    }

    private var canPlayDevice: Bool {
        model.dshOnline
            && model.usbConnected
            && !model.selectedAnimation.isEmpty
            && model.testState != .sending
    }

    private var subtitle: String {
        if !model.dshOnline {
            return model.everConnected
                ? "Preview only · reconnecting to DSH."
                : "Preview only · plugin not connected."
        }
        if inspectorOpen {
            switch tab {
            case .mapping: return "Editing · \(model.selectedActionTitle)"
            case .colour: return "Editing colours · \(model.selectedAnimationTitle)"
            }
        }
        if model.previewing { return "Previewing on the mote." }
        return "Following DSH."
    }

    private var stageBadgeText: String {
        switch stageKind {
        case .empty: return "NO ANIMATIONS"
        case .waiting: return model.dshOnline ? "LIVE" : "OFFLINE"
        case .live: return model.previewing ? "ON MOTE" : "LIVE"
        case .localPreview: return model.dshOnline ? "LOCAL PREVIEW" : "OFFLINE"
        }
    }

    private var stageBadgeColor: Color {
        switch stageKind {
        case .empty, .waiting: return model.dshOnline ? Cue9Theme.success : Cue9Theme.warning
        case .live: return model.previewing ? Cue9Theme.orange : Cue9Theme.success
        case .localPreview: return model.dshOnline ? Cue9Theme.orange : Cue9Theme.warning
        }
    }

    private var stageFooterMode: (String, Color) {
        if !model.dshOnline { return ("Preview only", Cue9Theme.warning) }
        if inspectorOpen { return ("Local preview", Cue9Theme.orange) }
        if model.previewing { return ("On mote", Cue9Theme.orange) }
        if stageKind == .live { return ("Following DSH", Cue9Theme.success) }
        return ("Live", Cue9Theme.success)
    }

    private var stageFooterDetail: String {
        switch stageKind {
        case .empty:
            return "No animations loaded"
        case .waiting:
            return "Waiting for a cue from DSH"
        case .live:
            return "\(model.liveActionTitle ?? "Waiting") · \(model.liveAnimationTitle ?? "—")"
        case .localPreview:
            return "\(model.selectedActionTitle) · \(model.selectedAnimationTitle)"
        }
    }

    private var stageAccessibilityLabel: String {
        let animation = stageKind == .live ? model.liveAnimationTitle : model.selectedAnimationTitle
        let action = stageKind == .live ? model.liveActionTitle : model.selectedActionTitle
        return "\(stageBadgeText.capitalized) mote face\(animation.map { ", \($0)" } ?? "")\(action.map { ", \($0)" } ?? "")."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                title: "Mote",
                subtitle: subtitle,
                trailing: AnyView(headerTrailing)
            )

            HStack(alignment: .top, spacing: 20) {
                stage
                if inspectorOpen {
                    inspector
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    MoteLiveRail(model: model, section: $section, returnNamespace: returnLiveNamespace)
                        .frame(width: 340)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(30)
        .animation(.easeInOut(duration: 0.24), value: inspectorOpen)
        .animation(.easeInOut(duration: 0.2), value: model.previewing)
        .onAppear {
            ensureMappingSelection()
            syncPreview(reset: true)
        }
        .onChange(of: inspectorOpen) { _, _ in
            if inspectorOpen { ensureMappingSelection() }
            syncPreview(reset: true)
        }
        .onChange(of: tab) { _, _ in
            if inspectorOpen { syncPreview(reset: true) }
        }
        .onChange(of: model.selectedAction) { _, _ in
            if inspectorOpen { syncPreview(reset: true) }
        }
        .onChange(of: model.selectedAnimation) { _, _ in
            if inspectorOpen { syncPreview(reset: true) }
        }
        .onChange(of: model.liveAnimation) { _, _ in
            if !inspectorOpen { syncPreview(reset: true) }
        }
        .onChange(of: model.dshOnline) { _, _ in
            syncPreview(reset: true)
        }
        .onChange(of: model.previewing) { _, _ in
            if !inspectorOpen { syncPreview(reset: true) }
        }
        .onExitCommand {
            if inspectorOpen {
                withAnimation(.easeInOut(duration: 0.2)) { inspectorOpen = false }
            }
        }
    }

    // MARK: - Header

    private var headerTrailing: some View {
        HStack(spacing: 12) {
            if !model.saveState.text.isEmpty {
                SaveStatusView(state: model.saveState)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    inspectorOpen.toggle()
                }
            } label: {
                Label(inspectorOpen ? "Done" : "Edit", systemImage: "slider.horizontal.3")
                    .font(Cue9Font.font(11.5, .medium))
                    .foregroundStyle(inspectorOpen ? Cue9Theme.ink : Cue9Theme.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        inspectorOpen ? Cue9Theme.ink.opacity(0.08) : Cue9Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(inspectorOpen ? Cue9Theme.lineStrong : Cue9Theme.line, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
            .help(inspectorOpen ? "Close the editor and return to live" : "Edit animations and colours")
            .accessibilityLabel(inspectorOpen ? "Done editing" : "Edit mote")
        }
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Cue9Theme.stage)

            stageBody
                .padding(.top, 46)
                .padding(.horizontal, 16)
                .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            StageBadge(text: stageBadgeText, color: stageBadgeColor)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            if !model.animations.isEmpty {
                ShellToggle(isOn: $shellOn, enabled: shellImage != nil, finish: finish)
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            StageFooter(mode: stageFooterMode, detail: stageFooterDetail)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stageAccessibilityLabel)
    }

    @ViewBuilder
    private var stageBody: some View {
        switch stageKind {
        case .empty:
            emptyStage
        case .waiting:
            waitingStage
        case .live, .localPreview:
            if shellOn, let shellImage {
                shellStage(shellImage)
            } else {
                faceView(size: 430)
            }
        }
    }

    private func shellStage(_ image: NSImage) -> some View {
        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width)
            let availableHeight = max(0, geo.size.height)
            let scale = min(1, availableWidth / 480, availableHeight / 580)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 480 * scale, height: 580 * scale)
                    .accessibilityHidden(true)
                faceView(size: 360 * scale)
                    .offset(y: 10 * scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func faceView(size: CGFloat) -> some View {
        PreviewSurface(preview: model.preview)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stageAccessibilityLabel)
    }

    private var emptyStage: some View {
        VStack(spacing: 10) {
            Text("No animations loaded")
                .font(Cue9Font.font(15, .semibold))
                .foregroundStyle(Cue9Theme.onStage)
            Text("Connect the DSH plugin to load the action and animation lists.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.66))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)
            Button("Open Device") {
                section = .device
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 4)
        }
    }

    private var waitingStage: some View {
        VStack(spacing: 10) {
            Text("Waiting for a cue")
                .font(Cue9Font.font(15, .semibold))
                .foregroundStyle(Cue9Theme.onStage)
            Text("The mote will move when DSH starts working.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.66))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar

            if tab == .mapping {
                mappingInspector
            } else {
                colourInspector
            }
        }
        .padding(18)
        .frame(width: 466)
        .frame(maxHeight: .infinity)
        .background(
            Cue9Theme.surface,
            in: RoundedRectangle(cornerRadius: Cue9Theme.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Cue9Theme.radius, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(MoteTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(Cue9Font.font(12, .medium))
                        .foregroundStyle(tab == item ? Cue9Theme.ink : Cue9Theme.muted)
                        .padding(.horizontal, 14)
                        .frame(height: 29)
                        .background(
                            tab == item ? Cue9Theme.ink.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Cue9Theme.lineStrong, lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(tab == item ? "Selected" : "")
            }
        }
        .padding(2)
        .background(
            Cue9Theme.surface2,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    // MARK: - Mapping

    private var mappingInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                fieldLabel("Action")
                Spacer()
                Text("\(model.actions.count) actions")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.top, 16)

            actionMenu
                .padding(.top, 5)

            HStack(spacing: 6) {
                Text("\(model.mappedActionCount) of \(model.actions.count) actions mapped")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(unmappedCount == 0 ? Cue9Theme.success : Cue9Theme.muted)
                Spacer(minLength: 4)
                if unmappedCount > 0 {
                    Button("Review \(unmappedCount) unmapped") {
                        showUnmapped = true
                    }
                    .buttonStyle(.plain)
                    .font(Cue9Font.font(10.5, .medium))
                    .foregroundStyle(Cue9Theme.orange)
                    .popover(isPresented: $showUnmapped, arrowEdge: .bottom) {
                        UnmappedActionsPopover(model: model, isPresented: $showUnmapped)
                    }
                }
            }
            .padding(.top, 6)

            HStack(spacing: 5) {
                SectionLabel(text: "Animations")
                    .help("One action can rotate through several animations.")
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Cue9Theme.soft)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .help("One action can rotate through several animations.")
                    .accessibilityLabel("About multiple animations")
                Spacer()
                Text(mappedCount == 1 ? "1 mapped" : "\(mappedCount) mapped")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.top, 16)

            if model.animations.isEmpty {
                emptyAnimations
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 5),
                            GridItem(.flexible(), spacing: 5),
                            GridItem(.flexible(), spacing: 5),
                        ],
                        spacing: 5
                    ) {
                        ForEach(model.mappableAnimations) { animation in
                            AnimationTileView(
                                animation: animation,
                                color: model.palette[animation.id]?.color ?? animation.color.color,
                                background: model.backgrounds[animation.id]?.color ?? CueCatalog.defaultBackground.color,
                                selected: model.selectedAnimation == animation.id,
                                mapped: mapped.contains(animation.id),
                                onSelect: { model.selectAnimation(animation.id) },
                                onToggle: { model.toggleMapping(animation.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }

            if !model.deviceAnimations.isEmpty {
                deviceReactions
                    .padding(.top, 10)
            }

            footer(
                testTitle: selectedIsDeviceOnly ? "Play on mote" : "Test on mote",
                testEnabled: selectedIsDeviceOnly ? canPlayDevice : canTestMapping,
                hint: selectedIsDeviceOnly ? deviceCaption : mappingCaption,
                returnNamespace: returnLiveNamespace,
                action: {
                    if selectedIsDeviceOnly {
                        model.previewDeviceAnimation(model.selectedAnimation)
                    } else {
                        model.previewAction(model.selectedAction, animation: model.selectedAnimation)
                    }
                }
            )
        }
    }

    private var deviceReactions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                SectionLabel(text: "Device reactions")
                Text("ON DEVICE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Cue9Theme.soft)
                Spacer(minLength: 4)
            }
            HStack(spacing: 5) {
                ForEach(model.deviceAnimations) { animation in
                    deviceReactionChip(animation)
                }
            }
            Text("Plays on the mote from its own sensors. Preview and recolour here; it cannot be mapped to a DSH action.")
                .font(Cue9Font.font(9.5))
                .foregroundStyle(Cue9Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceReactionChip(_ animation: CueAnimation) -> some View {
        let selected = model.selectedAnimation == animation.id
        let trigger = animation.id == "dizzy" ? "Shake"
            : animation.id == "stroked" ? "Stroke"
            : "On device"
        return Button {
            model.selectAnimation(animation.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.palette[animation.id]?.color ?? animation.color.color)
                        .frame(width: 6, height: 6)
                    Text(animation.label)
                        .font(Cue9Font.font(10.5, .medium))
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                        .lineLimit(1)
                }
                Text(trigger)
                    .font(Cue9Font.font(9))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Cue9Theme.surface2 : Cue9Theme.paper,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? Cue9Theme.orange.opacity(0.7) : Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(animation.label): \(trigger.lowercased()) on the mote. Preview and recolour here; not mappable.")
        .accessibilityLabel("Preview \(animation.label)")
        .accessibilityValue(selected ? "Selected. Device reaction, not mappable." : "Device reaction, not mappable.")
    }

    private var deviceCaption: String {
        if !model.dshOnline { return "Connect the DSH plugin in Device." }
        if !model.usbConnected { return "The mote isn't connected." }
        return "Plays \(model.selectedAnimationTitle) on the mote with these colours."
    }

    private var actionMenu: some View {
        Button {
            showActionPicker = true
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedActionTitle)
                        .font(Cue9Font.font(12.5, .medium))
                        .foregroundStyle(Cue9Theme.ink2)
                        .lineLimit(1)
                    Text(model.mappingSummary(for: model.selectedAction))
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(isUnmapped ? Cue9Theme.warning : Cue9Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                Cue9Theme.paper,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showActionPicker, arrowEdge: .bottom) {
            ActionPickerPopover(model: model, isPresented: $showActionPicker)
        }
        .accessibilityLabel("Action, \(model.selectedActionTitle)")
        .accessibilityHint("Choose which DSH action to map.")
    }

    private var mappingCaption: String {
        if !model.dshOnline { return "Connect the DSH plugin in Device." }
        if !model.usbConnected { return "The mote isn't connected." }
        if mappedCount == 0 { return "Tick an animation for this action first." }
        return "Shows \(model.selectedAnimationTitle) for \(model.selectedActionTitle) on the mote."
    }

    private var emptyAnimations: some View {
        VStack(spacing: 5) {
            Text("No animations loaded")
                .font(Cue9Font.font(12, .medium))
                .foregroundStyle(Cue9Theme.ink2)
            Text("Connect the DSH plugin to load the animation list.")
                .font(Cue9Font.font(11))
                .foregroundStyle(Cue9Theme.soft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Colour

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

    private var activeColourBinding: Binding<Color> {
        colourLayer == .ink ? inkBinding : backgroundBinding
    }

    private var defaultInk: Color {
        model.animations.first(where: { $0.id == model.selectedAnimation })?.color.color
            ?? CueCatalog.defaultColor(for: model.selectedAnimation).color
    }

    private var defaultBackground: Color {
        CueCatalog.defaultBackground.color
    }

    private var activeDefaultColour: Color {
        colourLayer == .ink ? defaultInk : defaultBackground
    }

    private var inkHex: String {
        model.palette[model.selectedAnimation]?.hex
            ?? CueCatalog.defaultColor(for: model.selectedAnimation).hex
    }

    private var backgroundHex: String {
        model.backgrounds[model.selectedAnimation]?.hex
            ?? CueCatalog.defaultBackground.hex
    }

    private var colourInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel("Animation")
                .padding(.top, 16)

            animationMenu
                .padding(.top, 5)

            usedByLine
                .padding(.top, 8)

            colourLayerPicker
                .padding(.top, 10)

            MoteColourPanel(
                color: activeColourBinding,
                defaultColor: activeDefaultColour,
                title: colourLayer == .ink ? "Expression colour" : "Background colour",
                currentAnimation: model.selectedAnimation
            )
            .id("\(model.selectedAnimation)-\(colourLayer.rawValue)")
            .padding(.top, 10)
            .frame(maxHeight: .infinity)

            footer(
                testTitle: "Test colours on mote",
                testEnabled: canTestColour,
                hint: colourCaption,
                returnNamespace: returnLiveNamespace,
                action: {
                    if selectedIsDeviceOnly {
                        model.previewDeviceAnimation(model.selectedAnimation)
                    } else if let action = colourAction {
                        model.previewAction(action, animation: model.selectedAnimation)
                    }
                }
            )
        }
    }

    private var colourLayerPicker: some View {
        HStack(spacing: 6) {
            colourLayerButton(.ink, color: inkBinding.wrappedValue, hex: inkHex)
            colourLayerButton(.background, color: backgroundBinding.wrappedValue, hex: backgroundHex)
        }
    }

    private func colourLayerButton(_ layer: ColourLayer, color: Color, hex: String) -> some View {
        let selected = colourLayer == layer
        return Button {
            colourLayer = layer
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Cue9Theme.lineStrong, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.rawValue)
                        .font(Cue9Font.font(11, .medium))
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                    Text("#\(hex)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Cue9Theme.soft)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                selected ? Cue9Theme.surface2 : Cue9Theme.paper,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Cue9Theme.orange.opacity(0.75) : Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layer.rawValue) colour")
        .accessibilityValue(selected ? "Selected, #\(hex)" : "#\(hex)")
    }

    private var animationMenu: some View {
        Button {
            showAnimationPicker = true
        } label: {
            HStack(spacing: 8) {
                ColourPairSwatch(
                    ink: inkBinding.wrappedValue,
                    background: backgroundBinding.wrappedValue,
                    size: 14
                )
                Text(model.selectedAnimationTitle)
                    .font(Cue9Font.font(12.5, .medium))
                    .foregroundStyle(Cue9Theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                Cue9Theme.paper,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAnimationPicker, arrowEdge: .bottom) {
            AnimationPickerPopover(model: model, isPresented: $showAnimationPicker)
        }
        .accessibilityLabel("Animation, \(model.selectedAnimationTitle)")
    }

    private var usedByLine: some View {
        let actions = model.usedByActions(for: model.selectedAnimation)
        return Group {
            if selectedIsDeviceOnly {
                Text(model.selectedAnimation == "dizzy"
                     ? "Device reaction · plays when you shake the mote."
                     : "Device reaction · plays when you stroke the screen.")
                    .foregroundStyle(Cue9Theme.soft)
            } else if actions.isEmpty {
                Text("Not used by an action yet.")
                    .foregroundStyle(Cue9Theme.warning)
            } else {
                Text("Used by \(actions.map(\.label).joined(separator: ", ")).")
                    .foregroundStyle(Cue9Theme.muted)
            }
        }
        .font(Cue9Font.font(10.5))
        .lineLimit(2)
    }

    private var colourCaption: String {
        if !model.dshOnline { return "Connect the DSH plugin in Device." }
        if !model.usbConnected { return "The mote isn't connected." }
        if selectedIsDeviceOnly {
            return "Plays \(model.selectedAnimationTitle) on the mote with expression #\(inkHex) on background #\(backgroundHex)."
        }
        if colourAction == nil { return "Map this animation to an action first." }
        return "Sends \(model.selectedAnimationTitle) with expression #\(inkHex) on background #\(backgroundHex)."
    }

    // MARK: - Footer

    private func footer(
        testTitle: String,
        testEnabled: Bool,
        hint: String,
        returnNamespace: Namespace.ID,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Divider()
                .overlay(Cue9Theme.line)
                .padding(.top, 12)

            TestFeedbackView(state: model.testState)

            HStack(spacing: 8) {
                Button(action: action) {
                    HStack(spacing: 7) {
                        if model.testState == .sending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Cue9Theme.infoInk)
                        } else {
                            Image(systemName: "bolt")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(model.testState == .sending ? "Sending…" : testTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TestButtonStyle())
                .disabled(!testEnabled)
                .opacity(testEnabled ? 1 : 0.45)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(testEnabled ? testTitle : hint)

                if model.previewing && model.dshOnline {
                    ReturnToLiveButton(
                        namespace: returnNamespace,
                        fullWidth: false,
                        enabled: model.testState != .sending
                    ) {
                        model.resumeLive()
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(Cue9Theme.soft)
    }

    private func ensureMappingSelection() {
        guard !model.selectedAction.isEmpty else { return }
        if model.isDeviceOnly(model.selectedAnimation) { return }
        let currentMapping = model.mapping[model.selectedAction] ?? []
        if !currentMapping.contains(model.selectedAnimation),
           let first = currentMapping.first ?? model.animations.first?.id {
            model.selectAnimation(first)
        }
    }

    private func syncPreview(reset: Bool) {
        if stageKind == .live {
            model.configureLivePreview(reset: reset)
        } else if stageKind == .localPreview {
            model.configurePreview(reset: reset)
        }
    }
}

private enum MoteTab: String, CaseIterable, Identifiable {
    case mapping = "Mapping"
    case colour = "Colours"

    var id: String { rawValue }
}

private enum ColourLayer: String, CaseIterable, Identifiable {
    case ink = "Expression"
    case background = "Background"

    var id: String { rawValue }
}

private enum StageKind {
    case empty
    case waiting
    case live
    case localPreview
}


private struct ReturnToLiveButton: View {
    let namespace: Namespace.ID
    let fullWidth: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Return to live")
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .matchedGeometryEffect(id: "returnToLive", in: namespace)
        .help("Return the mote to DSH")
        .accessibilityLabel("Return to live")
    }
}

private struct SaveStatusView: View {
    let state: SaveState

    private var icon: String {
        switch state {
        case .sent: return "checkmark.circle.fill"
        case .savedLocally: return "checkmark"
        case .pending: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .idle: return ""
        }
    }

    private var color: Color {
        switch state {
        case .sent: return Cue9Theme.success
        case .pending: return Cue9Theme.warning
        case .failed: return Cue9Theme.danger
        default: return Cue9Theme.muted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(state.text)
                .font(Cue9Font.font(10.5))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .help(state.text)
    }
}

private struct TestFeedbackView: View {
    let state: TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(state.text)
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .sent:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(state.text)
            }
            .font(Cue9Font.font(10.5, .medium))
            .foregroundStyle(Cue9Theme.success)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.top, 1)
                Text(message)
                    .font(Cue9Font.font(10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Cue9Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ShellToggle: View {
    @Binding var isOn: Bool
    let enabled: Bool
    let finish: ShellFinish

    var body: some View {
        HStack(spacing: 8) {
            CatMark()
                .fill(isOn ? Cue9Theme.onStage : Cue9Theme.onStage.opacity(0.55))
                .frame(width: 15, height: 14)
            Text("Shell")
                .font(Cue9Font.font(11, .medium))
                .foregroundStyle(isOn ? Cue9Theme.onStage : Cue9Theme.onStage.opacity(0.62))
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Cue9Theme.orange)
                .disabled(!enabled)
                .accessibilityLabel("Device shell")
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .background(
            Color(hex: 0x141412),
            in: Capsule()
        )
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
        .help(isOn ? "Hide the device shell" : "Show the device shell")
        .accessibilityElement(children: .contain)
    }
}

private struct CatMark: Shape {
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

private struct StageFooter: View {
    let mode: (String, Color)
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mode.1)
                .frame(width: 6, height: 6)
            Text(mode.0)
                .font(Cue9Font.font(10.5, .medium))
                .foregroundStyle(Cue9Theme.onStage)
            Text("·")
                .font(Cue9Font.font(10))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.42))
            Text(detail)
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.60))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(
            Color(hex: 0x141412),
            in: Capsule()
        )
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct MoteLiveRail: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection
    let returnNamespace: Namespace.ID

    private var mode: (String, Color) {
        if !model.dshOnline {
            return model.isReconnecting ? ("Reconnecting", Cue9Theme.warning) : ("Offline", Cue9Theme.warning)
        }
        if model.previewing { return ("Previewing", Cue9Theme.orange) }
        return ("Following DSH", Cue9Theme.success)
    }

    private var nowAction: String {
        if !model.dshOnline { return model.isReconnecting ? "Looking for DSH…" : "DSH is offline" }
        return model.liveActionTitle ?? "Waiting for a cue"
    }

    private var nowAnimation: String {
        if !model.dshOnline { return "Open Device to reconnect." }
        if model.previewing { return model.liveAnimationTitle ?? "Previewing on the mote" }
        return model.liveAnimationTitle ?? "The mote will move when DSH starts working."
    }

    var body: some View {
        VStack(spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionLabel(text: "Now")
                        Spacer(minLength: 6)
                        Pill(text: mode.0, color: mode.1)
                    }

                    Text(nowAction)
                        .font(Cue9Font.font(20, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                        .lineLimit(2)
                        .padding(.top, 16)

                    Text(nowAnimation)
                        .font(Cue9Font.font(12))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    if !model.dshOnline {
                        HStack(spacing: 8) {
                            Button("Retry") {
                                Task { await model.retryConnection() }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button("Open Device") {
                                section = .device
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.top, 14)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionLabel(text: "Recent")
                        Spacer()
                        Text(model.recentCues.isEmpty ? "—" : "LAST \(min(model.recentCues.count, 6))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Cue9Theme.soft)
                    }

                    if model.recentCues.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No recent cues yet.")
                                .font(Cue9Font.font(12, .medium))
                                .foregroundStyle(Cue9Theme.ink2)
                            Text("Cues appear here as DSH runs.")
                                .font(Cue9Font.font(11))
                                .foregroundStyle(Cue9Theme.muted)
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
                        .padding(.top, 5)
                    }

                    Divider()
                        .overlay(Cue9Theme.line)
                        .padding(.top, 12)

                    if model.previewing && model.dshOnline {
                        ReturnToLiveButton(
                            namespace: returnNamespace,
                            fullWidth: true,
                            enabled: model.testState != .sending
                        ) {
                            model.resumeLive()
                        }
                        .padding(.top, 10)
                    } else {
                        Text("History stays on this Mac.")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .padding(.top, 10)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func recentRow(_ cue: CueEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(model.palette[cue.animation]?.color ?? Cue9Theme.soft)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.actionLabel(cue.action))
                    .font(Cue9Font.font(12, .medium))
                    .foregroundStyle(Cue9Theme.ink2)
                    .lineLimit(1)
                Text(model.animationLabel(cue.animation))
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(cue.ageText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Cue9Theme.soft)
        }
        .padding(.vertical, 8)
    }
}


private struct ActionPickerPopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Actions")
                    .font(Cue9Font.font(13, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Spacer()
                Text("\(model.mappedActionCount)/\(model.actions.count) mapped")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.actions) { action in
                        let selected = model.selectedAction == action.id
                        let unmapped = model.isUnmapped(action.id)
                        Button {
                            model.selectAction(action.id)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(unmapped ? Cue9Theme.warning : Cue9Theme.success)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.label)
                                        .font(Cue9Font.font(11.5, .medium))
                                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                                        .lineLimit(1)
                                    Text(model.mappingSummary(for: action.id))
                                        .font(Cue9Font.font(10))
                                        .foregroundStyle(Cue9Theme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Cue9Theme.orange)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? Cue9Theme.ink.opacity(0.06) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(14)
        .frame(width: 306)
    }
}

private struct AnimationPickerPopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Animations")
                    .font(Cue9Font.font(13, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Spacer()
                Text("\(model.animations.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.animations) { animation in
                        let selected = model.selectedAnimation == animation.id
                        Button {
                            model.selectAnimation(animation.id)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                ColourPairSwatch(
                                    ink: model.palette[animation.id]?.color ?? animation.color.color,
                                    background: model.backgrounds[animation.id]?.color ?? CueCatalog.defaultBackground.color,
                                    size: 12
                                )
                                Text(animation.label)
                                    .font(Cue9Font.font(11.5, .medium))
                                    .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                                Spacer(minLength: 4)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Cue9Theme.orange)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? Cue9Theme.ink.opacity(0.06) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(selected ? "Selected" : "")
                    }
                }
            }
            .frame(maxHeight: 330)
        }
        .padding(14)
        .frame(width: 258)
    }
}

private struct UnmappedActionsPopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Unmapped actions")
                    .font(Cue9Font.font(13, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Spacer()
                Text("\(model.unmappedActions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.unmappedActions) { action in
                        Button {
                            model.selectAction(action.id)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle.dashed")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Cue9Theme.warning)
                                Text(action.label)
                                    .font(Cue9Font.font(11.5, .medium))
                                    .foregroundStyle(Cue9Theme.ink2)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Cue9Theme.soft)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 286)
    }
}
