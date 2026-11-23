import AppKit
import CoreImage
import SwiftUI

/// Guided, in-app setup for phone approvals. No terminal.
struct PhoneSetupSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    @State private var showKeychainExplainer = false
    @State private var homeWiFiExpanded = false

    private var setup: PhoneSetupState? { model.phoneSetup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Cue9Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.appAuthConflict {
                        appAuthCard
                    } else if !model.keychainAccessGranted {
                        keychainAccessCard
                    } else if setup == nil {
                        if model.phoneSetupBusy {
                            loading
                        } else {
                            unavailable
                        }
                    } else {
                        tailscaleStep
                        pairingStep
                        notificationsStep
                        homeWiFiHint
                    }
                    if let error = model.phoneError, !model.appAuthConflict {
                        banner(error, color: Cue9Theme.danger, icon: "exclamationmark.triangle")
                    }
                    if let notice = model.phoneNotice {
                        banner(notice, color: Cue9Theme.success, icon: "checkmark.circle")
                    }
                }
                .padding(24)
            }
            Divider().overlay(Cue9Theme.line)
            footer
        }
        .frame(width: 660, height: CommandLine.arguments.contains("--snapshot-phone") ? 1200 : 760)
        .background(Cue9Theme.paper)
        .onAppear {
            guard !CommandLine.arguments.contains("--snapshot-phone"), model.keychainAccessGranted else { return }
            Task {
                await model.refreshPhoneSetup()
                if model.phoneSetup?.pairing?.ready == true {
                    await model.createPhonePairing()
                }
            }
        }
        .task {
            guard !CommandLine.arguments.contains("--snapshot-phone") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await model.pollPhoneSetup()
            }
        }
        .sheet(isPresented: $showKeychainExplainer) {
            KeychainExplainerSheet(model: model, isPresented: $showKeychainExplainer)
        }
        .confirmationDialog(
            "Undo phone setup?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove phone setup", role: .destructive) {
                Task { await model.resetPhoneSetup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes all phones and pairing links, removes notifications, and removes the phone link's certificate, Serve route, and Mac config. Tailscale itself stays installed and signed in. You can run setup again.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up phone approvals")
                    .font(Cue9Font.font(23, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text("A guided setup for Tailscale, the phone link, and notifications. The cue9 app stays the command center; the terminal is never needed.")
                    .font(Cue9Font.font(12))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Cue9Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(Cue9Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(24)
    }

    private var unavailable: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("The phone setup is not answering yet.")
                    .font(Cue9Font.font(14, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text("DeepSeek Harness may not have reloaded the final cue9 phone plugin. Restart DeepSeek Harness once, then try again.")
                    .font(Cue9Font.font(11.5))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { refresh() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking Tailscale and the phone link…")
                .font(Cue9Font.font(12))
                .foregroundStyle(Cue9Theme.muted)
        }
        .padding(.vertical, 30)
    }

    private var tailscaleStep: some View {
        stepCard(
            number: 1,
            title: "Connect Tailscale",
            state: setup?.tailscale?.running == true && setup?.tailscale?.online == true,
            detail: setup?.tailscale?.online == true
                ? "Connected as \(setup?.tailscale?.dnsName ?? "this Mac")."
                : setup?.tailscale?.running == true
                    ? "Tailscale is open, but this Mac is offline. Open the Tailscale menu and click Connect."
                    : "Tailscale is not running on this Mac. Open it and connect this Mac before continuing."
        ) {
            HStack(spacing: 8) {
                Button("Open Tailscale") { openTailscale() }
                    .buttonStyle(OutlineButtonStyle())
                Button("Check again") { refresh() }
                    .buttonStyle(OutlineButtonStyle())
            }
            if setup?.tailscale?.online != true {
                Text("The phone and the Mac both need to be signed in to the same tailnet.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.soft)
            }
        }
    }

    /// The certificate step keeps its existing ready state; this only adds a renewal nudge.
    private var certificateExpiryWarning: String? {
        guard let https = setup?.https, https.ready == true else { return nil }
        let days = https.daysRemaining
        guard https.renewSoon == true || (days ?? Int.max) < 14 else { return nil }
        guard let days else { return "Certificate is expiring soon — fetch a new one." }
        if days < 0 { return "Certificate expired \(abs(days)) days ago — fetch a new one." }
        if days == 0 { return "Certificate expires today — fetch a new one." }
        return "Certificate expires in \(days) days — fetch a new one."
    }

    private var pairingStep: some View {
        stepCard(
            number: 2,
            title: "Pair your iPhone",
            state: setup?.phone?.paired == true,
            detail: setup?.phone?.paired == true
                ? "This phone has connected. Open the installed cue9 app whenever you want to review a request."
                : "This creates a private phone link and a one-time pairing link. If the link isn't set up yet, the app fetches the certificate and publishes only the phone app first. This page updates automatically after you tap Connect; there is nothing to reapply."
        ) {
            if setup?.tailscale?.iosOnline == 0 {
                Text((setup?.tailscale?.iosDevices ?? 0) > 0
                     ? "Your iPhone is in the tailnet but offline. Open Tailscale on the iPhone and connect it — or add the optional Wi-Fi DNS record at the end."
                     : "Add the iPhone to this Tailscale tailnet first, or use the optional Wi-Fi DNS record at the end.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }

            certificateSection
            pairingLinkSection

            if let devices = setup?.phone?.devices, !devices.isEmpty {
                Divider().overlay(Cue9Theme.line).padding(.vertical, 2)
                pairedDevices(devices)
            }
        }
    }

    @ViewBuilder
    private var certificateSection: some View {
        if setup?.https?.ready != true {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.top, 1)
                    Text("The phone link needs a trusted HTTPS certificate. Creating the pairing link will fetch it and set up the private Tailscale address; this can take a moment.")
                        .font(Cue9Font.font(10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Open Tailscale admin") { openAdmin() }
                        .buttonStyle(OutlineButtonStyle())
                    Text("Turn on HTTPS Certificates in the admin DNS page.")
                        .font(Cue9Font.font(10))
                        .foregroundStyle(Cue9Theme.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Cue9Theme.muted)
        }
        if let warning = certificateExpiryWarning {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.top, 1)
                Text(warning)
                    .font(Cue9Font.font(10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Renew certificate") { apply() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.phoneSetupBusy || setup?.canApply != true)
            }
            .foregroundStyle(Cue9Theme.warning)
        }
    }

    @ViewBuilder
    private var pairingLinkSection: some View {
        if let pairing = model.phonePairing {
            if pairing.isExpired {
                Text("This pairing link has expired. Create a fresh one; the old token will not work.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create a new link") { createPairing() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.phoneSetupBusy)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    PhoneQRCode(text: pairing.url)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this code on the iPhone. The link is intentionally not shown here.")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Copy pairing link") { copy(pairing.url) }
                                .buttonStyle(OutlineButtonStyle())
                            Button("New link") { createPairing() }
                                .buttonStyle(OutlineButtonStyle())
                                .disabled(model.phoneSetupBusy)
                        }
                        if let expires = pairing.expiresAtDate {
                            Text("Expires \(expires, style: .relative)")
                                .font(Cue9Font.font(10))
                                .foregroundStyle(Cue9Theme.soft)
                        }
                        Text("The iPhone needs Tailscale connected, or the optional Wi-Fi DNS record at the end. Open the link, tap Connect, then Share → Add to Home Screen. This page updates automatically after Connect.")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if setup?.pairing?.ready == true {
            Text("This link is one-time and expires after a couple of minutes. It is minted only for this Mac. After you tap Connect, this page updates automatically; no reapply is needed.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create pairing link") { createPairing() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.phoneSetupBusy)
        } else {
            Text("The private phone link isn't set up yet. Create the pairing link; the app will fetch the certificate and publish only the phone app first, then show the QR.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            if setup?.canApply != true {
                Text("Connect Tailscale first.")
                    .font(Cue9Font.font(10.5))
                    .foregroundStyle(Cue9Theme.warning)
            }
            Button("Create pairing link") { createPairing() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.phoneSetupBusy || setup?.canApply != true)
        }
    }

    private func pairedDevices(_ devices: [PhoneDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired devices")
                .font(Cue9Font.font(12.5, .semibold))
                .foregroundStyle(Cue9Theme.ink2)
            Text("Revoke a phone if it is lost or replaced. Revoking clears its session and notifications.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(devices) { device in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.id)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Cue9Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("Created \(stamp(device.createdAt))  ·  Last seen \(stamp(device.lastSeenAt))")
                            .font(Cue9Font.font(10))
                            .foregroundStyle(Cue9Theme.soft)
                    }
                    Spacer(minLength: 8)
                    Button("Revoke") {
                        Task { await model.revokePhone(deviceId: device.id) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.phoneSetupBusy)
                }
                .padding(.vertical, 3)
            }
            if devices.count > 1 {
                Button("Revoke all phones") {
                    Task { await model.revokePhone() }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.phoneSetupBusy)
            }
        }
    }

    private var keychainAccessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Cue9Theme.orange)
                        .frame(width: 30, height: 30)
                        .background(Cue9Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keychain access is needed")
                            .font(Cue9Font.font(14, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("cue9 keeps a local app token in your Mac's login Keychain. It only talks to the local cue9 plugin; it cannot answer approvals or read DSH.")
                            .font(Cue9Font.font(11))
                            .foregroundStyle(Cue9Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Why Keychain?") { showKeychainExplainer = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Not now") { dismiss() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private var appAuthCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Cue9Theme.warning)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 7) {
                    Text("This Mac's app authorization needs a reset")
                        .font(Cue9Font.font(14, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("The phone plugin has an old or different app credential. Reset it here to mint a new Keychain token. If it still fails, the plugin's app authorization must be cleared in DSH.")
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.phoneError, !model.phoneSetupBusy {
                        Text(error)
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Reset app authorization") {
                        Task { await model.resetAppAuthorization() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.phoneSetupBusy)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var notificationsStep: some View {
        stepCard(
            number: 3,
            title: "Notifications",
            state: setup?.phone?.push == true,
            detail: setup?.phone?.push == true
                ? "Notifications are on. This phone gets a push when DSH needs an approval or answer. This page updates automatically."
                : "On the iPhone, the cue9 Home Screen app shows a large Enable alerts button until notifications are on. Open cue9, tap Enable alerts, and allow notifications. This page updates automatically."
        ) {
            HStack(spacing: 8) {
                Button("Send test notification") { testPush() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.phoneSetupBusy || setup?.phone?.push != true)
                if setup?.phone?.push != true {
                    Text("Alerts are not on yet. Tap the big Enable alerts button in the cue9 Home Screen app first.")
                        .font(Cue9Font.font(10.5))
                        .foregroundStyle(Cue9Theme.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Optional, unverified router DNS hint. Deliberately not a numbered step:
    /// cue9 cannot read the router and must not show a green check for it.
    private var homeWiFiHint: some View {
        Card {
            DisclosureGroup(isExpanded: $homeWiFiExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = setup?.localDns?.name, let address = setup?.localDns?.address {
                        HStack(spacing: 8) {
                            Text("\(name)  →  \(address)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Cue9Theme.ink2)
                                .textSelection(.enabled)
                                .padding(.horizontal, 9)
                                .frame(height: 30)
                                .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Cue9Theme.line, lineWidth: 1)
                                )
                            Button("Copy record") { copy("\(name) \(address)") }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        Text("Add this local DNS record on your router or Pi-hole. cue9 cannot verify the router's DNS. It is only needed if Tailscale is off at home.")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Connect Tailscale first, then the optional router DNS record appears here.")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cue9Theme.muted)
                        .help("cue9 cannot verify this record. It is only needed if Tailscale is off at home.")
                    Text("Home Wi-Fi fallback (optional)")
                        .font(Cue9Font.font(12.5, .medium))
                        .foregroundStyle(Cue9Theme.ink)
                    Spacer(minLength: 0)
                }
            }
            .tint(Cue9Theme.muted)
        }
    }

    private func stepCard<Actions: View>(
        number: Int,
        title: String,
        state: Bool,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(state ? Cue9Theme.success.opacity(0.14) : Cue9Theme.orange.opacity(0.12))
                        .frame(width: 28, height: 28)
                    if state {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Cue9Theme.success)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Cue9Theme.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(Cue9Font.font(14.5, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text(detail)
                        .font(Cue9Font.font(11.5))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    actions()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func stamp(_ value: Double?) -> String {
        guard let value, value > 0 else { return "unknown" }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private func createPairing() {
        Task { await model.createPhonePairing() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.phoneSetupBusy {
                ProgressView().controlSize(.small)
                Text("Working…")
                    .font(Cue9Font.font(11))
                    .foregroundStyle(Cue9Theme.muted)
            }
            Button {
                showResetConfirmation = true
            } label: {
                Label("Undo phone setup…", systemImage: "trash")
                    .font(Cue9Font.font(11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Cue9Theme.danger)
            .disabled(model.phoneSetupBusy || !model.keychainAccessGranted)
            .help("Revokes phones, pairing links and notifications, and removes the phone link and its certificate. Tailscale stays installed.")
            TextLink(title: "Why Keychain?", systemImage: "questionmark.circle") {
                showKeychainExplainer = true
            }
            Spacer()
            Button("Refresh") { refresh() }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.phoneSetupBusy || !model.keychainAccessGranted)
            Button("Done") { dismiss() }
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(18)
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(Cue9Font.font(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func refresh() {
        Task { await model.refreshPhoneSetup() }
    }

    private func apply() {
        Task { await model.applyPhoneSetup() }
    }

    private func testPush() {
        Task { await model.testPhonePush() }
    }

    private func openTailscale() {
        let path = setup?.tailscale?.appPath ?? "/Applications/Tailscale.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        } else if let download = URL(string: "https://tailscale.com/download/mac") {
            NSWorkspace.shared.open(download)
        }
    }

    private func openAdmin() {
        if let value = setup?.tailscale?.adminUrl, let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        model.phoneNotice = "Copied."
    }
}

struct PhoneQRCode: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 156, height: 156)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Cue9Theme.surface)
                    .frame(width: 172, height: 172)
                    .overlay(
                        Text("QR unavailable")
                            .font(Cue9Font.font(10))
                            .foregroundStyle(Cue9Theme.soft)
                    )
            }
        }
    }

    static func image(for text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
