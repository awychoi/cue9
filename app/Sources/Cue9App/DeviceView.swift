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
    @State private var linkChoice = "usb"
    @State private var hostField = ""
    @State private var showProvision = false
    @State private var ssid = ""
    @State private var psk = ""
    @State private var provisionError: String?
    @State private var showPiSetup = false
    @State private var piPassword = ""
    @State private var piError: String?
    @State private var piInstalling = false
    @State private var keepAwakeOn = false
    @State private var showKeepAwakeWarning = false

    private let pluginRepo = URL(string: "https://github.com/awychoi/dsh-cue9-mote")!

    private var canOpenDSH: Bool {
        DSHLauncher.isInstalled || model.dshOnline
    }

    /// The Pi that feeds the ambient pages. Only shown once the link is set up
    /// and the app's restricted key exists.
    private var ambientTarget: String? {
        guard FileManager.default.fileExists(atPath: PISetup.runKeyPath) else { return nil }
        if let summary = MoteProvisioning.loadSummary(), summary.bridgeTarget.contains("@") {
            return summary.bridgeTarget
        }
        return model.linkHost.contains("@") ? model.linkHost : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Device",
                    subtitle: "The mote, its firmware, and the DSH plugin."
                )

                statusStrip

                pluginCard
                wirelessCard
                behaviourCard
                if let ambientTarget {
                    AmbientCard(target: ambientTarget, keyPath: PISetup.runKeyPath)
                }
                firmwareCard
                advancedCard
            }
            .padding(30)
        }
        .onAppear {
            flasher.refreshPorts()
            dshURL = model.dshURLString
            hostField = model.linkHost
            linkChoice = model.linkTransport
            keepAwakeOn = model.keepAwakeActive
        }
        .onChange(of: model.linkTransport) { _, value in
            linkChoice = value
        }
        .onChange(of: model.keepAwakeActive) { _, value in
            keepAwakeOn = value
        }
        .onChange(of: flasher.isFlashing) { _, flashing in
            if flashing {
                withAnimation(.easeInOut(duration: 0.12)) { detailsOpen = true }
            }
        }
        .alert("Reinstall firmware?", isPresented: $confirmFlash) {
            Button("Cancel", role: .cancel) {}
            Button("Reinstall", role: .destructive) {
                Task { await model.flashFirmware() }
            }
        } message: {
            Text("This replaces the firmware on \(flasher.selectedPort.isEmpty ? "the selected port" : flasher.selectedPort) with the version bundled in this app. Don't unplug the mote. Colours and behaviour settings are kept.")
        }
        .sheet(isPresented: $showProvision) {
            provisionSheet
        }
        .sheet(isPresented: $showPiSetup) {
            piSetupSheet
        }
    }

    // MARK: - Status

    private var statusStrip: some View {
        HStack(spacing: 0) {
            statusCell(
                label: "Mote",
                value: moteValue,
                sub: moteSub,
                dotColor: moteColor,
                valueColor: moteValue == "Not found" ? Cue9Theme.warning : Cue9Theme.ink2
            )
            statusDivider
            statusCell(
                label: "DSH plugin",
                value: model.dshOnline ? "Connected" : (model.isReconnecting ? "Reconnecting" : "Not connected"),
                sub: model.dshOnline || model.everConnected ? model.dshURLString : "Set up in DSH",
                dotColor: model.dshOnline ? Cue9Theme.success : Cue9Theme.warning,
                valueColor: model.dshOnline ? Cue9Theme.ink2 : Cue9Theme.warning
            )
            statusDivider
            statusCell(
                label: "Firmware",
                value: "Bundled 1.0",
                sub: "360 × 360 · 30 fps",
                dotColor: Cue9Theme.soft
            )
        }
        .padding(.vertical, 15)
        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private var moteValue: String {
        if model.pluginState != nil {
            if model.moteConnected { return "Connected" }
            return model.linkTransport == "wifi" ? "Not reachable" : "Not found"
        }
        return flasher.ports.isEmpty ? "Unknown" : "USB found"
    }

    private var moteSub: String {
        if model.pluginState != nil {
            if model.moteConnected {
                if model.linkTransport == "wifi" {
                    let rssi = model.moteRSSI.map { " · \($0) dBm" } ?? ""
                    return "Wi-Fi via \(model.linkHost)\(rssi)"
                }
                return "USB · \(model.usbPort ?? "connected")"
            }
            return model.linkTransport == "wifi" ? "Wi-Fi · check the Pi" : "Check the cable"
        }
        return flasher.ports.isEmpty ? "Via the DSH plugin" : "Plugin not connected"
    }

    private var moteColor: Color? {
        if model.pluginState != nil {
            return model.usbConnected ? Cue9Theme.success : Cue9Theme.warning
        }
        return flasher.ports.isEmpty ? Cue9Theme.soft : Cue9Theme.warning
    }

    private func statusCell(
        label: String,
        value: String,
        sub: String,
        dotColor: Color?,
        valueColor: Color = Cue9Theme.ink2
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                Text(value)
                    .font(Cue9Font.font(12, .medium))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
            .padding(.top, 5)
            Text(sub)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Cue9Theme.soft)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(Cue9Theme.line)
            .frame(width: 1, height: 36)
    }

    // MARK: - Plugin

    private var pluginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DSH plugin")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(model.dshOnline ? Cue9Theme.success : Cue9Theme.danger)
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                            Text(model.dshOnline
                                 ? "Installed and running. It listens to DSH and sends cues to the mote."
                                 : "Copy the URL into DSH's plugin installer, or ask your agent to install it.")
                                .font(Cue9Font.font(12))
                                .foregroundStyle(Cue9Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 15) {
                        if canOpenDSH {
                            Button {
                                openDSH()
                            } label: {
                                Label("Open DSH", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.top, 1)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                HStack(spacing: 9) {
                    SectionLabel(text: "Source")
                    CopySourceRow(url: pluginRepo)
                    Spacer()
                }
                .padding(.top, 13)
            }
        }
    }

    // MARK: - Link

    private var linkSummary: String {
        if model.linkTransport == "wifi" {
            let rssi = model.moteRSSI.map { " · \($0) dBm" } ?? ""
            return model.moteConnected
                ? "Wi-Fi via \(model.linkHost)\(rssi)"
                : "Wi-Fi via \(model.linkHost) · mote not connected"
        }
        return model.moteConnected ? "USB · \(model.usbPort ?? "connected")" : "USB · mote not connected"
    }

    private var wirelessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Link")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text(linkSummary)
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Picker("", selection: $linkChoice) {
                        Text("USB").tag("usb")
                        Text("Wi-Fi").tag("wifi")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(model.linkBusy || !model.dshOnline)
                    .onChange(of: linkChoice) { _, value in
                        guard value != model.linkTransport else { return }
                        Task {
                            await model.setLink(
                                transport: value,
                                host: value == "wifi" ? hostField : nil
                            )
                        }
                    }
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                HStack(spacing: 9) {
                    SectionLabel(text: "Pi")
                    TextField("pi@host", text: $hostField)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .padding(.horizontal, 9)
                        .frame(width: 230, height: 30)
                        .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Cue9Theme.line, lineWidth: 1)
                        )
                        .disabled(model.linkBusy)
                        .onSubmit {
                            Task { await model.setLink(transport: "wifi", host: hostField) }
                        }
                    Button("Apply") {
                        Task { await model.setLink(transport: "wifi", host: hostField) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.linkBusy || hostField.isEmpty)
                    Spacer()
                    Button("Set up Pi…") { showPiSetup = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.linkBusy)
                    Button("Provision mote…") { showProvision = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!model.dshOnline)
                }
                .padding(.top, 13)

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep this Mac awake")
                            .font(Cue9Font.font(12, .medium))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("Stops the Mac from sleeping on its own while the DSH plugin is loaded, so the mote keeps following DSH. Uses more power; closing the lid still sleeps.")
                            .font(Cue9Font.font(11))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $keepAwakeOn)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(model.linkBusy || !model.dshOnline)
                        .onChange(of: keepAwakeOn) { _, value in
                            if value && !model.keepAwakeActive {
                                showKeepAwakeWarning = true
                            } else if !value && model.keepAwakeActive {
                                Task {
                                    await model.setKeepAwake(false)
                                    keepAwakeOn = model.keepAwakeActive
                                }
                            }
                        }
                }
                .padding(.top, 13)

                if let error = model.linkError {
                    Text(error)
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.danger)
                        .padding(.top, 8)
                }
            }
        }
        .alert("Keep this Mac awake?", isPresented: $showKeepAwakeWarning) {
            Button("Cancel", role: .cancel) {
                keepAwakeOn = model.keepAwakeActive
            }
            Button("Keep awake") {
                Task {
                    await model.setKeepAwake(true)
                    keepAwakeOn = model.keepAwakeActive
                }
            }
        } message: {
            Text("The mote can only follow DSH while this Mac is awake. This stops the Mac from going to sleep on its own while the cue9 plugin is loaded, so the face keeps working when you're on the other computer.\n\nIt won't stop sleep if you close the lid or the battery runs out, and it uses more power. Turn it off when you don't need it.")
        }
    }

    private var provisionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Provision the mote")
                .font(Cue9Font.font(17, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Writes the Wi-Fi network and the Pi's certificates into the mote's config partition. The mote must be connected over USB.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Network name", text: $ssid)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Cue9Theme.line, lineWidth: 1)
                )
            SecureField("Password", text: $psk)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Cue9Theme.line, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Text(flasher.selectedPort.isEmpty ? "No USB modem found" : flasher.selectedPort)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
                Spacer()
                Button("Cancel") { showProvision = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button(model.linkBusy ? "Working…" : "Flash") {
                    Task {
                        provisionError = nil
                        let ok = await model.provisionMote(ssid: ssid, psk: psk)
                        if ok {
                            showProvision = false
                        } else {
                            provisionError = model.linkError
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(ssid.isEmpty || flasher.selectedPort.isEmpty || model.linkBusy || flasher.isFlashing)
            }

            if let provisionError {
                Text(provisionError)
                    .font(Cue9Font.font(11))
                    .foregroundStyle(Cue9Theme.danger)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            flasher.refreshPorts()
            if let summary = MoteProvisioning.loadSummary() {
                hostField = summary.bridgeTarget
            }
        }
    }

    private func installPi() async {
        piInstalling = true
        piError = nil
        let setup = PISetup(host: hostField, password: piPassword.isEmpty ? nil : piPassword)
        do {
            let (summary, _, _) = try await setup.install()
            model.adoptPiSummary(summary)
            hostField = summary.bridgeTarget
            piPassword = ""
            showPiSetup = false
            await model.setLink(transport: model.linkTransport, host: summary.bridgeTarget)
        } catch {
            piError = error.localizedDescription
        }
        piInstalling = false
    }

    private var piSetupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up the Pi")
                .font(Cue9Font.font(17, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Copies the bridge to \(hostField) and starts it as a user service. SSH access is required. The password is used once and not stored.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Pi password (optional if a key is installed)", text: $piPassword)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Cue9Theme.line, lineWidth: 1)
                )

            HStack(spacing: 8) {
                if piInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing…")
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.muted)
                } else if let piError {
                    Text(piError)
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.danger)
                        .lineLimit(4)
                }
                Spacer()
                Button("Cancel") { showPiSetup = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(piInstalling)
                Button("Install") {
                    Task { await installPi() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(piInstalling || hostField.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: - Behaviour

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

    private var behaviourCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Behaviour")
                        .font(Cue9Font.font(15.5, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("How the mote reacts to movement and touch.")
                        .font(Cue9Font.font(12))
                        .foregroundStyle(Cue9Theme.muted)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 15)

                behaviourSlider(
                    title: "Shake sensitivity",
                    help: "How easily a shake triggers Dizzy. 1 is hardest, 5 is easiest.",
                    scaleHint: "Left is harder; right is easier.",
                    value: sensitivityBinding,
                    range: 1...5,
                    step: 1,
                    readout: "\(model.shakeSensitivity) / 5",
                    onCommit: { model.updateBehaviour(sensitivity: model.shakeSensitivity) }
                )

                behaviourSlider(
                    title: "Dizzy duration",
                    help: "How long Dizzy plays after a shake.",
                    value: dizzyBinding,
                    range: 2...10,
                    step: 0.5,
                    readout: String(format: "%.1f s", model.dizzySeconds),
                    onCommit: { model.updateBehaviour(dizzySeconds: model.dizzySeconds) }
                )

                behaviourSlider(
                    title: "Happy duration",
                    help: "How long Happy plays after a stroke.",
                    value: happyBinding,
                    range: 1...4,
                    step: 0.1,
                    readout: String(format: "%.1f s", model.happySeconds),
                    onCommit: { model.updateBehaviour(happySeconds: model.happySeconds) }
                )

                Text(model.dshOnline
                     ? "Changes apply immediately. No reflash."
                     : "Connect the DSH plugin to adjust these.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(model.dshOnline ? Cue9Theme.soft : Cue9Theme.warning)
                    .padding(.top, 13)
            }
            .disabled(!model.dshOnline)
            .opacity(model.dshOnline ? 1 : 0.55)
        }
    }

    private func behaviourSlider(
        title: String,
        help: String,
        scaleHint: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Cue9Font.font(12, .medium))
                    .foregroundStyle(Cue9Theme.ink2)
                Image(systemName: "info.circle")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Cue9Theme.soft)
                    .help(help)
                Spacer(minLength: 8)
                Text(readout)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.muted)
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            .tint(Cue9Theme.orange)
            .help(help)
            if let scaleHint {
                Text(scaleHint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Cue9Theme.soft)
            }
        }
        .padding(.top, 13)
    }

    // MARK: - Firmware

    private var portMenu: some View {
        Button {
            showPortMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(flasher.selectedPort.isEmpty ? "No USB modem found" : flasher.selectedPort)
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
            .frame(width: 270, height: 30)
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
                    Text("No USB modem found")
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
        .help("Choose the mote's USB port")
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

    private var firmwareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Firmware")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("The Wi-Fi + animation image. Reinstalling takes about a minute and keeps your colours and behaviour settings.")
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 7) {
                        Button {
                            confirmFlash = true
                        } label: {
                            Label(flasher.isFlashing ? "Reinstalling…" : "Reinstall firmware…", systemImage: "bolt.fill")
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(flasher.isFlashing || flasher.selectedPort.isEmpty)
                        .opacity(flasher.isFlashing || flasher.selectedPort.isEmpty ? 0.45 : 1)

                        if flasher.isFlashing {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text("Don't unplug while flashing.")
                                    .font(Cue9Font.font(10.5))
                            }
                            .foregroundStyle(Cue9Theme.warning)
                        }
                    }
                    .padding(.top, 1)
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

                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "USB port")
                    HStack(spacing: 7) {
                        portMenu

                        Button {
                            flasher.refreshPorts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Refresh USB ports")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.top, 15)

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
                        technicalRow("Image", "pip_live-te.bin")
                        technicalRow("SHA-256", flasher.firmwareHash)
                        technicalRow("Write address", "0x10000 · app only")
                        HStack(alignment: .top) {
                            Text("Flash log")
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
                    HStack(spacing: 12) {
                        Text("Advanced")
                            .font(Cue9Font.font(11, .medium))
                            .foregroundStyle(Cue9Theme.ink2)
                        Text("DSH address, plugin source, USB bridge")
                            .font(Cue9Font.font(10))
                            .foregroundStyle(Cue9Theme.soft)
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
                            Text("DSH address")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 92, alignment: .leading)
                            TextField("DSH address", text: $dshURL)
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
                                .frame(width: 92, alignment: .leading)
                            CopySourceRow(url: pluginRepo)
                        }

                        HStack(spacing: 10) {
                            Text("USB bridge")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                                .frame(width: 92, alignment: .leading)
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

    private func openDSH() {
        let fallback = model.dshOnline ? URL(string: model.dshURLString) : nil
        DSHLauncher.open(webFallback: fallback)
    }
}

private enum DSHLauncher {
    private static let bundleIdentifier = "com.deepseek.dsh"

    static var isInstalled: Bool { appURL != nil }

    private static let appURL: URL? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "dsh://")!) {
            return url
        }
        let path = "/Applications/DeepSeek Harness.app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    static func open(webFallback: URL?) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            _ = running.activate(options: [.activateAllWindows])
            return
        }
        if let appURL {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                guard error != nil, let webFallback else { return }
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(webFallback)
                }
            }
            return
        }
        if let webFallback {
            NSWorkspace.shared.open(webFallback)
        }
    }
}
