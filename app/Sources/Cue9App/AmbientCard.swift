import Foundation
import SwiftUI

/// Timezone and place for the clock and weather pages. The Pi stores them;
/// the app reads and writes them over the bridge's restricted SSH key.
struct AmbientCard: View {
    let target: String
    let keyPath: String

    @State private var settings = AmbientSettings.cached() ?? .forThisMac()
    @State private var piZone = ""
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var cityQuery = AmbientSettings.cached()?.city ?? ""
    @State private var results: [GeoCity] = []
    @State private var searching = false
    @State private var suggestedZone: String?

    private enum Layout {
        static let label: CGFloat = 84
        static let gap: CGFloat = 10
    }

    private var client: AmbientPiClient {
        AmbientPiClient(target: target, keyPath: keyPath)
    }

    private var zoneOptions: [String] {
        var zones = TimeZone.knownTimeZoneIdentifiers.sorted()
        if !settings.timezone.isEmpty, !zones.contains(settings.timezone) {
            zones.insert(settings.timezone, at: 0)
        }
        return zones
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                form
                divider.padding(.top, 15)
                footer.padding(.top, 12)
            }
        }
        .task(id: target) { await load() }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ambient")
                    .font(Cue9Font.font(15.5, .semibold))
                    .foregroundStyle(Cue9Theme.ink)
                Text("Time and place for the clock and weather pages. Stored on the Pi, so they keep working when this Mac sleeps.")
                    .font(Cue9Font.font(12))
                    .foregroundStyle(Cue9Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if loading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { Task { await load() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(loading || saving)
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Cue9Theme.line)
            .padding(.top, 15)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let error {
                    Text(error)
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.danger)
                        .lineLimit(4)
                } else if let message {
                    Text(message)
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.muted)
                } else {
                    Text("Timezone first, then search for the place. The Pi re-sends both to the mote as soon as you save.")
                        .font(Cue9Font.font(11))
                        .foregroundStyle(Cue9Theme.soft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            Button(saving ? "Saving…" : "Save to Pi") {
                Task { await save() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(saving || loading)
        }
    }

    // MARK: - Form

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: Layout.gap, verticalSpacing: 12) {
            GridRow {
                label("Timezone")
                HStack(spacing: 10) {
                    Picker("", selection: $settings.timezone) {
                        Text(piZone.isEmpty ? "Pi local" : "Pi local · \(piZone)").tag("")
                        ForEach(zoneOptions, id: \.self) { zone in
                            Text(zone).tag(zone)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 300)
                    Spacer(minLength: 8)
                    Button("This Mac") {
                        settings.timezone = TimeZone.current.identifier
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            GridRow {
                label("Location")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        TextField("City", text: $cityQuery)
                            .textFieldStyle(.plain)
                            .font(Cue9Font.font(12))
                            .padding(.horizontal, 9)
                            .frame(width: 240, height: 30)
                            .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Cue9Theme.line, lineWidth: 1)
                            )
                            .onSubmit { Task { await searchCity() } }
                        Button(searching ? "Searching…" : "Search") {
                            Task { await searchCity() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(searching || cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                        if settings.lat != nil || !settings.city.isEmpty {
                            Button("Clear") {
                                settings.city = ""
                                settings.lat = nil
                                settings.lon = nil
                                cityQuery = ""
                                results = []
                                suggestedZone = nil
                                message = nil
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Spacer(minLength: 0)
                    }
                    if let lat = settings.lat, let lon = settings.lon {
                        Text("\(settings.city.isEmpty ? "Pinned point" : settings.city) · \(String(format: "%.2f, %.2f", lat, lon))")
                            .font(Cue9Font.font(11))
                            .foregroundStyle(Cue9Theme.muted)
                    }
                    if !results.isEmpty {
                        resultsList
                    }
                    if let suggestedZone, suggestedZone != settings.timezone {
                        suggestedRow(suggestedZone)
                    }
                }
            }

            GridRow {
                label("Units")
                Picker("", selection: $settings.units) {
                    Text("°F").tag("fahrenheit")
                    Text("°C").tag("celsius")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            GridRow {
                label("Clock")
                Picker("", selection: $settings.clock) {
                    Text("12-hour").tag(12)
                    Text("24-hour").tag(24)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
        }
        .padding(.top, 13)
    }

    private func label(_ text: String) -> some View {
        SectionLabel(text: text)
            .frame(width: Layout.label, alignment: .leading)
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(results) { city in
                Button {
                    choose(city)
                } label: {
                    HStack(spacing: 8) {
                        Text(city.name)
                            .font(Cue9Font.font(12, .medium))
                            .foregroundStyle(Cue9Theme.ink2)
                        Text(city.place)
                            .font(Cue9Font.font(11))
                            .foregroundStyle(Cue9Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let zone = city.timezone {
                            Text(zone)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Cue9Theme.soft)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Cue9Theme.paper, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Cue9Theme.line, lineWidth: 1)
        )
    }

    private func suggestedRow(_ zone: String) -> some View {
        HStack(spacing: 8) {
            Text("This place uses \(zone).")
                .font(Cue9Font.font(11))
                .foregroundStyle(Cue9Theme.muted)
            Button("Use it") {
                settings.timezone = zone
                suggestedZone = nil
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func load() async {
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
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func searchCity() async {
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

    private func choose(_ city: GeoCity) {
        settings.city = city.name
        settings.lat = city.latitude
        settings.lon = city.longitude
        cityQuery = city.name
        results = []
        suggestedZone = city.timezone
        message = "Location set to \(city.name). Save to send it to the Pi."
    }

    private func save() async {
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
            message = "Saved on the Pi. The clock and weather update within a second."
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
