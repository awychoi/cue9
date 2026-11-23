import AppKit
import SwiftUI

struct DeviceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: FirmwareFlasher

    @State private var advancedOpen = false
    @State private var detailsOpen = false
    @State private var confirmFlash = false
    @State private var dshURL = ""
    @State private var showPortMenu = false

    private let pluginRepo = URL(string: "https://github.com/awychoi/dsh-cue9-mote")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Device",
                    subtitle: "Reactions, software, and advanced settings.",
                    trailing: AnyView(Pill(
                        text: model.moteConnected ? "cue9 connected" : "cue9 not found",
                        color: model.moteConnected ? Cue9Theme.success : Cue9Theme.warning
                    ))
                )

                overviewCard
                reactionsCard
                softwareCard
                advancedCard
            }
            .padding(30)
        }
        .onAppear {
            flasher.refreshPorts()
            dshURL = model.dshURLString
        }
        .onChange(of: flasher.isFlashing) { _, flashing in
            if flashing {
                withAnimation(.easeInOut(duration: 0.12)) { detailsOpen = true }
            }
        }
        .alert("Reinstall cue9's software?", isPresented: $confirmFlash) {
            Button("Cancel", role: .cancel) {}
            Button("Reinstall", role: .destructive) {
                Task { await model.flashFirmware() }
            }
        } message: {
            Text("This replaces the software on \(flasher.selectedPort.isEmpty ? "the selected USB port" : flasher.selectedPort) with the version in this app. It takes about a minute. Keep cue9 connected. Colours and reactions are kept.")
        }
    }

    // MARK: - Overview

    private var overviewCard: some View {
        Card {
            HStack(alignment: .center, spacing: 26) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Cue9Theme.stage)
                        .frame(width: 112, height: 112)
                    if let shell = Cue9Assets.image("cat-shell-white") {
                        Image(nsImage: shell)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 88, height: 104)
                    } else {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Cue9Theme.orange)
                    }
                    Circle()
                        .fill(model.moteConnected ? Cue9Theme.success : Cue9Theme.warning)
                        .frame(width: 9, height: 9)
                        .offset(x: 44, y: -44)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("cue9")
                        .font(Cue9Font.font(20, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("DeepSeek desk companion.")
                        .font(Cue9Font.font(12))
                        .foregroundStyle(Cue9Theme.muted)
                    HStack(spacing: 14) {
                        overviewFact(
                            icon: model.linkTransport == "wifi" ? "wifi" : "powerplug",
                            value: model.moteConnected
                                ? (model.linkTransport == "wifi" ? "On Wi-Fi" : "On USB")
                                : "Not connected"
                        )
                        overviewFact(icon: "display", value: "360 × 360")
                        overviewFact(icon: "sparkles", value: "\(model.actions.count) moments")
                    }
                    .padding(.top, 6)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text("Bundled software")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Cue9Theme.soft)
                    Text("Version 1.0")
                        .font(Cue9Font.font(13, .semibold))
                        .foregroundStyle(Cue9Theme.ink2)
                    Text("Bundled with this app")
                        .font(Cue9Font.font(9.5))
                        .foregroundStyle(Cue9Theme.soft)
                        .lineLimit(1)
                }
            }
        }
    }

    private func overviewFact(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Cue9Theme.soft)
            Text(value)
                .font(Cue9Font.font(10))
                .foregroundStyle(Cue9Theme.muted)
        }
    }

    // MARK: - Reactions

    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { Double(model.shakeSensitivity) },
            set: { model.shakeSensitivity = Int($0.rounded()) }
        )
    }

    private var dizzyBinding: Binding<Double> {
        Binding(
            get: { model.dizzySeconds },
            set: { model.dizzySeconds = $0 }
        )
    }

    private var happyBinding: Binding<Double> {
        Binding(
            get: { model.happySeconds },
            set: { model.happySeconds = $0 }
        )
    }

    private var reactionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reactions")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("Shake and touch reactions.")
                            .font(Cue9Font.font(11.5))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                    Spacer(minLength: 12)
                    if model.deviceAnimations.count >= 2 {
                        HStack(spacing: 7) {
                            ForEach(model.deviceAnimations) { animation in
                                Button {
                                    model.previewDeviceAnimation(animation.id)
                                } label: {
                                    Label("Try \(FaceCopy.reactionTrigger(animation.id).lowercased())", systemImage: "play.fill")
                                        .font(Cue9Font.font(10.5, .medium))
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!canTryOnDevice)
                                .help(canTryOnDevice
                                      ? "Play the \(animation.label) face on cue9"
                                      : "Connect DeepSeek and cue9 first")
                            }
                        }
                    }
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 10)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        behaviourSlider(
                            title: "Shake sensitivity",
                            help: "How easily a shake makes cue9 dizzy. 1 is least sensitive. 5 is most.",
                            value: sensitivityBinding,
                            range: 1...5,
                            step: 1,
                            readout: "\(model.shakeSensitivity) / 5",
                            onCommit: { model.updateBehaviour(sensitivity: model.shakeSensitivity) }
                        )
                        behaviourSlider(
                            title: "Dizzy reaction",
                            help: "How long the dizzy face stays after a shake.",
                            value: dizzyBinding,
                            range: 2...10,
                            step: 0.5,
                            readout: String(format: "%.1f s", model.dizzySeconds),
                            onCommit: { model.updateBehaviour(dizzySeconds: model.dizzySeconds) }
                        )
                        behaviourSlider(
                            title: "Happy reaction",
                            help: "How long the happy face stays after a stroke.",
                            value: happyBinding,
                            range: 1...4,
                            step: 0.1,
                            readout: String(format: "%.1f s", model.happySeconds),
                            onCommit: { model.updateBehaviour(happySeconds: model.happySeconds) }
                        )
                    }
                    .frame(minWidth: 700)

                    VStack(spacing: 10) {
                        behaviourSlider(
                            title: "Shake sensitivity",
                            help: "How easily a shake makes cue9 dizzy. 1 is least sensitive. 5 is most.",
                            value: sensitivityBinding,
                            range: 1...5,
                            step: 1,
                            readout: "\(model.shakeSensitivity) / 5",
                            onCommit: { model.updateBehaviour(sensitivity: model.shakeSensitivity) }
                        )
                        behaviourSlider(
                            title: "Dizzy reaction",
                            help: "How long the dizzy face stays after a shake.",
                            value: dizzyBinding,
                            range: 2...10,
                            step: 0.5,
                            readout: String(format: "%.1f s", model.dizzySeconds),
                            onCommit: { model.updateBehaviour(dizzySeconds: model.dizzySeconds) }
                        )
                        behaviourSlider(
                            title: "Happy reaction",
                            help: "How long the happy face stays after a stroke.",
                            value: happyBinding,
                            range: 1...4,
                            step: 0.1,
                            readout: String(format: "%.1f s", model.happySeconds),
                            onCommit: { model.updateBehaviour(happySeconds: model.happySeconds) }
                        )
                    }
                }
                .padding(.top, 10)

                HStack(spacing: 5) {
                    Image(systemName: model.dshOnline ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 9.5, weight: .medium))
                    Text(model.dshOnline
                         ? "Applies immediately."
                         : "Connect DeepSeek Harness to adjust these.")
                        .font(Cue9Font.font(10.5))
                }
                .foregroundStyle(model.dshOnline ? Cue9Theme.soft : Cue9Theme.warning)
                .padding(.top, 8)
            }
            .disabled(!model.dshOnline)
            .opacity(model.dshOnline ? 1 : 0.55)
        }
    }

    private var canTryOnDevice: Bool {
        model.dshOnline && model.moteConnected && model.testState != .sending
    }

    private func behaviourSlider(
        title: String,
        help: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Cue9Font.font(11.5, .medium))
                    .foregroundStyle(Cue9Theme.ink2)
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Cue9Theme.soft)
                    .help(help)
                Spacer(minLength: 4)
                Text(readout)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.muted)
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            .tint(Cue9Theme.orange)
            .help(help)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Software

    private var portMenu: some View {
        Button {
            showPortMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(flasher.selectedPort.isEmpty ? "No USB connection found" : flasher.selectedPort)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(flasher.selectedPort.isEmpty ? Cue9Theme.soft : Cue9Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Cue9Theme.soft)
            }
            .padding(.horizontal, 9)
            .frame(width: 270, height: 32)
            .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Cue9Theme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(flasher.isFlashing)
        .popover(isPresented: $showPortMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                if flasher.ports.isEmpty {
                    Text("No USB connection found")
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.soft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                } else {
                    ForEach(flasher.ports, id: \.self) { port in
                        Button {
                            flasher.selectedPort = port
                            showPortMenu = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(port)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Cue9Theme.ink2)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if port == flasher.selectedPort {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Cue9Theme.orange)
                                }
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
            .frame(width: 290)
        }
        .help("Choose cue9's USB port")
    }

    private func flashStatusColor(_ status: String) -> Color {
        if status.localizedCaseInsensitiveContains("success") { return Cue9Theme.success }
        if status.localizedCaseInsensitiveContains("failed") { return Cue9Theme.danger }
        return Cue9Theme.muted
    }

    private func flashStatusIcon(_ status: String) -> String {
        if status.localizedCaseInsensitiveContains("success") { return "checkmark.circle.fill" }
        if status.localizedCaseInsensitiveContains("failed") { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var softwareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Software")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("Reinstall the bundled software. It takes about a minute. Faces and reactions are kept.")
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 7) {
                        Button {
                            confirmFlash = true
                        } label: {
                            Label(flasher.isFlashing ? "Reinstalling…" : "Reinstall software…", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(flasher.isFlashing || flasher.selectedPort.isEmpty)
                        .opacity(flasher.isFlashing || flasher.selectedPort.isEmpty ? 0.45 : 1)
                        .help(flasher.selectedPort.isEmpty
                              ? "Connect cue9 with a USB cable first"
                              : "Reinstall the software bundled with this app")

                        if flasher.isFlashing {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text("Don't unplug cue9 while it's working.")
                                    .font(Cue9Font.font(10.5))
                            }
                            .foregroundStyle(Cue9Theme.warning)
                        }
                    }
                }

                if flasher.isFlashing {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Cue9Theme.orange)
                        .padding(.top, 12)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                HStack(alignment: .center, spacing: 9) {
                    Text("USB port")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Cue9Theme.soft)
                    portMenu
                    Button {
                        flasher.refreshPorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Look for cue9's USB port again")
                    Spacer()
                }
                .padding(.top, 13)

                if let status = flasher.status {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: flashStatusIcon(status))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.top, 1)
                        Text(status)
                            .font(Cue9Font.font(11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(flashStatusColor(status))
                    .padding(.top, 9)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        detailsOpen.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Technical details")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.muted)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Cue9Theme.soft)
                            .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                if detailsOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        technicalRow("Image", "firmware.bin")
                        technicalRow("SHA-256", flasher.firmwareHash)
                        technicalRow("Screen", "360 × 360 · 30 fps")
                        HStack(alignment: .top) {
                            Text("Log")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 92, alignment: .leading)
                            ScrollView {
                                Text(flasher.log.isEmpty ? "Ready." : flasher.log)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Cue9Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 130)
                        }
                    }
                    .padding(12)
                    .background(Cue9Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 10)
                }
            }
        }
    }

    private func technicalRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Cue9Theme.soft)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Cue9Theme.muted)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        advancedOpen.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Cue9Theme.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Advanced")
                                .font(Cue9Font.font(12.5, .medium))
                                .foregroundStyle(Cue9Theme.ink2)
                            Text("DeepSeek address, USB bridge, plugin source")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Cue9Theme.soft)
                            .rotationEffect(.degrees(advancedOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if advancedOpen {
                    Divider()
                        .overlay(Cue9Theme.line)
                        .padding(.top, 13)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("DeepSeek address")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 104, alignment: .leading)
                            TextField("http://127.0.0.1:53614", text: $dshURL)
                                .textFieldStyle(Cue9TextFieldStyle())
                                .font(.system(size: 10.5, design: .monospaced))
                                .frame(maxWidth: 360)
                            Button("Apply") {
                                model.updateDSHURL(dshURL)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }

                        HStack(spacing: 10) {
                            Text("Plugin source")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 104, alignment: .leading)
                            CopySourceRow(url: pluginRepo)
                        }

                        HStack(spacing: 10) {
                            Text("USB bridge")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 104, alignment: .leading)
                            Button("Release USB") {
                                Task { await model.releaseUSB() }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.dshOnline)
                            Button("Reconnect") {
                                Task { await model.reconnectUSB() }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.dshOnline)
                        }

                        if let error = model.pluginError, !error.isEmpty {
                            Text(error)
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }
}
