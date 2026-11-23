import SwiftUI

/// In-app transparency explainer shown before the first Keychain access of a
/// build. The system dialog text is owned by macOS; this explains why it appears.
/// Once access is granted it becomes the Enabled state with Revoke/Done.
struct KeychainExplainerSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var confirmRevoke = false

    var body: some View {
        Group {
            if model.keychainAccessGranted {
                enabledContent
            } else {
                explainerContent
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Cue9Theme.paper)
        .confirmationDialog(
            "Revoke Keychain access?",
            isPresented: $confirmRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task { await model.revokeKeychainAccess() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local cue9 app token and removes the plugin's app-authorization hash. Phone approvals and the laptop panel keep working, but the app's phone setup and keep-awake controls stop until you enable Keychain access again.")
        }
    }

    // MARK: - Enabled

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Cue9Theme.success)
                    .frame(width: 38, height: 38)
                    .background(Cue9Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keychain access is enabled")
                        .font(Cue9Font.font(20, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("The local cue9 app token is active.")
                        .font(Cue9Font.font(11.5))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Cue9Theme.line)

            VStack(alignment: .leading, spacing: 11) {
                Text("The token only controls phone setup, pairing, notifications, and keep-awake. It cannot answer approvals or read DSH.")
                    .font(Cue9Font.font(11.5))
                    .foregroundStyle(Cue9Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Revoking deletes the token from your Mac's login Keychain and removes the plugin's app-authorization hash on this Mac. Phone approvals and the laptop panel keep working; the app's phone setup and keep-awake controls are disabled until you enable Keychain access again.")
                    .font(Cue9Font.font(11))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if let error = model.keychainAccessError, !error.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.top, 1)
                    Text(error)
                        .font(Cue9Font.font(10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Cue9Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Cue9Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirmRevoke = true
                } label: {
                    Text("Revoke")
                        .font(Cue9Font.font(12, .medium))
                        .foregroundStyle(Cue9Theme.danger)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Cue9Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Cue9Theme.danger.opacity(0.55), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.keychainAccessBusy)
                Spacer()
                if model.keychainAccessBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.keychainAccessBusy)
            }
        }
    }

    // MARK: - Not granted

    private var explainerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Cue9Theme.orange)
                    .frame(width: 38, height: 38)
                    .background(Cue9Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Why Keychain access?")
                        .font(Cue9Font.font(20, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("This is a local cue9 app credential, not a password for DSH, Tailscale, your website, or your iPhone.")
                        .font(Cue9Font.font(11.5))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Cue9Theme.line)

            VStack(alignment: .leading, spacing: 13) {
                point(
                    icon: "number",
                    title: "What it is",
                    text: "cue9 keeps a random local app token in your Mac's login Keychain."
                )
                point(
                    icon: "lock.shield",
                    title: "What it talks to",
                    text: "It is used only to authenticate the cue9 Mac app to the local cue9 phone plugin on this Mac. It configures the phone link, pairing, notifications, and keep-awake."
                )
                point(
                    icon: "xmark.shield",
                    title: "What it cannot do",
                    text: "It cannot answer approvals or read DSH. It is not your DSH, Tailscale, website, or iPhone password."
                )
                point(
                    icon: "keyboard",
                    title: "If macOS asks for a password",
                    text: "macOS may ask for your Mac login Keychain password. That is the password that unlocks your login Keychain — not a cue9, DSH, Tailscale, or website password."
                )
                point(
                    icon: "arrow.clockwise",
                    title: "Why it may reappear",
                    text: "After a rebuild or re-sign, macOS may treat cue9 as a new app and ask again. The token stays in Keychain; cue9 does not write it to disk."
                )
            }

            if let error = model.keychainAccessError, !error.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.top, 1)
                    Text(error)
                        .font(Cue9Font.font(10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Cue9Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Cue9Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                Button("Not now") {
                    isPresented = false
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(model.keychainAccessBusy)
                Spacer()
                if model.keychainAccessBusy {
                    ProgressView().controlSize(.small)
                }
                Button(model.keychainAccessBusy ? "Waiting for macOS…" : "Continue") {
                    Task {
                        await model.requestKeychainAccess()
                        if model.keychainAccessGranted {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.keychainAccessBusy)
            }

            Text("Not now leaves phone setup and keep-awake disabled. You can reopen this from Why Keychain? in Connect or phone setup.")
                .font(Cue9Font.font(10))
                .foregroundStyle(Cue9Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func point(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Cue9Theme.orange)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Cue9Font.font(12, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text(text)
                    .font(Cue9Font.font(11))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
