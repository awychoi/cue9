import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var mapping: [String: [String]]
    @Published var palette: [String: RGB]
    @Published var backgrounds: [String: RGB]
    @Published var actions: [CueAction]
    @Published var animations: [CueAnimation]
    @Published var selectedAction: String
    @Published var selectedAnimation: String
    @Published var pluginState: DSHPluginState?
    @Published var dshOnline = false
    @Published var pluginError: String?
    @Published var dshURLString: String
    @Published var saveState: SaveState = .idle
    @Published var testState: TestState = .idle
    @Published var isReconnecting = false
    @Published var everConnected = UserDefaults.standard.bool(forKey: "everConnected")
    @Published var recentCues: [CueEvent] = []
    @Published var linkBusy = false
    @Published var linkError: String?
    @Published var bridgeHost = UserDefaults.standard.string(forKey: "bridgeHost") ?? ""
    @Published var shakeSensitivity: Int
    @Published var dizzySeconds: Double
    @Published var happySeconds: Double
    @Published var phonePower: PhonePowerState?
    @Published var phoneSetup: PhoneSetupState?
    @Published var phonePairing: PhonePairing?
    @Published var phoneSetupBusy = false
    @Published var phoneError: String?
    @Published var phoneNotice: String?
    @Published var appAuthConflict = false
    @Published var keychainExplainerVisible = false
    @Published var keychainAccessGranted = false
    @Published var keychainAccessBusy = false
    @Published var keychainAccessError: String?
    @Published var keepAwakeEnabled = UserDefaults.standard.object(forKey: "keepAwakeAuto") as? Bool ?? true

    let preview = PreviewEngine()
    let flasher = FirmwareFlasher()
    private var pollTask: Task<Void, Never>?
    private var colourSaveTask: Task<Void, Never>?
    private var behaviourSaveTask: Task<Void, Never>?
    private var behaviourLoaded = false
    private var coloursSynced = false
    private var lastColoursPush = Date.distantPast
    private var saveClearTask: Task<Void, Never>?
    private var testClearTask: Task<Void, Never>?
    private var client: DSHClient
    private var appToken: String
    private var appRegistered = false
    private var registrationInFlight: Task<Bool, Never>?
    private var lastRegistrationAttempt = Date.distantPast
    private var phoneAuthError: String?
    private var lastRecordedCueKey: String?
    private var pendingSync = false
    private var failedPolls = 0
    private var lastPortDiscovery = Date.distantPast
    private var discoveringPort = false
    private var legacyCaffeineDisabled = false
    private let isSnapshotRun = CommandLine.arguments.contains("--snapshot")
    private static let keychainAcceptedBuildKey = "keychainAcceptedBuild"
    private var forceOfflineForSnapshot = false

    init() {
        let defaults = UserDefaults.standard
        shakeSensitivity = defaults.object(forKey: "shakeSensitivity") as? Int ?? 3
        dizzySeconds = defaults.object(forKey: "dizzySeconds") as? Double ?? 6
        happySeconds = defaults.object(forKey: "happySeconds") as? Double ?? 2.4

        // Never touch Keychain in init. First launch shows an in-app explainer;
        // normal launches for this build restore in the background.
        appToken = ""
        let savedURL = UserDefaults.standard.string(forKey: "dshURL") ?? "http://127.0.0.1:53614"
        dshURLString = savedURL
        client = DSHClient(
            baseURL: URL(string: savedURL) ?? URL(string: "http://127.0.0.1:53614")!,
            appToken: ""
        )

        let cached = Self.loadCatalog()
        let initialActions = cached.map { Self.makeActions($0.actions) } ?? []
        let initialAnimations = cached.map { Self.makeAnimations($0.animations) } ?? []
        let storedMapping = Self.loadMapping()
        let initialMapping = Self.reconciledMapping(
            storedMapping,
            actions: initialActions,
            animations: initialAnimations,
            seedNewActions: true,
            keepStoredUnknowns: true
        )
        let storedPalette = Self.loadPaletteFile()
        let storedBackgrounds = Self.loadBackgroundFile()
        let initialPalette = CueCatalog.defaultPalette.merging(storedPalette ?? [:]) { _, new in new }
        let initialBackgrounds = storedBackgrounds ?? [:]

        actions = initialActions
        animations = initialAnimations
        mapping = initialMapping
        palette = initialPalette
        backgrounds = initialBackgrounds
        let history = Self.loadHistory()
        recentCues = history
        lastRecordedCueKey = history.first.map { Self.cueKey(action: $0.action, animation: $0.animation) }

        let firstAction = initialActions.first(where: { $0.id == "tool_write" })?.id
            ?? initialActions.first?.id
            ?? ""
        selectedAction = firstAction
        selectedAnimation = initialMapping[firstAction]?.first
            ?? initialAnimations.first?.id
            ?? ""

        if initialMapping != storedMapping {
            persistMapping(sendToPlugin: false, showBadge: false)
        }
        var filledPalette = initialPalette
        var filledBackgrounds = initialBackgrounds
        var coloursChanged = false
        for animation in initialAnimations {
            if filledPalette[animation.id] == nil {
                filledPalette[animation.id] = animation.color
                coloursChanged = true
            }
            if filledBackgrounds[animation.id] == nil {
                filledBackgrounds[animation.id] = CueCatalog.defaultBackground
                coloursChanged = true
            }
        }
        if coloursChanged {
            palette = filledPalette
            backgrounds = filledBackgrounds
            persistColours(sendToPlugin: false, showBadge: false)
        }

        pendingSync = UserDefaults.standard.bool(forKey: "syncPending")
        ensureSelection()
        preview.configure(
            state: CueCatalog.stateIndex(selectedAnimation.isEmpty ? "work" : selectedAnimation),
            ink: palette[selectedAnimation] ?? CueCatalog.defaultColor(for: selectedAnimation),
            background: backgrounds[selectedAnimation] ?? CueCatalog.defaultBackground,
            reset: true
        )
        let snapshotMode = CommandLine.arguments.contains("--snapshot")
            || CommandLine.arguments.contains("--snapshot-phone")
        if snapshotMode {
            keychainAccessGranted = true
        } else if defaults.string(forKey: Self.keychainAcceptedBuildKey) == Self.currentBuildID() {
            Task { [weak self] in await self?.restoreKeychainAccess() }
        } else {
            keychainExplainerVisible = true
        }
        startPolling()
        if !FileManager.default.fileExists(atPath: CuePaths.palette.path) {
            persistColours(sendToPlugin: false, showBadge: false)
        }
    }

    deinit {
        pollTask?.cancel()
        colourSaveTask?.cancel()
        behaviourSaveTask?.cancel()
        saveClearTask?.cancel()
        testClearTask?.cancel()
    }

    var selectedActionTitle: String {
        actions.first(where: { $0.id == selectedAction })?.label
            ?? (selectedAction.isEmpty ? "No action" : selectedAction)
    }

    var selectedAnimationTitle: String {
        animations.first(where: { $0.id == selectedAnimation })?.label
            ?? (selectedAnimation.isEmpty ? "No animation" : selectedAnimation)
    }

    var liveAction: String? {
        pluginState?.current
    }

    var liveAnimation: String? {
        pluginState?.currentAnim
    }

    var liveActionTitle: String? {
        liveAction.map { actionLabel($0) }
    }

    var liveAnimationTitle: String? {
        liveAnimation.map { animationLabel($0) }
    }

    var previewing: Bool {
        pluginState?.previewing == true
    }

    var usbConnected: Bool {
        pluginState?.status?.connected == true
    }

    var usbPort: String? {
        pluginState?.status?.port
    }

    var linkTransport: String {
        pluginState?.link?.transport ?? "usb"
    }

    var linkHost: String {
        pluginState?.link?.host ?? bridgeHost
    }

    var moteConnected: Bool {
        pluginState?.status?.connected == true
    }

    var moteRSSI: Int? {
        pluginState?.status?.rssi
    }

    var keepAwakeActive: Bool {
        phonePower?.active == true
    }

    var keepAwakeReason: String {
        if phonePower == nil { return dshOnline ? "Not checked" : "DeepSeek offline" }
        return phonePower?.reason ?? "Idle"
    }

    var workingAgents: Int {
        phonePower?.working ?? 0
    }

    var waitingRequests: Int {
        phonePower?.waiting ?? 0
    }

    var phoneDevices: [PhoneDevice] {
        phoneSetup?.phone?.devices ?? []
    }

    private var runKey: String? {
        FileManager.default.fileExists(atPath: PISetup.runKeyPath) ? PISetup.runKeyPath : nil
    }

    var mappedAnimations: [String] {
        mapping[selectedAction] ?? []
    }

    func actionLabel(_ id: String) -> String {
        actions.first(where: { $0.id == id })?.label ?? id
    }

    func animationLabel(_ id: String) -> String {
        animations.first(where: { $0.id == id })?.label ?? id
    }

    func animation(for id: String) -> CueAnimation? {
        animations.first(where: { $0.id == id })
    }

    /// Only used by the offscreen snapshot mode so the offline screens can be
    /// reviewed without touching the real settings.
    func makeOfflineForSnapshot() {
        forceOfflineForSnapshot = true
        dshOnline = false
        pluginState = nil
        everConnected = true
        dshURLString = "http://127.0.0.1:1"
        startPolling()
    }

    /// Snapshot-only sample so the phone setup sheet can be reviewed offscreen.
    func makePhoneSetupDemo() {
        pollTask?.cancel()
        pollTask = nil
        let nowMs = Date().timeIntervalSince1970 * 1000
        phoneSetup = PhoneSetupState(
            ok: true,
            tailscale: .init(
                running: true,
                online: true,
                dnsName: "mbpmax64.tailf17d82.ts.net",
                iosDevices: 1,
                iosOnline: 1,
                error: nil,
                adminUrl: "https://login.tailscale.com/admin/dns",
                appPath: "/Applications/Tailscale.app"
            ),
            https: .init(
                ready: true,
                certFile: "~/Library/…/cert.pem",
                keyFile: "~/Library/…/key.pem",
                expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(9 * 86_400)),
                daysRemaining: 9,
                renewSoon: true
            ),
            serve: .init(
                active: true,
                port: 8443,
                url: "https://mbpmax64.tailf17d82.ts.net:8443"
            ),
            localDns: .init(
                name: "mbpmax64.tailf17d82.ts.net",
                address: "192.168.1.108"
            ),
            config: .init(
                publicOrigin: "https://mbpmax64.tailf17d82.ts.net:8443",
                port: 8791
            ),
            phone: .init(
                paired: true,
                clients: 1,
                lastSeenAt: nowMs - 60_000,
                push: true,
                devices: [
                    .init(
                        id: "demo-iphone",
                        createdAt: nowMs - 86_400_000,
                        lastSeenAt: nowMs - 60_000
                    ),
                ]
            ),
            pairing: .init(
                ready: true,
                origin: "https://mbpmax64.tailf17d82.ts.net:8443"
            ),
            canApply: true
        )
        phonePairing = PhonePairing(
            url: "https://mbpmax64.tailf17d82.ts.net:8443/?token=demo",
            token: "demo",
            expiresAt: Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
        )
        appAuthConflict = false
    }

    func pauseBackgroundWork() {
        pollTask?.cancel()
        pollTask = nil
        preview.stop()
    }

    func resumeBackgroundWork() {
        preview.start()
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func refresh() async {
        guard let url = URL(string: dshURLString) else {
            dshOnline = false
            isReconnecting = false
            pluginError = "Invalid DSH address"
            return
        }
        client = DSHClient(baseURL: url, appToken: appToken)
        do {
            let state = try await client.state()
            pluginState = state
            if !behaviourLoaded, let behaviour = state.behaviour {
                behaviourLoaded = true
                if let value = behaviour.sensitivity { shakeSensitivity = value }
                if let value = behaviour.dizzyMs { dizzySeconds = Double(value) / 1000 }
                if let value = behaviour.happyMs { happySeconds = Double(value) / 1000 }
                persistBehaviourLocally()
            }
            dshOnline = true
            isReconnecting = false
            failedPolls = 0
            pluginError = nil
            syncColoursIfNeeded(state)
            if !everConnected {
                everConnected = true
                UserDefaults.standard.set(true, forKey: "everConnected")
            }
            if let remoteActions = state.actions,
               let remoteAnimations = state.animations,
               !remoteActions.isEmpty,
               !remoteAnimations.isEmpty {
                applyCatalog(remoteActions, remoteAnimations)
            }
            if let remoteMapping = state.mapping, remoteMapping != mapping, !pendingSync {
                markPending()
            }
            if pendingSync {
                await pushPending()
            }
            recordCueIfNeeded(state)
            if await ensureAppRegistered() {
                if let power = try? await authorizedPhoneCall({ try await client.phonePower() }) {
                    phonePower = power
                    if let enabled = power.enabled {
                        keepAwakeEnabled = enabled
                        UserDefaults.standard.set(enabled, forKey: "keepAwakeAuto")
                    }
                    if !isSnapshotRun, !legacyCaffeineDisabled, state.link?.keepAwake == true {
                        do {
                            _ = try await client.setLink(
                                transport: state.link?.transport ?? linkTransport,
                                keepAwake: false
                            )
                            legacyCaffeineDisabled = true
                        } catch { /* the power plugin also disables it */ }
                    }
                } else {
                    phonePower = nil
                }
            } else {
                phonePower = nil
            }
        } catch {
            failedPolls += 1
            isReconnecting = everConnected
            dshOnline = false
            pluginState = nil
            phonePower = nil
            pluginError = error.localizedDescription
            await discoverDSHURL()
        }
    }

    /// DSH's web port is assigned per launch. The plugin publishes its bound
    /// origin at `~/.dsh/cue9/dsh.json`; use it only as a fallback when the
    /// saved address is local and stops answering.
    private func discoverDSHURL() async {
        guard !forceOfflineForSnapshot else { return }
        let now = Date()
        guard !discoveringPort, now.timeIntervalSince(lastPortDiscovery) > 5 else { return }
        guard let current = URL(string: dshURLString), Self.isLoopback(current) else { return }
        lastPortDiscovery = now
        discoveringPort = true
        defer { discoveringPort = false }
        guard let data = try? Data(contentsOf: CuePaths.dshPort),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = object["origin"] as? String,
              let url = URL(string: origin),
              Self.isLoopback(url),
              url.absoluteString != dshURLString else { return }
        let candidate = DSHClient(baseURL: url, appToken: appToken)
        guard (try? await candidate.state()) != nil else { return }
        dshURLString = url.absoluteString
        UserDefaults.standard.set(dshURLString, forKey: "dshURL")
        appRegistered = false
        appAuthConflict = false
        lastRegistrationAttempt = .distantPast
        registrationInFlight?.cancel()
        registrationInFlight = nil
        phonePower = nil
        phoneSetup = nil
        phonePairing = nil
        phoneAuthError = nil
        isReconnecting = true
        pluginError = nil
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func retryConnection() async {
        await refresh()
    }

    /// Point the local renderer at whatever DSH says is playing right now.
    func configureLivePreview(reset: Bool = true) {
        guard let animation = liveAnimation, CueCatalog.isRenderable(animation) else { return }
        showPreview(animation: animation, reset: reset)
    }

    /// Point the local renderer at one named face. Used by the live page for
    /// casual previews as well as by the studio.
    func showPreview(animation: String, reset: Bool = true) {
        guard CueCatalog.isRenderable(animation) else { return }
        preview.configure(
            state: CueCatalog.stateIndex(animation),
            ink: palette[animation] ?? CueCatalog.defaultColor(for: animation),
            background: backgrounds[animation] ?? CueCatalog.defaultBackground,
            reset: reset
        )
    }

    func configurePreview(reset: Bool = true) {
        guard !selectedAnimation.isEmpty else { return }
        showPreview(animation: selectedAnimation, reset: reset)
    }

    /// The best face to show when nothing is arriving from DSH.
    var idleFace: String {
        if CueCatalog.isRenderable("idle") { return "idle" }
        return animations.first(where: { !$0.deviceOnly })?.id ?? animations.first?.id ?? ""
    }

    func selectAction(_ action: String) {
        selectedAction = action
        if let first = mapping[action]?.first {
            selectedAnimation = first
        } else if let first = animations.first {
            selectedAnimation = first.id
        }
        configurePreview(reset: true)
    }

    func selectAnimation(_ animation: String) {
        selectedAnimation = animation
        configurePreview(reset: true)
    }

    func toggleMapping(_ animation: String) {
        guard !isDeviceOnly(animation) else { return }
        var list = mapping[selectedAction] ?? []
        if let index = list.firstIndex(of: animation) {
            list.remove(at: index)
        } else {
            list.append(animation)
        }
        mapping[selectedAction] = list
        saveMapping()
    }

    func setInkColor(_ color: Color) {
        palette[selectedAnimation] = RGB(color: color)
        configurePreview(reset: false)
        scheduleColourSave()
    }

    func setBackgroundColor(_ color: Color) {
        backgrounds[selectedAnimation] = RGB(color: color)
        configurePreview(reset: false)
        scheduleColourSave()
    }

    private func scheduleColourSave() {
        colourSaveTask?.cancel()
        colourSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveColours()
        }
    }

    func previewAction(_ action: String, animation: String) {
        guard dshOnline else {
            testState = .failed("Connect DeepSeek Harness first.")
            return
        }
        guard usbConnected else {
            testState = .failed("cue9 isn't connected right now.")
            return
        }
        testState = .sending
        Task {
            do {
                let ink = palette.mapValues { "#\($0.hex)" }
                let background = backgrounds.mapValues { "#\($0.hex)" }
                _ = try await client.palette(ink, backgrounds: background)
                _ = try await client.preview(action: action, animation: animation)
                await refresh()
                guard dshOnline else {
                    testState = .failed("Sent, but DeepSeek stopped responding.")
                    return
                }
                testState = .sent
                scheduleTestClear()
            } catch {
                pluginError = error.localizedDescription
                dshOnline = false
                isReconnecting = everConnected
                testState = .failed("Could not reach DeepSeek Harness.")
            }
        }
    }

    /// The best action to preview when testing an animation's colours.
    var mappableAnimations: [CueAnimation] { animations.filter { !$0.deviceOnly } }
    var deviceAnimations: [CueAnimation] { animations.filter(\.deviceOnly) }

    func isDeviceOnly(_ animation: String) -> Bool {
        animations.first(where: { $0.id == animation })?.deviceOnly == true
    }

    func previewDeviceAnimation(_ animation: String) {
        previewAction("idle", animation: animation)
    }

    func updateBehaviour(
        sensitivity: Int? = nil,
        dizzySeconds: Double? = nil,
        happySeconds: Double? = nil
    ) {
        if let sensitivity {
            shakeSensitivity = min(5, max(1, sensitivity))
        }
        if let dizzySeconds {
            self.dizzySeconds = min(10, max(2, dizzySeconds))
        }
        if let happySeconds {
            self.happySeconds = min(4, max(1, happySeconds))
        }
        persistBehaviourLocally()
        behaviourSaveTask?.cancel()
        behaviourSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushBehaviour()
        }
    }

    private func persistBehaviourLocally() {
        let defaults = UserDefaults.standard
        defaults.set(shakeSensitivity, forKey: "shakeSensitivity")
        defaults.set(dizzySeconds, forKey: "dizzySeconds")
        defaults.set(happySeconds, forKey: "happySeconds")
    }

    private func pushBehaviour() async {
        guard dshOnline else { return }
        do {
            _ = try await client.behaviour(
                sensitivity: shakeSensitivity,
                dizzyMs: Int((dizzySeconds * 1000).rounded()),
                happyMs: Int((happySeconds * 1000).rounded())
            )
        } catch {
            pluginError = "Could not send behaviour: \(error.localizedDescription)"
        }
    }

    func isUnmapped(_ actionID: String) -> Bool {
        (mapping[actionID] ?? []).isEmpty
    }

    func resumeLive() {
        guard dshOnline else {
            testState = .failed("Connect DeepSeek Harness first.")
            return
        }
        testState = .sending
        Task {
            do {
                _ = try await client.resumeLive()
                await refresh()
                testState = .sent
                scheduleTestClear()
            } catch {
                pluginError = error.localizedDescription
                dshOnline = false
                isReconnecting = everConnected
                testState = .failed("Could not reach DeepSeek Harness.")
            }
        }
    }

    func saveMapping() {
        persistMapping(sendToPlugin: true, showBadge: true)
    }

    private func saveColours() {
        persistColours(sendToPlugin: true, showBadge: true)
    }

    var unmappedActions: [CueAction] {
        actions.filter { isUnmapped($0.id) }
    }

    var mappedActionCount: Int {
        actions.filter { !isUnmapped($0.id) }.count
    }

    private func scheduleTestClear() {
        testClearTask?.cancel()
        testClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.testState == .sent {
                self?.testState = .idle
            }
        }
    }

    private func scheduleSaveClear() {
        saveClearTask?.cancel()
        saveClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.saveState == .sent || self?.saveState == .savedLocally {
                self?.saveState = .idle
            }
        }
    }

    private func markPending() {
        pendingSync = true
        UserDefaults.standard.set(true, forKey: "syncPending")
    }

    private func pushPending() async {
        guard dshOnline else { return }
        do {
            _ = try await client.mapping(mapping)
            _ = try await client.palette(
                palette.mapValues { "#\($0.hex)" },
                backgrounds: backgrounds.mapValues { "#\($0.hex)" }
            )
            pendingSync = false
            UserDefaults.standard.set(false, forKey: "syncPending")
            saveState = .sent
            scheduleSaveClear()
        } catch {
            saveState = .pending
        }
    }

    func releaseUSB() async {
        guard dshOnline else { return }
        do {
            _ = try await client.setUSB(false)
            await refresh()
        } catch {
            pluginError = error.localizedDescription
        }
    }

    func reconnectUSB() async {
        guard dshOnline else { return }
        do {
            _ = try await client.setUSB(true)
            await refresh()
        } catch {
            pluginError = error.localizedDescription
        }
    }

    func setLink(transport: String, host: String? = nil) async {
        if transport == "wifi", (host ?? bridgeHost).isEmpty {
            linkError = "Add the Raspberry Pi's address first."
            return
        }
        linkBusy = true
        defer { linkBusy = false }
        do {
            let state = try await client.setLink(
                transport: transport,
                host: host ?? (transport == "wifi" ? bridgeHost : nil),
                key: transport == "wifi" ? runKey : nil
            )
            pluginState = state
            if let saved = state.link?.host, !saved.isEmpty {
                bridgeHost = saved
                UserDefaults.standard.set(saved, forKey: "bridgeHost")
            }
            linkError = nil
        } catch {
            linkError = error.localizedDescription
        }
    }

    private static let phoneHardResetMessage = "The app authorization could not be reset. Clear the cue9 phone app authorization in DSH and restart DSH, then reset app authorization again."

    private static func statusCode(of error: Error) -> Int? {
        guard let clientError = error as? DSHClientError,
              case .badStatus(let code) = clientError else {
            return nil
        }
        return code
    }

    private func setPhoneAuthError(_ message: String) {
        phoneAuthError = message
        phoneError = message
    }

    private func clearPhoneAuthError() {
        if phoneError == phoneAuthError { phoneError = nil }
        phoneAuthError = nil
    }

    /// Register this Mac's Keychain token once. Conflicts are a user-actionable
    /// state, not something to retry in a loop.
    @discardableResult
    private func ensureAppRegistered(force: Bool = false) async -> Bool {
        if isSnapshotRun { return false }
        guard keychainAccessGranted else { return false }
        if appToken.isEmpty {
            appAuthConflict = true
            setPhoneAuthError("This Mac's app authorization is unavailable. Reset it in the phone setup.")
            return false
        }
        if appRegistered, !force { return true }
        if appAuthConflict, !force { return false }
        if !force, Date().timeIntervalSince(lastRegistrationAttempt) < 5 {
            return false
        }
        if let registrationInFlight {
            return await registrationInFlight.value
        }

        lastRegistrationAttempt = Date()
        let currentClient = client
        let token = appToken
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let result = try await currentClient.registerApp(token: token)
                if Task.isCancelled { return false }
                switch result {
                case .created, .ok:
                    self.appRegistered = true
                    self.appAuthConflict = false
                    self.clearPhoneAuthError()
                    return true
                case .conflict:
                    self.appRegistered = false
                    self.appAuthConflict = true
                    self.setPhoneAuthError(
                        "This Mac isn't authorized for the phone plugin. Reset app authorization; if it still fails, the plugin still has an old authorization."
                    )
                    return false
                }
            } catch {
                if Task.isCancelled { return false }
                self.appRegistered = false
                let code = Self.statusCode(of: error)
                if code == 401 {
                    self.appAuthConflict = true
                    self.setPhoneAuthError(
                        "This Mac's app authorization was rejected. Reset it in the phone setup."
                    )
                } else if code == 403 {
                    self.appAuthConflict = false
                    self.setPhoneAuthError(
                        "The phone plugin rejected this Mac's address. Use a loopback DSH address."
                    )
                } else {
                    self.appAuthConflict = false
                    self.setPhoneAuthError(
                        "Could not authorize this Mac with the phone plugin: \(error.localizedDescription)"
                    )
                }
                return false
            }
        }
        registrationInFlight = task
        let result = await task.value
        registrationInFlight = nil
        return result
    }

    /// Run one app-authenticated phone-plugin call, registering first and
    /// retrying exactly once after a 401.
    private func authorizedPhoneCall<T>(_ operation: () async throws -> T) async throws -> T {
        guard await ensureAppRegistered() else {
            throw DSHClientError.server(
                phoneAuthError ?? "This Mac isn't authorized for the phone plugin."
            )
        }
        do {
            return try await operation()
        } catch {
            guard Self.statusCode(of: error) == 401 else { throw error }
            appRegistered = false
            lastRegistrationAttempt = .distantPast
            guard await ensureAppRegistered(force: true) else {
                throw DSHClientError.server(
                    phoneAuthError ?? "This Mac isn't authorized for the phone plugin."
                )
            }
            return try await operation()
        }
    }

    func setKeepAwake(_ on: Bool) async {
        let previous = keepAwakeEnabled
        guard keychainAccessGranted else {
            keepAwakeEnabled = previous
            phoneError = "Keychain access is needed for keep-awake. Open Why Keychain? in Connect."
            return
        }
        keepAwakeEnabled = on
        UserDefaults.standard.set(on, forKey: "keepAwakeAuto")
        do {
            phonePower = try await authorizedPhoneCall { try await client.setPhonePower(on) }
            clearPhoneAuthError()
        } catch {
            keepAwakeEnabled = previous
            UserDefaults.standard.set(previous, forKey: "keepAwakeAuto")
            if !appAuthConflict {
                phoneError = "Could not change keep-awake: \(error.localizedDescription)"
            }
        }
    }

    /// Open the in-app transparency explainer from Connect or the setup sheet.
    func showKeychainExplainer() {
        keychainAccessError = nil
        keychainExplainerVisible = true
    }

    /// Called only from the explainer's Continue button. This is the first
    /// Keychain read on a new launch/build, so the user knows why the system
    /// prompt can appear.
    func requestKeychainAccess() async {
        guard !keychainAccessBusy, !isSnapshotRun else { return }
        keychainAccessBusy = true
        keychainAccessError = nil
        defer { keychainAccessBusy = false }

        let token = await Task.detached(priority: .userInitiated) {
            KeychainToken.loadOrCreate()
        }.value

        guard let token, !token.isEmpty else {
            keychainAccessGranted = false
            keychainAccessError = "macOS did not let cue9 read the Keychain. You can try Continue again, or use the app without phone features."
            return
        }
        await acceptKeychainToken(token)
    }

    /// Normal launch of a build that already has access: no explainer, but the
    /// read is still off the initialization path.
    private func restoreKeychainAccess() async {
        guard !keychainAccessGranted, !isSnapshotRun else { return }
        let token = await Task.detached(priority: .utility) {
            KeychainToken.loadOrCreate()
        }.value

        guard let token, !token.isEmpty else {
            keychainAccessError = "macOS did not let cue9 read the Keychain. Open Why Keychain? and try again."
            keychainExplainerVisible = true
            return
        }
        await acceptKeychainToken(token)
    }

    private func acceptKeychainToken(_ token: String) async {
        appToken = token
        client.appToken = token
        keychainAccessGranted = true
        keychainAccessError = nil
        keychainExplainerVisible = false
        appAuthConflict = false
        clearPhoneAuthError()
        UserDefaults.standard.set(Self.currentBuildID(), forKey: Self.keychainAcceptedBuildKey)
        await refresh()
        if dshOnline {
            await refreshPhoneSetup()
        }
    }

    /// Disable the app's local Keychain authorization and remove the plugin's
    /// app-auth hash. This intentionally does not touch phone sessions, the
    /// panel, or Tailscale.
    func revokeKeychainAccess() async {
        guard !keychainAccessBusy, !phoneSetupBusy else { return }
        keychainAccessBusy = true
        defer { keychainAccessBusy = false }
        keychainAccessError = nil
        keychainAccessGranted = false

        let inFlight = registrationInFlight
        inFlight?.cancel()
        registrationInFlight = nil
        _ = await inFlight?.value

        let deleted = await Task.detached(priority: .userInitiated) {
            KeychainToken.delete()
        }.value

        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent("cue9", isDirectory: true)
            .appendingPathComponent("phone", isDirectory: true)
            .appendingPathComponent("app-auth.json")
        var fileError: Error?
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: authFile.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            do {
                try FileManager.default.removeItem(at: authFile)
            } catch {
                fileError = error
            }
        }

        appToken = ""
        client.appToken = ""
        appRegistered = false
        lastRegistrationAttempt = .distantPast
        appAuthConflict = false
        phoneAuthError = nil
        phoneSetup = nil
        phonePairing = nil
        phonePower = nil
        phoneError = nil
        phoneNotice = "Keychain access revoked. Phone setup and keep-awake are disabled."
        UserDefaults.standard.removeObject(forKey: Self.keychainAcceptedBuildKey)

        if !deleted {
            keychainAccessError = "The Keychain item could not be deleted. Remove the cue9 app token in Keychain Access if it remains."
        } else if fileError != nil {
            keychainAccessError = "Keychain access was revoked, but the plugin's app-authorization file could not be removed. The next grant may need a reset."
        }
    }

    /// Changes whenever the executable is rebuilt/re-signed, so the explainer
    /// appears once for each new build rather than on every normal launch.
    private static func currentBuildID() -> String {
        guard let executable = Bundle.main.executableURL else { return "unknown" }
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modified)-\(size)"
    }

    func refreshPhoneSetup() async {
        guard keychainAccessGranted else {
            phoneSetup = nil
            phoneError = nil
            return
        }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        phonePairing = nil
        do {
            phoneSetup = try await authorizedPhoneCall { try await client.phoneSetup() }
            clearPhoneAuthError()
            phoneError = nil
        } catch {
            if !appAuthConflict {
                phoneError = "Could not read the phone setup: \(error.localizedDescription)"
            }
        }
    }

    /// Silent refresh for the open setup sheet. It updates the states the wizard
    /// displays without toggling the busy/error UI and without discarding a
    /// pairing link the user is currently looking at.
    func pollPhoneSetup() async {
        guard keychainAccessGranted, dshOnline, !phoneSetupBusy, !appAuthConflict, !Task.isCancelled else { return }
        let activeClient = client
        do {
            let next = try await activeClient.phoneSetup()
            guard !Task.isCancelled, dshOnline, !phoneSetupBusy, !appAuthConflict else { return }
            phoneSetup = next
        } catch {
            // Silent by design. The manual Refresh button surfaces errors.
        }
    }

    private func requireKeychainForPhone() -> Bool {
        if keychainAccessGranted { return true }
        phoneError = "Keychain access is needed for phone features. Open Why Keychain? in Connect."
        return false
    }

    func applyPhoneSetup() async {
        guard requireKeychainForPhone() else { return }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        guard !phoneSetupBusy else { return }
        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        do {
            phoneSetup = try await authorizedPhoneCall { try await client.applyPhoneSetup() }
            clearPhoneAuthError()
            phoneError = nil
            phoneNotice = "Phone link is ready."
            await refresh()
        } catch {
            if !appAuthConflict {
                phoneError = "Setup failed: \(error.localizedDescription)"
            }
        }
    }

    func testPhonePush() async {
        guard requireKeychainForPhone() else { return }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        guard !phoneSetupBusy else { return }
        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        do {
            let result = try await authorizedPhoneCall { try await client.testPhonePush() }
            let failed = result.failed ?? 0
            let sent = result.sent ?? 0
            if result.ok == true {
                clearPhoneAuthError()
                if failed > 0 {
                    phoneNotice = nil
                    let accepted = sent == 1 ? "1 subscription" : "\(sent) subscriptions"
                    let rejected = failed == 1 ? "1 subscription" : "\(failed) subscriptions"
                    phoneError = "Apple accepted the test push for \(accepted), but \(rejected) failed. In the cue9 app on your iPhone, disable alerts and enable them again, then send another test."
                } else {
                    phoneError = nil
                    phoneNotice = "Apple accepted the test push. If no banner appears, check Focus/Do Not Disturb and iPhone Settings → Notifications → cue9, then lock your iPhone or switch away from cue9."
                }
            } else {
                phoneNotice = nil
                switch result.error {
                case "no-subscriptions":
                    phoneError = "Enable notifications in the cue9 app on your iPhone first."
                case "push-rejected":
                    phoneError = "Apple rejected the test push. In the cue9 app on your iPhone, disable alerts and enable them again; if it still fails, check iPhone Settings → Notifications → cue9."
                default:
                    phoneError = "The test push could not be sent. In the cue9 app on your iPhone, disable alerts and enable them again; if it still fails, check iPhone Settings → Notifications → cue9."
                }
            }
        } catch {
            phoneNotice = nil
            if !appAuthConflict {
                phoneError = "The test push could not be sent: \(error.localizedDescription)"
            }
        }
    }

    /// Mint one short-lived pairing link. The raw token is held only in memory.
    func createPhonePairing() async {
        guard requireKeychainForPhone() else { return }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        guard !phoneSetupBusy else { return }

        let needsLinkSetup = phoneSetup?.pairing?.ready != true
        if needsLinkSetup, phoneSetup?.canApply != true {
            phoneError = "Connect Tailscale first, then create the pairing link."
            return
        }

        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        var startedLinkSetup = false
        do {
            if phoneSetup?.pairing?.ready != true {
                startedLinkSetup = true
                phoneSetup = try await authorizedPhoneCall { try await client.applyPhoneSetup() }
                clearPhoneAuthError()
            }
            guard phoneSetup?.pairing?.ready == true else {
                phoneError = "The phone link is not ready yet. Try again after Tailscale is connected."
                return
            }
            phonePairing = try await authorizedPhoneCall { try await client.createPhonePairing() }
            clearPhoneAuthError()
            phoneError = nil
            phoneNotice = "Pairing link created. It expires shortly."
        } catch {
            if !appAuthConflict {
                phoneError = startedLinkSetup
                    ? "Could not set up the phone link: \(error.localizedDescription)"
                    : "Could not create a pairing link: \(error.localizedDescription)"
            }
        }
    }

    /// Revoke one paired phone, or every paired phone when `deviceId` is nil.
    func revokePhone(deviceId: String? = nil) async {
        guard requireKeychainForPhone() else { return }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        guard !phoneSetupBusy else { return }
        phoneSetupBusy = true
        do {
            try await authorizedPhoneCall { try await client.revokePhone(deviceId: deviceId) }
            phonePairing = nil
            clearPhoneAuthError()
            phoneNotice = deviceId == nil ? "All phones revoked." : "Phone revoked."
        } catch {
            if !appAuthConflict {
                phoneError = "Could not revoke the phone: \(error.localizedDescription)"
            }
            phoneSetupBusy = false
            return
        }
        phoneSetupBusy = false
        await refreshPhoneSetup()
    }

    /// Remove this Mac's phone link: all phones and pairing links, notifications,
    /// the certificate, Serve route and phone config. Tailscale and the app's
    /// Keychain authorization are deliberately left alone.
    func resetPhoneSetup() async {
        guard requireKeychainForPhone() else { return }
        guard dshOnline else {
            phoneError = "Connect DeepSeek Harness first."
            return
        }
        guard !phoneSetupBusy else { return }
        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        phoneError = nil
        phoneNotice = nil
        do {
            let result = try await authorizedPhoneCall { try await client.resetPhoneSetup() }
            phoneSetup = nil
            phonePairing = nil
            clearPhoneAuthError()
            phoneNotice = "Phone setup removed. You can run it again."
            var warning = result.warning?.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok == false, warning?.isEmpty != false {
                warning = "The phone plugin returned an incomplete reset result."
            }
            await refreshPhoneSetup()
            if let warning, !warning.isEmpty {
                phoneError = warning
            }
        } catch {
            if !appAuthConflict {
                phoneError = "Could not undo the phone setup: \(error.localizedDescription)"
            }
        }
    }

    /// The plugin re-reads its app-auth file on every request, so a 401 from
    /// rotate can be recovered by removing only that exact file and registering
    /// the new Keychain token once. Never loop this.
    private func recoverAppAuthorizationAfterUnauthorizedRotate(baseURL: URL) async {
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent("cue9", isDirectory: true)
            .appendingPathComponent("phone", isDirectory: true)
            .appendingPathComponent("app-auth.json")

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: authFile.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            try? FileManager.default.removeItem(at: authFile)
        }

        guard let newToken = KeychainToken.generate() else {
            appAuthConflict = true
            setPhoneAuthError(Self.phoneHardResetMessage)
            return
        }
        guard KeychainToken.store(newToken) else {
            appAuthConflict = true
            setPhoneAuthError("Could not save the new app token to the Keychain. Remove the cue9 app token in Keychain Access, then reset again.")
            return
        }

        do {
            let result = try await client.registerApp(token: newToken)
            guard result != .conflict else {
                appAuthConflict = true
                setPhoneAuthError(Self.phoneHardResetMessage)
                return
            }
            appToken = newToken
            client = DSHClient(baseURL: baseURL, appToken: newToken)
            appRegistered = true
            appAuthConflict = false
            lastRegistrationAttempt = Date()
            clearPhoneAuthError()
            phonePower = nil
            phoneSetup = nil
            phonePairing = nil
            phoneNotice = "App authorization reset."
            await refreshPhoneSetup()
        } catch {
            appAuthConflict = true
            setPhoneAuthError(Self.phoneHardResetMessage)
        }
    }

    /// Rotate this Mac's app token through the plugin. The Keychain and
    /// in-memory token change only after the Host accepts the new token.
    func resetAppAuthorization() async {
        guard !phoneSetupBusy else { return }
        guard !appToken.isEmpty else {
            appAuthConflict = true
            setPhoneAuthError("This Mac has no app token in the Keychain. Reset app authorization from the cue9 phone setup.")
            return
        }
        phoneSetupBusy = true
        defer { phoneSetupBusy = false }
        phoneNotice = nil
        phoneError = nil
        lastRegistrationAttempt = .distantPast
        registrationInFlight?.cancel()
        registrationInFlight = nil

        guard let newToken = KeychainToken.generate() else {
            appAuthConflict = true
            setPhoneAuthError("Could not create a new Keychain app token. Try again, or remove the cue9 app token in Keychain Access.")
            return
        }

        let oldToken = appToken
        let baseURL = URL(string: dshURLString) ?? URL(string: "http://127.0.0.1:53614")!
        do {
            try await client.rotateAppToken(newToken: newToken)
        } catch {
            let code = Self.statusCode(of: error)
            if code == 401 {
                await recoverAppAuthorizationAfterUnauthorizedRotate(baseURL: baseURL)
            } else if code == 400 {
                appAuthConflict = true
                setPhoneAuthError("The phone plugin rejected the new app token. Reset app authorization again.")
            } else {
                setPhoneAuthError("Could not rotate this Mac's app authorization: \(error.localizedDescription)")
            }
            return
        }

        // The Host accepted the new token. Only now replace the Keychain value.
        guard KeychainToken.store(newToken) else {
            // Keep the old token usable if possible.
            let rollback = DSHClient(baseURL: baseURL, appToken: newToken)
            var rolledBack = false
            do {
                try await rollback.rotateAppToken(newToken: oldToken)
                rolledBack = true
            } catch { /* keep the hard-reset message below */ }
            if rolledBack {
                appRegistered = true
                appAuthConflict = false
                setPhoneAuthError("The new key could not be saved to the Keychain. The old authorization is still active; try again.")
            } else {
                appAuthConflict = true
                setPhoneAuthError("The new key could not be saved to the Keychain, and the old authorization could not be restored. Reset app authorization from the cue9 phone setup; if that fails, clear the plugin's app authorization in DSH.")
            }
            return
        }

        appToken = newToken
        client = DSHClient(baseURL: baseURL, appToken: newToken)
        appRegistered = true
        appAuthConflict = false
        lastRegistrationAttempt = Date()
        clearPhoneAuthError()
        phonePower = nil
        phoneSetup = nil
        phonePairing = nil
        phoneNotice = "App authorization reset."
        await refreshPhoneSetup()
    }

    func adoptPiSummary(_ summary: PiSummary) {
        bridgeHost = summary.bridgeTarget
        UserDefaults.standard.set(bridgeHost, forKey: "bridgeHost")
    }

    /// Flash Wi-Fi + the Pi's certificates, then point the plugin at the Pi.
    /// Requires the mote on USB and a Pi summary at ~/.dsh/cue9/pi.json.
    func provisionMote(ssid: String, psk: String) async -> Bool {
        guard let summary = MoteProvisioning.loadSummary() else {
            linkError = "The Raspberry Pi isn't set up yet. Close this and set it up in Connect."
            return false
        }
        guard let data = try? MoteProvisioning.configData(summary: summary, ssid: ssid, psk: psk) else {
            linkError = "Could not build the config."
            return false
        }
        linkBusy = true
        defer { linkBusy = false }
        let wasUSB = linkTransport == "usb"
        if dshOnline && wasUSB {
            _ = try? await client.setUSB(false)
            _ = await flasher.waitForPortFree(flasher.selectedPort)
        }
        let ok = await flasher.flash(config: data)
        if ok {
            let target = summary.bridgeTarget
            bridgeHost = target
            UserDefaults.standard.set(target, forKey: "bridgeHost")
            do {
                let state = try await client.setLink(transport: "wifi", host: target, key: runKey)
                pluginState = state
                linkError = nil
            } catch {
                linkError = error.localizedDescription
            }
        } else if dshOnline && wasUSB {
            _ = try? await client.setUSB(true)
        }
        await refresh()
        return ok
    }

    func flashFirmware() async {
        if dshOnline {
            _ = try? await client.setUSB(false)
            _ = await flasher.waitForPortFree(flasher.selectedPort)
        }
        _ = await flasher.flash()
        if dshOnline {
            _ = try? await client.setUSB(true)
        }
        await refresh()
    }

    func updateDSHURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dshURLString = trimmed
        UserDefaults.standard.set(trimmed, forKey: "dshURL")
        client = DSHClient(
            baseURL: URL(string: trimmed) ?? URL(string: "http://127.0.0.1:53614")!,
            appToken: appToken
        )
        dshOnline = false
        pluginState = nil
        isReconnecting = false
        appRegistered = false
        appAuthConflict = false
        lastRegistrationAttempt = .distantPast
        registrationInFlight?.cancel()
        registrationInFlight = nil
        phonePower = nil
        phoneSetup = nil
        phonePairing = nil
        phoneAuthError = nil
        startPolling()
    }

    // MARK: - Catalog

    private func applyCatalog(_ remoteActions: [DSHPluginAction], _ remoteAnimations: [DSHPluginAnimation]) {
        let previousActions = actions
        let previousMapping = mapping
        let nextActions = Self.makeActions(remoteActions)
        let nextAnimations = Self.makeAnimations(remoteAnimations)
        guard nextActions != actions || nextAnimations != animations else { return }

        actions = nextActions
        animations = nextAnimations

        let nextMapping = Self.reconciledMapping(
            previousMapping,
            actions: nextActions,
            animations: nextAnimations,
            seedNewActions: previousActions.isEmpty
        )
        if nextMapping != mapping {
            mapping = nextMapping
            persistMapping(sendToPlugin: true, showBadge: false)
        }
        ensureColours()
        ensureSelection()
        saveCatalog()
    }

    private func ensureColours() {
        var nextPalette = palette
        var nextBackgrounds = backgrounds
        var changed = false
        for animation in animations {
            if nextPalette[animation.id] == nil {
                nextPalette[animation.id] = animation.color
                changed = true
            }
            if nextBackgrounds[animation.id] == nil {
                nextBackgrounds[animation.id] = CueCatalog.defaultBackground
                changed = true
            }
        }
        guard changed else { return }
        palette = nextPalette
        backgrounds = nextBackgrounds
        persistColours(sendToPlugin: true, showBadge: false)
    }

    private func ensureSelection() {
        var actionChanged = false
        if !actions.contains(where: { $0.id == selectedAction }) {
            selectedAction = actions.first?.id ?? ""
            actionChanged = true
        }
        if actionChanged
            || selectedAnimation.isEmpty
            || !animations.contains(where: { $0.id == selectedAnimation }) {
            selectedAnimation = mapping[selectedAction]?.first
                ?? animations.first?.id
                ?? ""
        }
        configurePreview(reset: true)
    }

    private func saveCatalog() {
        let cache = CachedCatalog(
            actions: actions.map { DSHPluginAction(id: $0.id, label: $0.label, map: $0.defaultMap) },
            animations: animations.map {
                DSHPluginAnimation(id: $0.id, label: $0.label, deviceOnly: $0.deviceOnly)
            }
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: CuePaths.catalog, options: .atomic)
    }

    private static func makeActions(_ remote: [DSHPluginAction]) -> [CueAction] {
        remote.map { CueAction(id: $0.id, label: $0.label, defaultMap: $0.map ?? []) }
    }

    private static func makeAnimations(_ remote: [DSHPluginAnimation]) -> [CueAnimation] {
        remote.map {
            CueAnimation(
                id: $0.id,
                label: $0.label,
                color: CueCatalog.defaultColor(for: $0.id),
                deviceOnly: $0.deviceOnly == true
            )
        }
    }

    private static func reconciledMapping(
        _ input: [String: [String]],
        actions: [CueAction],
        animations: [CueAnimation],
        seedNewActions: Bool,
        keepStoredUnknowns: Bool = false
    ) -> [String: [String]] {
        guard !actions.isEmpty, !animations.isEmpty else { return input }
        let validActions = Set(actions.map(\.id))
        let deviceOnly = Set(animations.filter(\.deviceOnly).map(\.id))
        let validAnimations = Set(animations.filter { !$0.deviceOnly }.map(\.id))
        var next = input
        for action in actions {
            if let existing = next[action.id] {
                /* The cached catalog can lag the plugin right after new
                 * actions or animations are added. Keep stored ids until a
                 * live list arrives, then filter against the authoritative
                 * one. */
                let filtered = existing.filter {
                    !deviceOnly.contains($0) && (keepStoredUnknowns || validAnimations.contains($0))
                }
                if filtered.isEmpty && !existing.isEmpty {
                    next[action.id] = action.defaultMap.filter { validAnimations.contains($0) }
                } else {
                    next[action.id] = filtered
                }
            } else {
                next[action.id] = seedNewActions
                    ? action.defaultMap.filter { validAnimations.contains($0) }
                    : []
            }
        }
        if !keepStoredUnknowns {
            next = next.filter { validActions.contains($0.key) }
        }
        return next
    }

    // MARK: - Persistence

    private func persistMapping(sendToPlugin: Bool, showBadge: Bool) {
        let snapshot = mapping
        do {
            let data = try JSONSerialization.data(
                withJSONObject: snapshot,
                options: [.prettyPrinted, .sortedKeys]
            )
            if !isSnapshotRun {
                try data.write(to: CuePaths.mapping, options: .atomic)
            }
            if showBadge {
                saveState = .savedLocally
                scheduleSaveClear()
            }
            guard sendToPlugin else { return }
            guard dshOnline else {
                markPending()
                saveState = .pending
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.client.mapping(snapshot)
                    if self.pendingSync {
                        self.saveState = .pending
                    } else {
                        self.saveState = .sent
                        self.scheduleSaveClear()
                    }
                } catch {
                    self.markPending()
                    self.saveState = .pending
                }
            }
        } catch {
            saveState = .failed("Could not save mapping")
            pluginError = "Could not save mapping: \(error.localizedDescription)"
        }
    }

    private var localHasCustomPalette: Bool {
        palette.contains { id, rgb in rgb != CueCatalog.defaultColor(for: id) }
    }

    private var localHasCustomBackgrounds: Bool {
        backgrounds.contains { _, rgb in rgb != CueCatalog.defaultBackground }
    }

    /// The app owns the colour store. On the first successful poll it pushes
    /// that store to the plugin, which mirrors it and sends it to the firmware.
    /// If the app has no custom colours but the plugin does, the app adopts
    /// them instead, so a wiped local file can recover from the plugin.
    private func syncColoursIfNeeded(_ state: DSHPluginState) {
        let remotePalette = state.palette?.compactMapValues { Self.parseHex($0) } ?? [:]
        let remoteBackgrounds = state.backgrounds?.compactMapValues { Self.parseHex($0) } ?? [:]
        let remoteHasCustomPalette = remotePalette.contains { id, rgb in
            rgb != CueCatalog.defaultColor(for: id)
        }
        let remoteHasCustomBackgrounds = remoteBackgrounds.contains { _, rgb in
            rgb != CueCatalog.defaultBackground
        }

        if !coloursSynced {
            coloursSynced = true
            if localHasCustomPalette || localHasCustomBackgrounds {
                pushColours()
            } else if remoteHasCustomPalette || remoteHasCustomBackgrounds {
                adoptRemoteColours(remotePalette, backgrounds: remoteBackgrounds)
            } else {
                pushColours()
            }
            return
        }

        let paletteMissing = localHasCustomPalette && !remoteHasCustomPalette
        let backgroundsMissing = localHasCustomBackgrounds && !remoteHasCustomBackgrounds
        if (paletteMissing || backgroundsMissing),
           Date().timeIntervalSince(lastColoursPush) > 2 {
            pushColours()
        }
    }

    private func pushColours() {
        lastColoursPush = Date()
        persistColours(sendToPlugin: true, showBadge: false)
    }

    private func adoptRemoteColours(_ remotePalette: [String: RGB],
                                    backgrounds remoteBackgrounds: [String: RGB]) {
        guard !remotePalette.isEmpty || !remoteBackgrounds.isEmpty else { return }
        var nextPalette = palette
        var nextBackgrounds = backgrounds
        for (id, rgb) in remotePalette { nextPalette[id] = rgb }
        for (id, rgb) in remoteBackgrounds { nextBackgrounds[id] = rgb }
        guard nextPalette != palette || nextBackgrounds != backgrounds else { return }
        palette = nextPalette
        backgrounds = nextBackgrounds
        persistColours(sendToPlugin: false, showBadge: false)
        configurePreview(reset: false)
    }

    private func persistColours(sendToPlugin: Bool, showBadge: Bool) {
        let ink = palette.mapValues { "#\($0.hex)" }
        let background = backgrounds.mapValues { "#\($0.hex)" }
        do {
            let inkData = try JSONSerialization.data(
                withJSONObject: ink,
                options: [.prettyPrinted, .sortedKeys]
            )
            let backgroundData = try JSONSerialization.data(
                withJSONObject: background,
                options: [.prettyPrinted, .sortedKeys]
            )
            Self.backupColourFile(CuePaths.palette, to: CuePaths.paletteBackup)
            Self.backupColourFile(CuePaths.backgrounds, to: CuePaths.backgroundsBackup)
            if !isSnapshotRun {
                try inkData.write(to: CuePaths.palette, options: .atomic)
                try backgroundData.write(to: CuePaths.backgrounds, options: .atomic)
            }
            if showBadge {
                saveState = .savedLocally
                scheduleSaveClear()
            }
            guard sendToPlugin else { return }
            guard dshOnline else {
                markPending()
                saveState = .pending
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.client.palette(ink, backgrounds: background)
                    if self.pendingSync {
                        self.saveState = .pending
                    } else {
                        self.saveState = .sent
                        self.scheduleSaveClear()
                    }
                } catch {
                    self.markPending()
                    self.saveState = .pending
                }
            }
        } catch {
            saveState = .failed("Could not save colours")
            pluginError = "Could not save colours: \(error.localizedDescription)"
        }
    }

    private func recordCueIfNeeded(_ state: DSHPluginState) {
        guard let action = state.current else { return }
        let animation = state.currentAnim ?? mapping[action]?.first ?? ""
        let key = Self.cueKey(action: action, animation: animation)
        guard key != lastRecordedCueKey else { return }
        lastRecordedCueKey = key
        recentCues.insert(CueEvent(action: action, animation: animation), at: 0)
        if recentCues.count > 6 {
            recentCues.removeLast(recentCues.count - 6)
        }
        saveHistory()
    }

    private static func cueKey(action: String, animation: String) -> String {
        "\(action)|\(animation)"
    }

    private struct CachedCatalog: Codable {
        let actions: [DSHPluginAction]
        let animations: [DSHPluginAnimation]
    }

    private static func loadCatalog() -> CachedCatalog? {
        guard let data = try? Data(contentsOf: CuePaths.catalog) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    private static func loadMapping() -> [String: [String]] {
        guard
            let data = try? Data(contentsOf: CuePaths.mapping),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return [:] }
        return object
    }

    private static func loadPaletteFile() -> [String: RGB]? {
        let maps = [CuePaths.palette, CuePaths.legacyPalette, CuePaths.paletteBackup]
            .compactMap(readColourMap)
        return bestColourMap(maps) { id, rgb in
            rgb != CueCatalog.defaultColor(for: id)
        }
    }

    private static func loadBackgroundFile() -> [String: RGB]? {
        let maps = [CuePaths.backgrounds, CuePaths.legacyBackgrounds, CuePaths.backgroundsBackup]
            .compactMap(readColourMap)
        return bestColourMap(maps) { _, rgb in
            rgb != CueCatalog.defaultBackground
        }
    }

    /// Prefer the copy that still has the most custom values. This lets a
    /// wiped or defaulted app store recover from the plugin mirror or backup.
    private static func bestColourMap(_ maps: [[String: RGB]],
                                      isCustom: (String, RGB) -> Bool) -> [String: RGB]? {
        var best: [String: RGB]?
        var bestCount = -1
        for map in maps {
            let count = map.reduce(0) { $0 + (isCustom($1.key, $1.value) ? 1 : 0) }
            if count > bestCount {
                best = map
                bestCount = count
            }
        }
        return best
    }

    private static func readColourMap(_ url: URL) -> [String: RGB]? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        var result: [String: RGB] = [:]
        for (key, value) in object {
            guard let rgb = parseHex(value) else { continue }
            result[key] = rgb
        }
        return result.isEmpty ? nil : result
    }

    private static func backupColourFile(_ source: URL, to backup: URL) {
        guard
            let data = try? Data(contentsOf: source),
            !data.isEmpty,
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return }
        try? data.write(to: backup, options: .atomic)
    }

    private static func loadHistory() -> [CueEvent] {
        guard let data = try? Data(contentsOf: CuePaths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let events = try? decoder.decode([CueEvent].self, from: data) else { return [] }
        return Array(events.prefix(6))
    }

    private func saveHistory() {
        guard !isSnapshotRun else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recentCues) else { return }
        try? data.write(to: CuePaths.history, options: .atomic)
    }

    private static func parseHex(_ value: String) -> RGB? {
        let text = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let number = UInt32(text, radix: 16) else { return nil }
        return RGB(
            r: UInt8((number >> 16) & 0xFF),
            g: UInt8((number >> 8) & 0xFF),
            b: UInt8(number & 0xFF)
        )
    }
}
