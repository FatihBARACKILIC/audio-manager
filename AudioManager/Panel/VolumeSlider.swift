import AudioDomain
import SwiftUI

/// The per-app volume slider: free movement, with a guide mark every 20%.
///
/// `Slider(value:in:step:)` would draw these marks natively, but it also snaps the value
/// to the step, which would leave the user six volume levels to choose from. The marks
/// are drawn instead and the value stays continuous, with a small magnetic pull so the
/// round numbers are easy to land on without being the only choice.
struct VolumeSlider: View {
    @Binding var value: Double
    let label: Text

    /// Distance from the slider's edge to the centre of the thumb at either end.
    ///
    /// Half the thumb's width, so a mark drawn here lines up with where the thumb
    /// actually stops. Measured off a `.mini` slider rendered at 4× — AppKit puts its
    /// own tick marks at 4.0pt and 235.9pt in a 240pt frame.
    private static let trackInset: CGFloat = 4

    var body: some View {
        VStack(spacing: 1) {
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
        Canvas { context, size in
            let span = size.width - VolumeSlider.trackInset * 2
            guard span > 0 else { return }
            let diameter: CGFloat = 1.5

            for index in 0..<VolumeCurve.guidePositions {
                let position = VolumeSlider.trackInset
                    + span * CGFloat(index) / CGFloat(VolumeCurve.guidePositions - 1)
                let dot = CGRect(
                    x: position - diameter / 2,
                    y: 0,
                    width: diameter,
                    height: diameter
                )
                context.fill(Path(ellipseIn: dot), with: .color(.secondary.opacity(0.45)))
            }
        }
        .frame(height: 1.5)
        // The marks are a reading aid for the slider above, which already announces its
        // value; announcing them again would just be noise.
        .accessibilityHidden(true)
    }
}
