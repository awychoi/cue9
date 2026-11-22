import Foundation
import SwiftUI

struct ClockWeatherView: View {
    @ObservedObject var model: AppModel
    @Binding var section: AppSection

    @StateObject private var ambient = AmbientPageModel()

    private var target: String? {
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
                    title: "Clock & Weather",
                    subtitle: "Time and weather for cue9's two pages.",
                    trailing: AnyView(statusPill)
                )

                if target != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 18) {
                            AmbientClockPreview(model: model, page: ambient)
                                .frame(width: 300)
                            ClockSettingsCard(page: ambient)
                                .frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 18) {
                            AmbientWeatherPreview(model: model, page: ambient)
                                .frame(width: 300)
                            PlaceSettingsCard(page: ambient)
                                .frame(maxWidth: .infinity)
                        }
                        AmbientSaveRow(page: ambient)
                    }
                } else {
                    setupCard
                }
            }
            .padding(30)
        }
        .task(id: target) {
            if let target {
                await ambient.load(target: target, keyPath: PISetup.runKeyPath)
            }
        }
        .task(id: ambient.weatherQuery) {
            if target != nil {
                await ambient.refreshWeather()
            }
        }
    }

    private var statusPill: some View {
        Group {
            if target == nil {
                Pill(text: "No bridge", color: Cue9Theme.warning)
            } else if ambient.loading {
                Pill(text: "Connecting", color: Cue9Theme.soft)
            } else if ambient.error != nil {
                Pill(text: "Bridge offline", color: Cue9Theme.warning)
            } else {
                Pill(text: "Bridge connected", color: Cue9Theme.success)
            }
        }
    }

    private var setupCard: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Clock and weather need the bridge")
                        .font(Cue9Font.font(17, .semibold))
                        .foregroundStyle(Cue9Theme.ink)
                    Text("The Raspberry Pi sends the time and weather to cue9. It keeps running when this Mac is asleep.")
                        .font(Cue9Font.font(12))
                        .foregroundStyle(Cue9Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 7) {
                        setupStep(1, "Set up the Raspberry Pi.")
                        setupStep(2, "Send your Wi-Fi details to cue9.")
                        setupStep(3, "Choose a city here.")
                    }
                    .padding(.top, 4)

                    Button("Open Connect") {
                        section = .connect
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
                Image(systemName: "clock")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Cue9Theme.orange.opacity(0.55))
                    .padding(.trailing, 12)
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
        }
    }
}

// MARK: - Page model

@MainActor
final class AmbientPageModel: ObservableObject {
    @Published var settings = AmbientSettings.cached() ?? .forThisMac()
    @Published var piZone = ""
    @Published var loading = false
    @Published var saving = false
    @Published var message: String?
    @Published var error: String?
    @Published var cityQuery = AmbientSettings.cached()?.city ?? ""
    @Published var results: [GeoCity] = []
    @Published var searching = false
    @Published var suggestedZone: String?
    @Published var weather: DeviceWeather?

    private var target = ""
    private var keyPath = ""
    private var weatherKey = ""

    init() {
        if CommandLine.arguments.contains("--snapshot-weather") {
            weather = DeviceWeather(
                code: 1, temp: 56, hi: 63, lo: 50, feels: 55,
                units: "F", city: "FRESH MEADOWS"
            )
        }
    }

    var weatherQuery: String {
        "\(settings.lat ?? 0)|\(settings.lon ?? 0)|\(settings.units)|\(settings.city)"
    }

    private var client: AmbientPiClient {
        AmbientPiClient(target: target, keyPath: keyPath)
    }

    func load(target: String, keyPath: String) async {
        guard self.target != target || settings.city.isEmpty else { return }
        self.target = target
        self.keyPath = keyPath
        await load()
    }

    func load() async {
        guard !target.isEmpty else { return }
        loading = true
        error = nil
        do {
            let snapshot = try await client.fetch()
            settings = AmbientSettings.from(snapshot)
            settings.cache()
            piZone = snapshot.piZone ?? ""
            cityQuery = settings.city
            suggestedZone = nil
            message = nil
            await refreshWeather(force: true)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func searchCity() async {
        searching = true
        error = nil
        do {
            results = try await GeoLookup.search(cityQuery)
            if results.isEmpty {
                error = "No place matched “\(cityQuery)”."
            }
        } catch {
            self.error = error.localizedDescription
        }
        searching = false
    }

    func choose(_ city: GeoCity) {
        settings.city = city.name
        settings.lat = city.latitude
        settings.lon = city.longitude
        cityQuery = city.name
        results = []
        suggestedZone = city.timezone
        message = "Location set to \(city.name). Save to apply."
    }

    func clearCity() {
        settings.city = ""
        settings.lat = nil
        settings.lon = nil
        cityQuery = ""
        results = []
        suggestedZone = nil
        message = nil
    }

    func useThisMac() {
        settings.timezone = TimeZone.current.identifier
    }

    func useSuggestedZone() {
        if let suggestedZone {
            settings.timezone = suggestedZone
            self.suggestedZone = nil
        }
    }

    func save() async {
        guard !target.isEmpty else { return }
        saving = true
        error = nil
        message = nil
        do {
            let snapshot = try await client.save(settings)
            settings = AmbientSettings.from(snapshot)
            settings.cache()
            piZone = snapshot.piZone ?? piZone
            cityQuery = settings.city
            suggestedZone = nil
            message = "Saved."
            await refreshWeather(force: true)
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    func refreshWeather(force: Bool = false) async {
        var latitude = settings.lat
        var longitude = settings.lon
        if latitude == nil || longitude == nil, !settings.city.isEmpty {
            if let city = try? await GeoLookup.search(settings.city).first {
                latitude = city.latitude
                longitude = city.longitude
            }
        }
        guard let latitude, let longitude else {
            weather = nil
            return
        }
        let key = "\(latitude),\(longitude),\(settings.units),\(settings.city)"
        if !force, key == weatherKey { return }
        weatherKey = key
        weather = await WeatherLookup.fetch(
            latitude: latitude,
            longitude: longitude,
            units: settings.units,
            city: settings.city
        )
    }
}

// MARK: - Previews

private struct AmbientClockPreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var page: AmbientPageModel

    private var zone: TimeZone {
        TimeZone(identifier: page.settings.timezone)
            ?? TimeZone(identifier: page.piZone)
            ?? .current
    }

    var body: some View {
        DevicePageCard(title: "Clock") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let image = AmbientPageRenderer.render(
                    page: .clock,
                    timeZone: zone,
                    clock24: page.settings.clock == 24,
                    weather: page.weather,
                    status: AmbientStatus.current(for: model),
                    date: context.date
                ) {
                    DevicePageImage(image: image)
                } else {
                    DevicePagePlaceholder(symbol: "clock")
                }
            }
        }
    }
}

private struct AmbientWeatherPreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var page: AmbientPageModel

    private var zone: TimeZone {
        TimeZone(identifier: page.settings.timezone)
            ?? TimeZone(identifier: page.piZone)
            ?? .current
    }

    var body: some View {
        DevicePageCard(title: "Weather") {
            if let image = AmbientPageRenderer.render(
                page: .weather,
                timeZone: zone,
                clock24: page.settings.clock == 24,
                weather: page.weather,
                status: AmbientStatus.current(for: model)
            ) {
                DevicePageImage(image: image)
            } else {
                DevicePagePlaceholder(symbol: "cloud.sun")
            }
        }
    }
}

private struct DevicePageCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(Cue9Font.font(11.5, .semibold))
                    .foregroundStyle(Cue9Theme.onStage)
                Spacer()
                Text("ON CUE9")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Cue9Theme.onStage.opacity(0.42))
            }
            content
                .frame(width: 236, height: 236)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 1))
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(Cue9Theme.stage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DevicePageImage: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
    }
}

private struct DevicePagePlaceholder: View {
    let symbol: String

    var body: some View {
        ZStack {
            Cue9Theme.stage
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Cue9Theme.onStage.opacity(0.5))
        }
    }
}

// MARK: - Settings

private struct ClockSettingsCard: View {
    @ObservedObject var page: AmbientPageModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Clock")
                    .font(Cue9Font.font(15.5, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text("Clock format and units.")
                    .font(Cue9Font.font(12))
                    .foregroundStyle(Cue9Theme.muted)
                    .padding(.top, 4)

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 14)

                settingRow(title: "Time format") {
                    Picker("", selection: $page.settings.clock) {
                        Text("12-hour").tag(12)
                        Text("24-hour").tag(24)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)
                }

                settingRow(title: "Temperature") {
                    Picker("", selection: $page.settings.units) {
                        Text("°F").tag("fahrenheit")
                        Text("°C").tag("celsius")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }

                Text("Swipe cue9 to switch pages.")
                    .font(Cue9Font.font(10))
                    .foregroundStyle(Cue9Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, minHeight: 248, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(Cue9Font.font(11.5, .medium))
                .foregroundStyle(Cue9Theme.ink2)
            Spacer(minLength: 12)
            content()
        }
        .padding(.top, 12)
    }
}

private struct PlaceSettingsCard: View {
    @ObservedObject var page: AmbientPageModel

    private let zoneOptions: [String] = {
        var zones = TimeZone.knownTimeZoneIdentifiers.sorted()
        if !zones.contains(TimeZone.current.identifier) {
            zones.insert(TimeZone.current.identifier, at: 0)
        }
        return zones
    }()

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Place")
                            .font(Cue9Font.font(15.5, .semibold))
                            .foregroundStyle(Cue9Theme.ink)
                        Text("City and timezone.")
                            .font(Cue9Font.font(12))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                    Spacer()
                    if page.loading {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") {
                        Task { await page.load() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(page.loading || page.saving)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 14)

                Text("City")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Cue9Theme.soft)
                    .padding(.top, 14)

                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Cue9Theme.soft)
                        TextField("Search for a city", text: $page.cityQuery)
                            .textFieldStyle(.plain)
                            .font(Cue9Font.font(12))
                            .onSubmit { Task { await page.searchCity() } }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Cue9Theme.line, lineWidth: 1)
                    )

                    Button(page.searching ? "Searching…" : "Search") {
                        Task { await page.searchCity() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(page.searching || page.cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)

                    if page.settings.lat != nil || !page.settings.city.isEmpty {
                        Button("Clear") { page.clearCity() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 6)

                if let city = selectedCityLine {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Cue9Theme.orange)
                        Text(city)
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                    .padding(.top, 7)
                }

                if !page.results.isEmpty {
                    resultsList
                        .padding(.top, 8)
                }

                if let zone = page.suggestedZone, zone != page.settings.timezone {
                    HStack(spacing: 8) {
                        Text("This place uses \(zone).")
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.muted)
                        Button("Use it") { page.useSuggestedZone() }
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }

                Divider()
                    .overlay(Cue9Theme.line)
                    .padding(.top, 14)

                HStack(spacing: 10) {
                    Text("Timezone")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Cue9Theme.soft)
                        .frame(width: 78, alignment: .leading)

                    Picker("", selection: $page.settings.timezone) {
                        Text(page.piZone.isEmpty ? "Pi time" : "Pi time · \(page.piZone)").tag("")
                        ForEach(zoneOptions, id: \.self) { zone in
                            Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 310)

                    Button("Use this Mac") { page.useThisMac() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, minHeight: 248, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var selectedCityLine: String? {
        guard !page.settings.city.isEmpty else { return nil }
        if let lat = page.settings.lat, let lon = page.settings.lon {
            return "\(page.settings.city) · \(String(format: "%.1f, %.1f", lat, lon))"
        }
        return page.settings.city
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(page.results) { city in
                Button {
                    page.choose(city)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Cue9Theme.soft)
                        Text(city.name)
                            .font(Cue9Font.font(11.5, .medium))
                            .foregroundStyle(Cue9Theme.ink2)
                        Text(city.place)
                            .font(Cue9Font.font(10.5))
                            .foregroundStyle(Cue9Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let zone = city.timezone {
                            Text(zone)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Cue9Theme.soft)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }
}

private struct AmbientSaveRow: View {
    @ObservedObject var page: AmbientPageModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let error = page.error {
                    Text(error)
                        .foregroundStyle(Cue9Theme.danger)
                        .lineLimit(4)
                } else if let message = page.message {
                    Text(message)
                        .foregroundStyle(Cue9Theme.muted)
                } else {
                    Text("Saved on the Raspberry Pi.")
                        .foregroundStyle(Cue9Theme.soft)
                }
            }
            .font(Cue9Font.font(10.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button(page.saving ? "Saving…" : "Save") {
                Task { await page.save() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(page.saving || page.loading)
        }
        .padding(.horizontal, 4)
    }
}
