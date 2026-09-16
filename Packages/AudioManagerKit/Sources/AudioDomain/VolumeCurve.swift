import Foundation

/// Maps the 0...1 slider the user drags onto the linear gain the DSP applies.
///
/// A linear slider sounds wrong: loudness is roughly logarithmic, so a linear 0.5
/// sounds close to full volume. A square-law taper ("audio taper") is the usual
/// compromise — cheap, monotonic, invertible, and close enough to perceptual that a
/// slider at half reads as half as loud.
public enum VolumeCurve {
    /// Anything at or below this slider position is treated as silence, so dragging a
    /// slider to the bottom really is silent instead of -80 dB of hiss.
    public static let silenceThreshold = 0.001

    /// Linear amplitude multiplier for a slider position.
    public static func gain(forSlider slider: Double) -> Double {
        guard slider.isFinite, slider > silenceThreshold else { return 0 }
        let clamped = min(slider, 1)
        return clamped * clamped
    }

    /// Slider position that produces the given linear gain. Inverse of `gain(forSlider:)`.
    public static func slider(forGain gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        return min(gain, 1).squareRoot()
    }

    /// Decibel value of a slider position, for display next to the slider.
    /// Returns `-.infinity` at silence.
    public static func decibels(forSlider slider: Double) -> Double {
        let gain = gain(forSlider: slider)
        guard gain > 0 else { return -.infinity }
        return 20 * log10(gain)
    }

    /// Slider positions the panel marks with a guide dot: every 20 percent.
    public static let guidePositions = 6

    /// How close to a guide the slider has to be before it settles on it.
    ///
    /// Two percent of travel: enough that a round number is easy to land on, small
    /// enough that a value like 37% is still reachable. A volume control that only
    /// offered the six marked steps would be easier to hit and much worse to use.
    public static let guideSnapDistance = 0.02

    /// Pulls a slider position onto the nearest guide mark when it is already close.
    public static func snappedToGuide(_ slider: Double) -> Double {
        guard slider.isFinite else { return 0 }
        let clamped = min(max(slider, 0), 1)
        // Divide rather than multiply by the spacing: 3 * 0.2 is not 0.6 in binary
        // floating point, and a slider that reports 0.6000000000000001 would make the
        // snap pointless — it exists so the value lands on a round number.
        let steps = Double(guidePositions - 1)
        let nearest = (clamped * steps).rounded() / steps
        return abs(clamped - nearest) <= guideSnapDistance ? nearest : clamped
    }

    /// Converts decibels to a linear multiplier (used for boost and EQ makeup gain).
    public static func linearGain(fromDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return decibels > 0 ? 1 : 0 }
        return pow(10, decibels / 20)
    }

    /// Converts a linear multiplier to decibels.
    public static func decibels(fromLinearGain gain: Double) -> Double {
        guard gain > 0 else { return -.infinity }
        return 20 * log10(gain)
    }
}

/// Hearing-safety ceiling applied after every other gain stage.
///
/// This exists so "boost quiet apps" cannot turn into "blow the user's ears out".
/// It is deliberately a hard clamp on the final multiplier rather than a limiter on
/// the signal: predictable, allocation-free, and impossible to bypass from the UI.
public struct OutputLimit: Codable, Sendable, Equatable, Hashable {
    /// Highest linear gain any app may reach. 1.0 means "never louder than the source".
    public private(set) var maximumGain: Double
    public var isEnabled: Bool

    public static let range: ClosedRange<Double> = 0.1...4
    public static let disabled = OutputLimit(maximumGain: OutputLimit.range.upperBound, isEnabled: false)

    public init(maximumGain: Double = 1, isEnabled: Bool = true) {
        self.maximumGain = OutputLimit.clamp(maximumGain)
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumGain = OutputLimit.clamp(try container.decodeIfPresent(Double.self, forKey: .maximumGain) ?? 1)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public mutating func setMaximumGain(_ value: Double) {
        maximumGain = OutputLimit.clamp(value)
    }

    /// Applies the ceiling. Always the last stage of the gain chain.
    public func apply(to gain: Double) -> Double {
        guard isEnabled else { return gain }
        return min(gain, maximumGain)
    }
}
