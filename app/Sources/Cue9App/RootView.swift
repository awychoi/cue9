import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case mote = "Mote"
    case device = "Device"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .mote: return "sparkles"
        case .device: return "cpu"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var section: AppSection
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init(model: AppModel, initialSection: AppSection = .mote) {
        _model = ObservedObject(wrappedValue: model)
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        // Always the same view shape: switching to or from System must not
        // rebuild the page and lose its scroll position.
        content.preferredColorScheme(appearance.colorScheme)
    }

    private var content: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, section: $section)
            Divider().overlay(Cue9Theme.line)
            Group {
                switch section {
                case .mote:
                    MoteView(model: model, section: $section)
                case .device:
                    DeviceView(model: model, flasher: model.flasher)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Cue9Font.font(13))
        .tint(Cue9Theme.orange)
        .background(Cue9Theme.paper)
        .overlay(
            WindowAppearanceSetter(appearance: appearance)
                .frame(width: 0, height: 0),
            alignment: .topLeading
        )
        .frame(minWidth: 1200, minHeight: 780)
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 24)

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14.5, weight: .medium))
                                .frame(width: 18)
                            Text(item.rawValue)
                                .font(Cue9Font.font(13.5, .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == item ? Cue9Theme.ink : Cue9Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 41, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(section == item ? Cue9Theme.surface2 : .clear)
                        )
                        .overlay(alignment: .leading) {
                            if section == item {
                                Capsule()
                                    .fill(Cue9Theme.orange)
                                    .frame(width: 3, height: 18)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .keyboardShortcut(item == .mote ? "1" : "2", modifiers: .command)
                    .accessibilityValue(section == item ? "Selected" : "")
                }
            }

            if section == .device {
                SidebarNowCard(model: model, section: $section)
                    .padding(.horizontal, 14)
                    .padding(.top, 20)
            }

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                SidebarStatusBox(model: model, section: $section)
                AppearanceControl()
                ShellFinishControl()
                MakerCredit()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 222)
        .background(Cue9Theme.surface)
    }
}

struct SidebarNowCard: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    private var mode: (String, Color) {
        if !model.dshOnline {
            if model.isReconnecting { return ("Reconnecting", Cue9Theme.warning) }
            return (model.everConnected ? "Plugin offline" : "Setup needed", Cue9Theme.warning)
        }
        if model.previewing { return ("Previewing", Cue9Theme.orange) }
        return ("Following DSH", Cue9Theme.success)
    }

    private var nowTitle: String {
        if !model.dshOnline {
            return model.isReconnecting ? "Looking for DSH…" : "DSH is not connected"
        }
        return model.liveActionTitle ?? "Waiting for a cue"
    }

    private var nowDetail: String {
        if !model.dshOnline {
            return model.everConnected
                ? "Your mappings still work. Retry or open Device."
                : "Install the DSH plugin to bring the mote online."
        }
        if model.previewing {
            return model.liveAnimationTitle ?? "Previewing on the mote."
        }
        if let animation = model.liveAnimationTitle {
            return animation
        }
        return "The mote will move when DSH starts working."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                SectionLabel(text: "Now")
                Spacer(minLength: 4)
                Pill(text: mode.0, color: mode.1)
            }

            Text(nowTitle)
                .font(Cue9Font.font(13.5, .semibold))
                .foregroundStyle(Cue9Theme.ink)
                .lineLimit(2)
                .padding(.top, 10)

            Text(nowDetail)
                .font(Cue9Font.font(11))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            if model.previewing && model.dshOnline {
                Button {
                    model.resumeLive()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Return to live")
                    }
                    .font(Cue9Font.font(10.5, .medium))
                    .foregroundStyle(Cue9Theme.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 9)
                .disabled(model.testState == .sending)
                .help("Return the mote to DSH")
            } else if !model.dshOnline {
                HStack(spacing: 8) {
                    Button("Retry") {
                        Task { await model.retryConnection() }
                    }
                    .buttonStyle(.plain)
                    .font(Cue9Font.font(10.5, .medium))
                    .foregroundStyle(Cue9Theme.orange)

                    Text("·")
                        .font(Cue9Font.font(10))
                        .foregroundStyle(Cue9Theme.soft)

                    Button("Open Device") {
                        section = .device
                    }
                    .buttonStyle(.plain)
                    .font(Cue9Font.font(10.5, .medium))
                    .foregroundStyle(Cue9Theme.muted)
                }
                .padding(.top, 8)
            }

            Divider()
                .overlay(Cue9Theme.line)
                .padding(.top, 13)

            HStack {
                SectionLabel(text: "Recent")
                Spacer()
                Text(model.recentCues.isEmpty ? "—" : "LAST \(min(model.recentCues.count, 3))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.top, 12)

            if model.recentCues.isEmpty {
                Text("Cues appear here as DSH runs.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentCues.prefix(3).enumerated()), id: \.element.id) { index, cue in
                        if index > 0 {
                            Divider()
                                .overlay(Cue9Theme.line)
                                .padding(.vertical, 6)
                        }
                        recentRow(cue)
                    }
                }
                .padding(.top, 7)
            }
        }
        .padding(12)
        .background(
            Cue9Theme.surface2,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private func recentRow(_ cue: CueEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(model.palette[cue.animation]?.color ?? Cue9Theme.soft)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.actionLabel(cue.action))
                    .font(Cue9Font.font(11, .medium))
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
                .lineLimit(1)
        }
    }
}

struct SidebarStatusBox: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    private var mote: (String, Color) {
        if model.pluginState != nil {
            if model.moteConnected { return ("Connected", Cue9Theme.success) }
            return model.linkTransport == "wifi"
                ? ("Not reachable", Cue9Theme.warning)
                : ("Not found", Cue9Theme.warning)
        }
        if !model.flasher.ports.isEmpty {
            return ("USB found", Cue9Theme.warning)
        }
        return (model.isReconnecting ? "Checking" : "Unknown", Cue9Theme.soft)
    }

    private var plugin: (String, Color) {
        if model.dshOnline { return ("Connected", Cue9Theme.success) }
        if model.isReconnecting { return ("Reconnecting", Cue9Theme.warning) }
        return ("Not connected", Cue9Theme.warning)
    }

    var body: some View {
        VStack(spacing: 8) {
            row(name: "Mote", value: mote.0, color: mote.1)
            row(name: "DSH plugin", value: plugin.0, color: plugin.1)
        }
        .padding(12)
        .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private func row(name: String, value: String, color: Color) -> some View {
        Button {
            section = .device
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .frame(width: 64, alignment: .leading)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Spacer(minLength: 1)
                Text(value)
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.ink2)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Device")
        .accessibilityLabel("\(name): \(value). Open Device.")
    }
}

struct AppearanceControl: View {
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        HStack {
            Text("Appearance")
                .font(Cue9Font.font(11))
                .foregroundStyle(Cue9Theme.muted)
            Spacer()
            HStack(spacing: 1) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            appearanceRaw = mode.rawValue
                        }
                    } label: {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 23)
                            .foregroundStyle(appearance == mode ? Cue9Theme.ink : Cue9Theme.soft)
                            .background {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(appearance == mode ? Cue9Theme.ink.opacity(0.10) : .clear)
                            }
                            .overlay {
                                if appearance == mode {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(Cue9Theme.lineStrong, lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.title) appearance")
                    .accessibilityLabel("\(mode.title) appearance")
                    .accessibilityValue(appearance == mode ? "Selected" : "")
                }
            }
            .padding(2)
            .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 4)
    }
}

struct ShellFinishControl: View {
    @AppStorage("shellFinish") private var finishRaw = ShellFinish.white.rawValue

    private var finish: ShellFinish {
        ShellFinish(rawValue: finishRaw) ?? .white
    }

    var body: some View {
        HStack {
            Text("Shell")
                .font(Cue9Font.font(11))
                .foregroundStyle(Cue9Theme.muted)
            Spacer()
            HStack(spacing: 5) {
                ForEach(ShellFinish.allCases) { item in
                    Button {
                        finishRaw = item.rawValue
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(item.swatch)
                            .frame(width: 28, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        finish == item ? Cue9Theme.orange : Cue9Theme.lineStrong,
                                        lineWidth: finish == item ? 1.8 : 1
                                    )
                            )
                            .overlay {
                                if finish == item {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(item == .white ? Color(hex: 0x3A3A36) : Color.white)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(item.title) shell")
                    .accessibilityLabel("\(item.title) shell")
                    .accessibilityValue(finish == item ? "Selected" : "")
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct BrandLockup: View {
    @Environment(\.colorScheme) private var colorScheme

    private var image: NSImage? {
        Cue9Assets.image(colorScheme == .dark ? "cue9-lockup-white" : "cue9-lockup")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 143, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Cue9Theme.orange).frame(width: 6, height: 6)
                    Text("cue9")
                        .font(Cue9Font.font(24, .medium))
                        .foregroundStyle(Cue9Theme.ink)
                }
            }
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Cue9Font.font(30, .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Cue9Theme.ink)
                Text(subtitle)
                    .font(Cue9Font.font(13))
                    .foregroundStyle(Cue9Theme.muted)
            }
            Spacer()
            if let trailing {
                trailing.padding(.top, 7)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Cue9Font.font(12.5, .semibold))
            .foregroundStyle(Cue9Theme.orangeInk)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(configuration.isPressed ? Cue9Theme.orange.opacity(0.8) : Cue9Theme.orange,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TestButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Cue9Font.font(12.5, .semibold))
            .foregroundStyle(Cue9Theme.infoInk)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(configuration.isPressed ? Cue9Theme.info.opacity(0.82) : Cue9Theme.info,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Cue9Font.font(12.5, .medium))
            .foregroundStyle(Cue9Theme.ink2)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(configuration.isPressed ? Cue9Theme.surface2 : Cue9Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
    }
}
