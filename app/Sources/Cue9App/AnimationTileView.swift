import SwiftUI

struct AnimationTileView: View {
    let animation: CueAnimation
    let color: Color
    let background: Color
    let selected: Bool
    let mapped: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 5, height: 11)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(background)
                            .frame(width: 5, height: 11)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Cue9Theme.lineStrong, lineWidth: 0.5)
                            )
                    }
                    .frame(width: 5, height: 24)
                    Text(animation.label)
                        .font(Cue9Font.font(11.5, .medium))
                        .foregroundStyle(selected ? Cue9Theme.ink : Cue9Theme.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(animation.label)")
            .accessibilityValue(selected ? "Selected. \(mapped ? "Included in this action" : "Not included")" : (mapped ? "Included in this action" : "Not included"))

            Button(action: onToggle) {
                CheckBox(isOn: mapped)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .help(mapped ? "Remove \(animation.label)" : "Include \(animation.label)")
            .accessibilityLabel(mapped ? "Remove \(animation.label)" : "Include \(animation.label)")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Cue9Theme.surface2 : Cue9Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Cue9Theme.orange.opacity(0.7) : Cue9Theme.line, lineWidth: 1)
        )
    }
}
