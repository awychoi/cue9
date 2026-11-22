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
    private var lastRecordedCueKey: String?
    private var pendingSync = false
    private var failedPolls = 0
    private var lastPortDiscovery = Date.distantPast
    private var discoveringPort = false

    init() {
        let defaults = UserDefaults.standard
        shakeSensitivity = defaults.object(forKey: "shakeSensitivity") as? Int ?? 3
        dizzySeconds = defaults.object(forKey: "dizzySeconds") as? Double ?? 6
        happySeconds = defaults.object(forKey: "happySeconds") as? Double ?? 2.4

        let savedURL = UserDefaults.standard.string(forKey: "dshURL") ?? "http://127.0.0.1:53614"
        dshURLString = savedURL
        client = DSHClient(baseURL: URL(string: savedURL) ?? URL(string: "http://127.0.0.1:53614")!)

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
        pluginState?.status?.keepAwake == true
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
        client = DSHClient(baseURL: url)
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
        } catch {
            failedPolls += 1
            isReconnecting = everConnected
            dshOnline = false
            pluginState = nil
            pluginError = error.localizedDescription
            await discoverDSHURL()
        }
    }

    /// DSH's web port is assigned per launch. The plugin publishes its bound
    /// origin at `~/.dsh/cue9/dsh.json`; use it only as a fallback when the
    /// saved address is local and stops answering.
    private func discoverDSHURL() async {
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
        let candidate = DSHClient(baseURL: url)
        guard (try? await candidate.state()) != nil else { return }
        dshURLString = url.absoluteString
        UserDefaults.standard.set(dshURLString, forKey: "dshURL")
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
        preview.configure(
            state: CueCatalog.stateIndex(animation),
            ink: palette[animation] ?? CueCatalog.defaultColor(for: animation),
            background: backgrounds[animation] ?? CueCatalog.defaultBackground,
            reset: reset
        )
    }

    func configurePreview(reset: Bool = true) {
        guard !selectedAnimation.isEmpty else { return }
        preview.configure(
            state: CueCatalog.stateIndex(selectedAnimation),
            ink: palette[selectedAnimation] ?? CueCatalog.defaultColor(for: selectedAnimation),
            background: backgrounds[selectedAnimation] ?? CueCatalog.defaultBackground,
            reset: reset
        )
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
            testState = .failed("Connect the DSH plugin first.")
            return
        }
        guard usbConnected else {
            testState = .failed("The mote is not connected over USB.")
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
                    testState = .failed("Sent, but the plugin stopped responding.")
                    return
                }
                testState = .sent
                scheduleTestClear()
            } catch {
                pluginError = error.localizedDescription
                dshOnline = false
                isReconnecting = everConnected
                testState = .failed("Could not reach the DSH plugin.")
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

    func actionUsing(_ animation: String) -> String? {
        if mapping[selectedAction]?.contains(animation) == true {
            return selectedAction
        }
        return actions.first(where: { mapping[$0.id]?.contains(animation) == true })?.id
    }

    func isUnmapped(_ actionID: String) -> Bool {
        (mapping[actionID] ?? []).isEmpty
    }

    func resumeLive() {
        guard dshOnline else {
            testState = .failed("Connect the DSH plugin first.")
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
                testState = .failed("Could not reach the DSH plugin.")
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

    func usedByActions(for animation: String) -> [CueAction] {
        actions.filter { mapping[$0.id]?.contains(animation) == true }
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
            linkError = "Set the Pi's SSH address first."
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

    func setKeepAwake(_ on: Bool) async {
        linkBusy = true
        defer { linkBusy = false }
        do {
            let state = try await client.setLink(transport: linkTransport, keepAwake: on)
            pluginState = state
            linkError = nil
        } catch {
            linkError = error.localizedDescription
        }
    }

    func adoptPiSummary(_ summary: PiSummary) {
        bridgeHost = summary.bridgeTarget
        UserDefaults.standard.set(bridgeHost, forKey: "bridgeHost")
    }

    /// Flash Wi-Fi + the Pi's certificates, then point the plugin at the Pi.
    /// Requires the mote on USB and a Pi summary at ~/.dsh/cue9/pi.json.
    func provisionMote(ssid: String, psk: String) async -> Bool {
        guard let summary = MoteProvisioning.loadSummary() else {
            linkError = "No Pi setup found at ~/.dsh/cue9/pi.json."
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
        dshOnline = false
        pluginState = nil
        isReconnecting = false
        startPolling()
    }

    func usageCount(for animation: String) -> Int {
        mapping.values.filter { $0.contains(animation) }.count
    }

    func mappingSummary(for action: String) -> String {
        let mapped = mapping[action] ?? []
        guard !mapped.isEmpty else { return "No animation" }
        let labels = mapped.map { animationLabel($0) }
        if labels.count <= 2 {
            return labels.joined(separator: " + ")
        }
        return "\(mapped.count) animations"
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
            try data.write(to: CuePaths.mapping, options: .atomic)
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
            try inkData.write(to: CuePaths.palette, options: .atomic)
            try backgroundData.write(to: CuePaths.backgrounds, options: .atomic)
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
