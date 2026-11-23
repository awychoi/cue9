import AppKit
import SwiftUI

struct ConnectView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: FirmwareFlasher

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
    @State private var showPhoneSetup = false
    @State private var showTrouble = false
    @State private var showSetupSteps = false

    private let pluginRepo = URL(string: "https://github.com/awychoi/dsh-cue9-mote")!

    private var canOpenDSH: Bool {
        DSHLauncher.isInstalled || model.dshOnline
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Connect",
                    subtitle: "Set up DeepSeek and connect cue9.",
                    trailing: AnyView(Pill(
                        text: model.dshOnline ? "DeepSeek connected" : "DeepSeek offline",
                        color: model.dshOnline ? Cue9Theme.success : Cue9Theme.warning
                    ))
                )

                if !model.dshOnline {
                    offlineNote
                }

                deepSeekCard
                linkCard
                phoneCard
                keepAwakeCard
                troubleshootingCard
            }
            .padding(30)
        }
        .onAppear {
            flasher.refreshPorts()
            hostField = model.linkHost
            linkChoice = model.linkTransport
            keepAwakeOn = model.keepAwakeEnabled
            if model.dshOnline && !model.phoneSetupBusy {
                Task { await model.refreshPhoneSetup() }
            }
        }
        .onChange(of: model.linkTransport) { _, value in
            linkChoice = value
        }
        .onChange(of: model.dshOnline) { _, online in
            guard online, !model.phoneSetupBusy else { return }
            Task { await model.refreshPhoneSetup() }
        }
        .onChange(of: model.keepAwakeEnabled) { _, value in
            keepAwakeOn = value
        }
        .sheet(isPresented: $showProvision) {
            provisionSheet
        }
        .sheet(isPresented: $showPiSetup) {
            piSetupSheet
        }
        .sheet(isPresented: $showPhoneSetup) {
            PhoneSetupSheet(model: model)
        }
    }

    // MARK: - Map

    private var bridgeStatus: (String, Color) {
        if !model.dshOnline { return ("Waiting for DeepSeek", Cue9Theme.soft) }
        if model.moteConnected {
            return (model.linkTransport == "wifi" ? "On Wi-Fi" : "On USB", Cue9Theme.success)
        }
        return (model.linkTransport == "wifi" ? "Check the bridge" : "Check the cable", Cue9Theme.warning)
    }

    private var cue9Status: (String, Color) {
        if model.moteConnected { return ("Here and happy", Cue9Theme.success) }
        if !flasher.ports.isEmpty { return ("Found on USB", Cue9Theme.warning) }
        return ("Not found", Cue9Theme.soft)
    }

    private var offlineNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Cue9Theme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("DeepSeek is offline")
                    .font(Cue9Font.font(13, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text(model.everConnected
                     ? "Open DeepSeek Harness, then retry."
                     : "Open DeepSeek Harness and add the cue9 plugin.")
                    .font(Cue9Font.font(11.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                Task { await model.retryConnection() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            if canOpenDSH {
                Button {
                    openDSH()
                } label: {
                    Label("Open DeepSeek", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Cue9Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.warning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - DeepSeek

    private var deepSeekCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("DeepSeek Harness")
                                .font(Cue9Font.font(15.5, .semibold))
                                .foregroundStyle(Cue9Theme.ink)
                            Circle()
                                .fill(model.dshOnline ? Cue9Theme.success : Cue9Theme.warning)
                                .frame(width: 6, height: 6)
                        }
                        Text(model.dshOnline
                             ? "The cue9 add-on is running."
                             : "Install the cue9 add-on in DeepSeek Harness.")
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        if model.dshOnline {
                            Button {
                                showSetupSteps.toggle()
                            } label: {
                                Text(showSetupSteps ? "Hide setup" : "Setup")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }

                        if canOpenDSH {
                            Button {
                                openDSH()
                            } label: {
                                Label("Open DeepSeek", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                if !model.dshOnline || showSetupSteps {
                    Divider()
                        .overlay(Cue9Theme.line)
                        .padding(.top, 14)

                    VStack(alignment: .leading, spacing: 9) {
                        setupStep(1, "Open DeepSeek Harness.")
                        setupStep(2, "Open Plugins → Add plugin.")
                        setupStep(3, "Choose the cue9 plugin folder.")
                    }
                    .padding(.top, 13)

                    HStack(spacing: 10) {
                        SectionLabel(text: "Plugin link")
                        CopySourceRow(url: pluginRepo)
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Cue9Theme.orangeInk)
                .frame(width: 17, height: 17)
                .background(Cue9Theme.orange, in: Circle())
            Text(text)
                .font(Cue9Font.font(11.5))
                .foregroundStyle(Cue9Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Link

    private var linkSummary: String {
        if model.linkTransport == "wifi" {
            return model.moteConnected
                ? "Connected over Wi-Fi."
                : "Wi-Fi is set to \(model.linkHost). cue9 is not connected."
        }
        if model.moteConnected {
            return "Connected over USB."
        }
        return flasher.ports.isEmpty
            ? "Connect a USB cable, or use Wi-Fi."
            : "cue9 is on USB. DeepSeek is not connected."
    }

    private var linkCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Connection")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text(linkSummary)
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Picker("", selection: $linkChoice) {
                        Text("USB cable").tag("usb")
                        Text("Wi-Fi").tag("wifi")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
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

                if linkChoice == "usb" {
                    Text("Keep cue9 connected with a USB cable.")
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(Cue9Theme.soft)
                        .padding(.top, 12)
                }

                if linkChoice == "wifi" {
                    Divider()
                        .overlay(Cue9Theme.line)
                        .padding(.top, 14)

                    HStack(spacing: 9) {
                        SectionLabel(text: "Raspberry Pi")
                        TextField("pi@host", text: $hostField)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                            .padding(.horizontal, 9)
                            .frame(width: 230, height: 32)
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
                    }
                    .padding(.top, 13)

                    HStack(spacing: 8) {
                        Button("Set up the Raspberry Pi…") { showPiSetup = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.linkBusy)
                        Button("Send Wi-Fi to cue9…") { showProvision = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.dshOnline)
                        Spacer()
                        Text("The Pi stays online while this Mac sleeps.")
                            .font(Cue9Font.font(9.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .lineLimit(2)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                    .padding(.top, 10)
                }

                if let error = model.linkError {
                    Text(error)
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 9)
                }
            }
        }
    }

    // MARK: - Phone

    private var phoneStatus: (text: String, color: Color) {
        if !model.keychainAccessGranted { return ("Keychain access needed", Cue9Theme.warning) }
        if model.appAuthConflict { return ("App authorization needed", Cue9Theme.warning) }
        guard let setup = model.phoneSetup else {
            return model.phoneSetupBusy ? ("Checking", Cue9Theme.soft) : ("Not checked", Cue9Theme.soft)
        }
        if setup.tailscale?.online != true { return ("Mac is offline in Tailscale", Cue9Theme.warning) }
        if setup.serve?.active != true { return ("Needs setup", Cue9Theme.warning) }
        if setup.phone?.push == true { return ("Ready · notifications on", Cue9Theme.success) }
        if setup.phone?.paired == true { return ("Paired · notifications off", Cue9Theme.warning) }
        return ("Ready · phone not paired", Cue9Theme.warning)
    }

    private var phoneCard: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Approvals on your phone")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Pill(text: phoneStatus.text, color: phoneStatus.color)
                    }
                    Text("Answer approvals and questions from your iPhone, on Wi-Fi or Tailscale. The full command and every choice show up on the phone.")
                        .font(Cue9Font.font(12))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.phoneError, !model.phoneSetupBusy {
                        Text(error)
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 7) {
                    Button("Set up phone") { showPhoneSetup = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.dshOnline || !model.keychainAccessGranted)
                    TextLink(title: "Why Keychain?", systemImage: "questionmark.circle") {
                        model.showKeychainExplainer()
                    }
                    if model.appAuthConflict {
                        TextLink(title: "Reset app authorization", systemImage: "key") {
                            Task { await model.resetAppAuthorization() }
                        }
                        .disabled(model.phoneSetupBusy)
                    }
                }
            }
        }
    }

    // MARK: - Keep awake

    private var keepAwakeCard: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep this Mac awake while DSH works")
                        .font(Cue9Font.font(15.5, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text(model.keepAwakeActive
                         ? "Awake now — \(model.keepAwakeReason); closing the lid still sleeps."
                         : "Sleep allowed — \(model.keepAwakeReason); closing the lid still sleeps.")
                        .font(Cue9Font.font(12))
                        .foregroundStyle(model.keepAwakeActive ? Cue9Theme.ink2 : Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.appAuthConflict {
                        Text("App authorization needs a reset — see Approvals on your phone.")
                            .font(Cue9Font.font(10))
                            .foregroundStyle(Cue9Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $keepAwakeOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!model.dshOnline || !model.keychainAccessGranted || model.phonePower == nil)
                    .onChange(of: keepAwakeOn) { _, value in
                        guard value != model.keepAwakeEnabled else { return }
                        Task {
                            await model.setKeepAwake(value)
                            keepAwakeOn = model.keepAwakeEnabled
                        }
                    }
            }
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showTrouble.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "lifepreserver")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cue9Theme.muted)
                    Text("Troubleshooting")
                        .font(Cue9Font.font(12.5, .medium))
                        .foregroundStyle(Cue9Theme.ink2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Cue9Theme.soft)
                        .rotationEffect(.degrees(showTrouble ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTrouble {
                VStack(alignment: .leading, spacing: 10) {
                    troubleRow(
                        "DeepSeek is offline",
                        "Open DeepSeek Harness, then retry. cue9 usually finds its port by itself."
                    )
                    troubleRow(
                        "cue9 isn't on USB",
                        "Try another cable. Refresh the port list in Device."
                    )
                    troubleRow(
                        "Wi-Fi doesn't work",
                        "Check the Raspberry Pi is on, then choose Wi-Fi again."
                    )
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private func troubleRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Cue9Theme.soft)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Cue9Font.font(11, .medium))
                    .foregroundStyle(Cue9Theme.ink2)
                Text(detail)
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sheets

    private var provisionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send Wi-Fi to cue9")
                .font(Cue9Font.font(17, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Writes the network and the Pi's certificates into cue9. Connect cue9 over USB first. This replaces its Wi-Fi settings.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Wi-Fi network name", text: $ssid)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Cue9Theme.line, lineWidth: 1)
                )
            SecureField("Wi-Fi password", text: $psk)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Cue9Theme.line, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Text(flasher.selectedPort.isEmpty ? "No USB connection found" : flasher.selectedPort)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
                Spacer()
                Button("Cancel") { showProvision = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button(model.linkBusy ? "Working…" : "Send to cue9") {
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
        .frame(width: 460)
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
            Text("Set up the Raspberry Pi")
                .font(Cue9Font.font(17, .semibold))
                .foregroundStyle(Cue9Theme.ink)
            Text("Installs the cue9 bridge on \(hostField). SSH must be enabled. The password is used once and not stored.")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Pi password (only if you don't use an SSH key)", text: $piPassword)
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
        .frame(width: 500)
    }

    private func openDSH() {
        let fallback = model.dshOnline ? URL(string: model.dshURLString) : nil
        DSHLauncher.open(webFallback: fallback)
    }
}

// MARK: - DeepSeek launcher

enum DSHLauncher {
    private static let bundleIdentifier = "com.deepseek.dsh"

    static var isInstalled: Bool { appURL != nil }

    static var icon: NSImage? {
        guard let appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

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
