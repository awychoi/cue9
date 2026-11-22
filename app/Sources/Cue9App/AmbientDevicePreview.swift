import AppKit
import CoreGraphics
import Cue9Preview
import Foundation

enum AmbientPage: Int {
    case clock = 1
    case weather = 2
}

struct DeviceWeather: Equatable {
    var code: Int          // 0 sunny, 1 partly, 2 rain, 3 snow
    var temp: Int
    var hi: Int
    var lo: Int
    var feels: Int
    var units: String      // "F" or "C"
    var city: String
}

struct AmbientStatus {
    var label: String
    var color: RGB

    @MainActor
    static func current(for model: AppModel) -> AmbientStatus {
        guard model.dshOnline else {
            return AmbientStatus(label: "NO LINK", color: RGB(r: 147, g: 165, b: 177))
        }
        guard let action = model.liveAction else {
            return AmbientStatus(label: "AGENT IDLE", color: RGB(r: 144, g: 223, b: 209))
        }
        switch action {
        case "approval":
            return AmbientStatus(label: "APPROVAL NEEDED", color: RGB(r: 241, g: 189, b: 104))
        case "question":
            return AmbientStatus(label: "QUESTION WAITING", color: RGB(r: 255, g: 145, b: 184))
        case "hub_down":
            return AmbientStatus(label: "NO LINK", color: RGB(r: 147, g: 165, b: 177))
        case "idle", "sleep":
            return AmbientStatus(label: "AGENT IDLE", color: RGB(r: 144, g: 223, b: 209))
        case "thinking":
            return AmbientStatus(label: "THINKING", color: RGB(r: 100, g: 224, b: 236))
        case "tool_read":
            return AmbientStatus(label: "READING", color: RGB(r: 100, g: 224, b: 236))
        case "tool_search":
            return AmbientStatus(label: "SEARCHING", color: RGB(r: 100, g: 224, b: 236))
        case "waiting":
            return AmbientStatus(label: "WAITING", color: RGB(r: 228, g: 187, b: 122))
        case "session_start":
            return AmbientStatus(label: "WAKING", color: RGB(r: 100, g: 224, b: 236))
        case "done":
            return AmbientStatus(label: "DONE", color: RGB(r: 165, g: 230, b: 155))
        case "error":
            return AmbientStatus(label: "RETRYING", color: RGB(r: 228, g: 187, b: 122))
        case "offline":
            return AmbientStatus(label: "OFFLINE", color: RGB(r: 147, g: 165, b: 177))
        default:
            return AmbientStatus(label: "AGENT WORKING", color: RGB(r: 100, g: 224, b: 236))
        }
    }
}

/// Renders the same clock and weather frames the firmware draws. The app shows
/// these as previews, so they should look exactly like cue9's pages.
enum AmbientPageRenderer {
    static func render(
        page: AmbientPage,
        timeZone: TimeZone,
        clock24: Bool,
        weather: DeviceWeather?,
        status: AmbientStatus,
        date: Date = Date()
    ) -> CGImage? {
        let localEpoch = Int64(date.timeIntervalSince1970.rounded())
            + Int64(timeZone.secondsFromGMT(for: date))
        var pixels = [UInt16](repeating: 0, count: 360 * 360)

        let result: Int32 = RendererGate.run {
            guard let context = cue9_ambient_create() else { return -1 }
            defer { cue9_ambient_destroy(context) }

            let city = weather?.city ?? ""
            return status.label.withCString { statusPointer in
                city.withCString { cityPointer in
                    pixels.withUnsafeMutableBufferPointer { buffer in
                        cue9_ambient_render(
                            context,
                            Int32(page.rawValue),
                            localEpoch,
                            clock24 ? 1 : 0,
                            1,
                            statusPointer,
                            status.color.r,
                            status.color.g,
                            status.color.b,
                            weather == nil ? 0 : 1,
                            Int32(weather?.code ?? 0),
                            Int32(weather?.temp ?? 0),
                            Int32(weather?.hi ?? 0),
                            Int32(weather?.lo ?? 0),
                            Int32(weather?.feels ?? 0),
                            CChar(weather?.units == "C" ? 67 : 70),
                            cityPointer,
                            1.1,
                            buffer.baseAddress,
                            Int32(360 * 360)
                        )
                    }
                }
            }
        }

        guard result == 0 else { return nil }
        return cgImage(from: pixels)
    }

    private static func cgImage(from pixels: [UInt16]) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: 360 * 360 * 4)
        for index in 0..<(360 * 360) {
            let colour = pixels[index]
            let red = UInt8((colour >> 11) & 0x1F)
            let green = UInt8((colour >> 5) & 0x3F)
            let blue = UInt8(colour & 0x1F)
            rgba[index * 4 + 0] = (red << 3) | (red >> 2)
            rgba[index * 4 + 1] = (green << 2) | (green >> 4)
            rgba[index * 4 + 2] = (blue << 3) | (blue >> 2)
            rgba[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: 360, height: 360,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 360 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

enum WeatherLookup {
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    /// The same Open-Meteo service the Pi uses, so the app's weather page
    /// shows the same kind of data as the device.
    static func fetch(
        latitude: Double,
        longitude: Double,
        units: String,
        city: String
    ) async -> DeviceWeather? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: units == "celsius" ? "celsius" : "fahrenheit"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let value = try JSONDecoder().decode(Response.self, from: data)
            let code = condition(for: value.current.weather_code)
            let unit = units == "celsius" ? "C" : "F"
            let name = String(
                city.uppercased()
                    .filter { $0.asciiValue != nil && $0.asciiValue! >= 32 }
                    .prefix(18)
            ).trimmingCharacters(in: .whitespaces)
            return DeviceWeather(
                code: code,
                temp: Int(value.current.temperature_2m.rounded()),
                hi: Int((value.daily.temperature_2m_max.first ?? value.current.temperature_2m).rounded()),
                lo: Int((value.daily.temperature_2m_min.first ?? value.current.temperature_2m).rounded()),
                feels: Int(value.current.apparent_temperature.rounded()),
                units: unit,
                city: name
            )
        } catch {
            return nil
        }
    }

    private static func condition(for code: Int) -> Int {
        if code == 0 { return 0 }
        if [71, 73, 75, 77, 85, 86].contains(code) { return 3 }
        if (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code) { return 2 }
        return 1
    }
}
