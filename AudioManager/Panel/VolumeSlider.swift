import AudioDomain
import SwiftUI

/// The per-app volume slider: free movement, with a guide mark every 20%.
///
/// `Slider(value:in:step:)` would draw these marks natively, but it also snaps the value
/// to the step, which would leave the user six volume levels to choose from. The marks
/// are drawn instead and the value stays continuous, with a small magnetic pull so the
/// round numbers are easy to land on without being the only choice — and each mark is a
/// button, so a round number is one click away rather than something to aim for.
struct VolumeSlider: View {
    @Binding var value: Double
    let label: Text

    @State private var hoveredMark: Int?

    /// Distance from the slider's edge to the centre of the thumb at either end.
    ///
    /// Half the thumb's width, so a mark drawn here lines up with where the thumb
    /// actually stops. Measured off a `.mini` slider rendered at 4× — AppKit puts its
    /// own tick marks at 4.0pt and 235.9pt in a 240pt frame.
    private static let trackInset: CGFloat = 4

    private static let markDiameter: CGFloat = 4

    /// The invisible area around a mark that takes the click.
    ///
    /// A 4pt dot is far too small to hit comfortably. Marks sit about 40pt apart in the
    /// panel, so an 18pt target is generous without two of them ever overlapping.
    private static let markHitWidth: CGFloat = 18
    private static let markRowHeight: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { value },
                    set: { value = VolumeCurve.snappedToGuide($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .accessibilityLabel(label)
            .accessibilityValue(Text("\(Int(value * 100)) percent"))

            marks
        }
    }

    private var marks: some View {
        GeometryReader { proxy in
            let span = proxy.size.width - VolumeSlider.trackInset * 2
            ForEach(0..<VolumeCurve.guidePositions, id: \.self) { index in
                let fraction = Double(index) / Double(VolumeCurve.guidePositions - 1)

                Button {
                    value = fraction
                } label: {
                    Circle()
                        .fill(color(for: fraction, isHovered: hoveredMark == index))
                        .frame(
                            width: VolumeSlider.markDiameter,
                            height: VolumeSlider.markDiameter
                        )
                        .frame(
                            width: VolumeSlider.markHitWidth,
                            height: VolumeSlider.markRowHeight
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hoveredMark = $0 ? index : nil }
                .help(Text("Set volume to \(Int(fraction * 100)) percent"))
                .accessibilityLabel(Text("Set volume to \(Int(fraction * 100)) percent"))
                .position(
                    x: VolumeSlider.trackInset + span * fraction,
                    y: VolumeSlider.markRowHeight / 2
                )
            }
        }
        .frame(height: VolumeSlider.markRowHeight)
    }

    /// The mark the slider is sitting on is filled with the accent colour, so the row
    /// says where it is as well as where it could go.
    private func color(for fraction: Double, isHovered: Bool) -> Color {
        if abs(value - fraction) < 0.001 {
            return .accentColor
        }
        return .secondary.opacity(isHovered ? 1 : 0.6)
    }
}
