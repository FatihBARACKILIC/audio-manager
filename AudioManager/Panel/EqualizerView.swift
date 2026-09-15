import AudioDomain
import SwiftUI

/// Ten vertical band sliders, the shape people expect from a graphic equalizer.
struct EqualizerView: View {
    @Binding var settings: EqualizerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: $settings.isEnabled) {
                    Text("Equalizer")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()

                Button {
                    var reset = settings
                    reset.reset()
                    settings = reset
                } label: {
                    Text("Flat")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(settings.isFlat)
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<EqualizerSettings.bandCount, id: \.self) { band in
                    bandSlider(band)
                }
            }
            .opacity(settings.isEnabled ? 1 : 0.4)
            .disabled(!settings.isEnabled)
        }
    }

    private func bandSlider(_ band: Int) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { settings.gain(at: band) },
                    set: { newValue in
                        var updated = settings
                        updated.setGain(newValue, at: band)
                        settings = updated
                    }
                ),
                in: EqualizerSettings.gainRange
            )
            .controlSize(.mini)
            .frame(width: 58)
            .rotationEffect(.degrees(-90))
            .frame(width: 24, height: 58)
            .accessibilityLabel(Text(label(for: band)))
            .accessibilityValue(Text("\(Int(settings.gain(at: band))) decibels"))

            Text(shortLabel(for: band))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func label(for band: Int) -> String {
        let frequency = EqualizerSettings.bandFrequencies[band]
        return frequency >= 1000
            ? String(format: "%.0f kilohertz", frequency / 1000)
            : String(format: "%.0f hertz", frequency)
    }

    private func shortLabel(for band: Int) -> String {
        let frequency = EqualizerSettings.bandFrequencies[band]
        return frequency >= 1000
            ? String(format: "%.0fk", frequency / 1000)
            : String(format: "%.0f", frequency)
    }
}
