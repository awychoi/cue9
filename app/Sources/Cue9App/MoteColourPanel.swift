import SwiftUI

struct MoteColourPanel: View {
    @Binding var color: Color
    let defaultColor: Color
    let title: String

    @State private var red: Double
    @State private var green: Double
    @State private var blue: Double
    @State private var hex: String
    @State private var hexError: String?

    init(color: Binding<Color>, defaultColor: Color, title: String, currentAnimation: String) {
        _color = color
        self.defaultColor = defaultColor
        self.title = title
        let rgb = RGB(color: color.wrappedValue)
        _red = State(initialValue: Double(rgb.r))
        _green = State(initialValue: Double(rgb.g))
        _blue = State(initialValue: Double(rgb.b))
        _hex = State(initialValue: rgb.hex)
    }

    private var currentHex: String {
        String(format: "%02x%02x%02x", Int(red), Int(green), Int(blue))
    }

    private var isLight: Bool {
        let rgb = RGB(r: UInt8(red), g: UInt8(green), b: UInt8(blue))
        return (0.2126 * Double(rgb.r) + 0.7152 * Double(rgb.g) + 0.0722 * Double(rgb.b)) > 150
    }

    var body: some View {
        GeometryReader { geo in
            let tall = geo.size.height > 430 && geo.size.width > 390
            ScrollView(.vertical) {
                if tall {
                    tallLayout(width: geo.size.width)
                } else {
                    compactLayout(width: geo.size.width)
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func tallLayout(width: CGFloat) -> some View {
        let swatch = min(64, (width - 32) / 5)
        return VStack(alignment: .leading, spacing: 13) {
            colourPreview(height: 76)

            HStack {
                SectionLabel(text: "Presets")
                Spacer()
                Text("15")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Cue9Theme.soft)
            }

            presetGrid(size: swatch)

            channelSection

            hexSection

            Text("Colours apply the next time this animation runs.")
                .font(Cue9Font.font(10.5))
                .foregroundStyle(Cue9Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func compactLayout(width: CGFloat) -> some View {
        let swatch = min(40, (width * 0.50 - 32) / 5)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Presets")
                Spacer()
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 13, height: 13)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Cue9Theme.lineStrong, lineWidth: 1))
                    Text("#\(currentHex)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Cue9Theme.muted)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                presetGrid(size: swatch)
                    .frame(width: width * 0.50, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    channelSection
                    hexSection
                    Text("Applies next run.")
                        .font(Cue9Font.font(10))
                        .foregroundStyle(Cue9Theme.soft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colourPreview(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Cue9Font.font(10.5, .medium))
                Spacer()
                Text("#\(currentHex)")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(isLight ? Cue9Theme.ink : Cue9Theme.onStage)
            .padding(11)
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Cue9Theme.lineStrong, lineWidth: 1)
        )
    }

    private func presetGrid(size: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(size), spacing: 8), count: 5),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(CueCatalog.colourPresets) { preset in
                Button {
                    apply(preset.color)
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(preset.color)
                        .frame(width: size, height: size * 0.72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    isSelected(preset) ? Cue9Theme.orange : Cue9Theme.lineStrong,
                                    lineWidth: isSelected(preset) ? 2 : 1
                                )
                        )
                        .overlay {
                            if isSelected(preset) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(preset.hex == 0x11110F ? Color.white : Color.black.opacity(0.72))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(preset.name) · #\(String(format: "%06x", preset.hex))")
                .accessibilityLabel("\(preset.name) preset")
                .accessibilityValue("#\(String(format: "%06x", preset.hex))\(isSelected(preset) ? ", selected" : "")")
            }
        }
    }

    private var channelSection: some View {
        VStack(spacing: 7) {
            ChannelRow(label: "R", value: redBinding, color: Color(hex: 0xFF4B3E), onEdit: apply)
            ChannelRow(label: "G", value: greenBinding, color: Color(hex: 0x39D353), onEdit: apply)
            ChannelRow(label: "B", value: blueBinding, color: Color(hex: 0x4B8BFF), onEdit: apply)
        }
    }

    private var hexSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                HStack(spacing: 2) {
                    Text("#")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Cue9Theme.soft)
                    TextField("rrggbb", text: $hex)
                        .textFieldStyle(Cue9TextFieldStyle())
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { applyHex() }
                        .frame(maxWidth: 136)
                }

                Button("Set") { applyHex() }
                    .buttonStyle(SecondaryButtonStyle())

                Button {
                    apply(defaultColor)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Cue9Theme.soft)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset to the default colour")
                .accessibilityLabel("Reset to default colour")
            }

            if let hexError {
                Text(hexError)
                    .font(Cue9Font.font(10))
                    .foregroundStyle(Cue9Theme.danger)
            }
        }
    }

    private func isSelected(_ preset: ColourPreset) -> Bool {
        currentHex.lowercased() == String(format: "%06x", preset.hex)
    }

    private var redBinding: Binding<Double> {
        Binding(get: { red }, set: { red = $0; apply() })
    }

    private var greenBinding: Binding<Double> {
        Binding(get: { green }, set: { green = $0; apply() })
    }

    private var blueBinding: Binding<Double> {
        Binding(get: { blue }, set: { blue = $0; apply() })
    }

    private func apply() {
        color = Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
        hex = currentHex
        hexError = nil
    }

    private func apply(_ newColor: Color) {
        let rgb = RGB(color: newColor)
        red = Double(rgb.r)
        green = Double(rgb.g)
        blue = Double(rgb.b)
        hex = rgb.hex
        hexError = nil
        color = newColor
    }

    private func applyHex() {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            hexError = "Use six hex characters, for example ff6a00."
            return
        }
        apply(Color(hex: value))
    }
}

private struct ChannelRow: View {
    let label: String
    @Binding var value: Double
    let color: Color
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Cue9Theme.soft)
                .frame(width: 10)

            GeometryReader { geo in
                let fraction = CGFloat(value / 255)
                let knob: CGFloat = 14
                let travel = max(1, geo.size.width - knob)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Cue9Theme.surface2)
                        .overlay(
                            Capsule()
                                .stroke(Cue9Theme.line, lineWidth: 1)
                        )
                    LinearGradient(
                        colors: [Color.black, color],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(Capsule())
                    .opacity(0.9)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 1))
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .offset(x: travel * fraction)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let x = min(max(0, gesture.location.x - knob / 2), travel)
                            value = Double(x / travel) * 255
                            onEdit()
                        }
                )
            }
            .frame(height: 18)

            Text("\(Int(value))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Cue9Theme.muted)
                .frame(width: 27, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "R" ? "Red" : label == "G" ? "Green" : "Blue")
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(255, value + 1)
            case .decrement:
                value = max(0, value - 1)
            @unknown default:
                break
            }
            onEdit()
        }
    }
}
