import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case now = "Now"
    case faces = "Faces"
    case clockWeather = "Clock & Weather"
    case connect = "Connect"
    case device = "Device"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .now: return "sparkles"
        case .faces: return "face.smiling"
        case .clockWeather: return "clock"
        case .connect: return "link"
        case .device: return "cpu"
        }
    }

    var blurb: String {
        switch self {
        case .now: return "Live view."
        case .faces: return "Faces and colours."
        case .clockWeather: return "Time and weather."
        case .connect: return "DeepSeek, USB, and Wi-Fi."
        case .device: return "Reactions and software."
        }
    }

    var cliName: String {
        switch self {
        case .now: return "now"
        case .faces: return "faces"
        case .clockWeather: return "clock"
        case .connect: return "connect"
        case .device: return "device"
        }
    }

    var group: String {
        switch self {
        case .now, .faces, .clockWeather: return "Your cue9"
        case .connect, .device: return "Set up"
        }
    }

    var shortcut: KeyEquivalent {
        let character: Character
        switch self {
        case .now: character = "1"
        case .faces: character = "2"
        case .clockWeather: character = "3"
        case .connect: character = "4"
        case .device: character = "5"
        }
        return KeyEquivalent(character)
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var section: AppSection
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init(model: AppModel, initialSection: AppSection = .now) {
        _model = ObservedObject(wrappedValue: model)
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        // Keep the same view shape when the appearance changes so page state
        // and scroll positions survive the switch.
        content.preferredColorScheme(appearance.colorScheme)
    }

    private var content: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, section: $section)
            Rectangle()
                .fill(Cue9Theme.line)
                .frame(width: 1)
            Group {
                switch section {
                case .now:
                    NowView(model: model, section: $section)
                case .faces:
                    FacesView(model: model, section: $section)
                case .clockWeather:
                    ClockWeatherView(model: model, section: $section)
                case .connect:
                    ConnectView(model: model, flasher: model.flasher)
                case .device:
                    DeviceView(model: model, flasher: model.flasher)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Cue9Font.font(13))
        .tint(Cue9Theme.orange)
        .background(appBackground)
        .overlay(
            WindowAppearanceSetter(appearance: appearance)
                .frame(width: 0, height: 0),
            alignment: .topLeading
        )
        .frame(minWidth: 1200, minHeight: 780)
    }

    private var appBackground: some View {
        Cue9Theme.paper
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [Cue9Theme.orange.opacity(0.045), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 720
                )
                .allowsHitTesting(false)
            }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection
    @State private var showPreferences = false

    private var groups: [(String, [AppSection])] {
        let order: [AppSection] = [.now, .faces, .clockWeather, .connect, .device]
        return ["Your cue9", "Set up"].map { name in
            (name, order.filter { $0.group == name })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.0.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Cue9Theme.soft)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                        ForEach(group.1) { item in
                            navItem(item)
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                SidebarConnection(model: model) {
                    section = .connect
                }
                Button {
                    showPreferences = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 12, weight: .medium))
                        Text("Appearance")
                            .font(Cue9Font.font(11.5, .medium))
                        Spacer()
                        Image(systemName: "gearshape")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Cue9Theme.soft)
                    }
                    .foregroundStyle(Cue9Theme.muted)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Cue9Theme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPreferences, arrowEdge: .bottom) {
                    PreferencesPanel()
                }
                .help("Appearance, preview shell, and about")

                MakerCredit()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 236)
        .background(Cue9Theme.surface)
    }

    private func navItem(_ item: AppSection) -> some View {
        let selected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Cue9Theme.orange.opacity(0.13) : .clear)
                        .frame(width: 27, height: 27)
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Cue9Theme.orange : Cue9Theme.muted)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.rawValue)
                        .font(Cue9Font.font(12.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                    Text(item.blurb)
                        .font(Cue9Font.font(9.5))
                        .foregroundStyle(Cue9Theme.soft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Cue9Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Cue9Theme.orange)
                        .frame(width: 3, height: 19)
                        .offset(x: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .keyboardShortcut(item.shortcut, modifiers: .command)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint(item.blurb)
    }
}

struct SidebarConnection: View {
    @ObservedObject var model: AppModel
    let action: () -> Void

    private var deepSeek: (String, Color) {
        if model.dshOnline { return ("Connected", Cue9Theme.success) }
        if model.isReconnecting { return ("Looking…", Cue9Theme.warning) }
        return ("Offline", Cue9Theme.warning)
    }

    private var cue9: (String, Color) {
        if model.pluginState != nil {
            if model.moteConnected {
                return (model.linkTransport == "wifi" ? "On Wi-Fi" : "On USB", Cue9Theme.success)
            }
            return ("Not found", Cue9Theme.warning)
        }
        if !model.flasher.ports.isEmpty { return ("USB found", Cue9Theme.warning) }
        return ("Unknown", Cue9Theme.soft)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(deepSeek.1).frame(width: 6, height: 6)
                    Text("DeepSeek")
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(Cue9Theme.muted)
                    Spacer(minLength: 4)
                    Text(deepSeek.0)
                        .font(Cue9Font.font(10.5, .medium))
                        .foregroundStyle(Cue9Theme.ink2)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle().fill(cue9.1).frame(width: 6, height: 6)
                    Text("cue9")
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(Cue9Theme.muted)
                    Spacer(minLength: 4)
                    Text(cue9.0)
                        .font(Cue9Font.font(10.5, .medium))
                        .foregroundStyle(Cue9Theme.ink2)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Cue9Theme.soft)
                }
            }
            .padding(11)
            .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Connect")
        .accessibilityLabel("DeepSeek \(deepSeek.0). cue9 \(cue9.0). Open Connect.")
    }
}

struct PreferencesPanel: View {
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("showDeviceShell") private var shellOn = true
    @AppStorage("shellFinish") private var shellFinishRaw = ShellFinish.white.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    private var finish: ShellFinish {
        ShellFinish(rawValue: shellFinishRaw) ?? .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(Cue9Font.font(12.5, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                HStack(spacing: 1) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                appearanceRaw = mode.rawValue
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                Text(mode.title)
                                    .font(Cue9Font.font(9.5, .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(appearance == mode ? Cue9Theme.ink : Cue9Theme.muted)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(appearance == mode ? Cue9Theme.surface : .clear)
                            }
                            .overlay {
                                if appearance == mode {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Cue9Theme.lineStrong, lineWidth: 1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(appearance == mode ? "Selected" : "")
                    }
                }
                .padding(3)
                .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Divider().overlay(Cue9Theme.line)

            VStack(alignment: .leading, spacing: 9) {
                Text("Shell preview")
                    .font(Cue9Font.font(12.5, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text("Changes the app preview only.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    ForEach(ShellFinish.allCases) { item in
                        Button {
                            shellFinishRaw = item.rawValue
                            if !shellOn { shellOn = true }
                        } label: {
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(item.swatch)
                                    .frame(width: 24, height: 20)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(Cue9Theme.lineStrong, lineWidth: 1)
                                    )
                                Text(item.title)
                                    .font(Cue9Font.font(10.5, .medium))
                                    .foregroundStyle(Cue9Theme.ink2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .background(
                                finish == item ? Cue9Theme.surface2 : Cue9Theme.paper,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(finish == item ? Cue9Theme.orange.opacity(0.65) : Cue9Theme.line, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(finish == item ? "Selected" : "")
                    }
                }

                Toggle("Show the shell in previews", isOn: $shellOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(Cue9Font.font(10.5))
            }

            Divider().overlay(Cue9Theme.line)

            Link(destination: URL(string: "https://wychoi.com")!) {
                HStack(spacing: 4) {
                    Text("Made by wychoi")
                        .font(Cue9Font.font(10.5, .medium))
                        .foregroundStyle(Cue9Theme.muted)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Cue9Theme.soft)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 292)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let trailing {
                trailing.padding(.top, 5)
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
