import Foundation

/// How much of an app's audio we take over.
public enum ControlMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// The tap only silences the app at the source. Nothing is re-rendered, so there is
    /// no added latency and no processing cost. This is the default.
    case muteOnly
    /// The app's audio is captured, processed (volume, boost, EQ) and played back by us.
    /// Costs a few milliseconds of latency, which the settings UI explains.
    case fullControl
}

/// Ten-band graphic equalizer, ISO octave centre frequencies.
public struct EqualizerSettings: Codable, Sendable, Equatable, Hashable {
    public static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = bandFrequencies.count
    public static let gainRange: ClosedRange<Double> = -12...12
    /// Below this the band is treated as flat, so the filter stage can be skipped.
    public static let flatnessThreshold = 0.05

    public var isEnabled: Bool
    /// Gain per band in decibels, always `bandCount` entries, always clamped.
    public private(set) var gains: [Double]

    public static let flat = EqualizerSettings()

    public init(isEnabled: Bool = false, gains: [Double] = Array(repeating: 0, count: bandCount)) {
        self.isEnabled = isEnabled
        self.gains = EqualizerSettings.normalize(gains)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let decoded = try container.decodeIfPresent([Double].self, forKey: .gains) ?? []
        gains = EqualizerSettings.normalize(decoded)
    }

    /// Forces the array to the expected length and clamps every value, so a corrupted
    /// or outdated stored profile can never produce an out-of-range filter.
    private static func normalize(_ gains: [Double]) -> [Double] {
        var normalized = Array(repeating: 0.0, count: bandCount)
        for index in 0..<min(bandCount, gains.count) {
            let value = gains[index]
            normalized[index] = value.isFinite ? min(max(value, gainRange.lowerBound), gainRange.upperBound) : 0
        }
        return normalized
    }

    public mutating func setGain(_ gain: Double, at index: Int) {
        guard index >= 0, index < EqualizerSettings.bandCount else { return }
        let clamped = gain.isFinite ? min(max(gain, EqualizerSettings.gainRange.lowerBound), EqualizerSettings.gainRange.upperBound) : 0
        gains[index] = clamped
    }

    public func gain(at index: Int) -> Double {
        guard index >= 0, index < gains.count else { return 0 }
        return gains[index]
    }

    /// True when the filter stage would be a no-op and can be bypassed entirely.
    public var isFlat: Bool {
        !isEnabled || gains.allSatisfy { abs($0) < EqualizerSettings.flatnessThreshold }
    }

    public mutating func reset() {
        gains = Array(repeating: 0, count: EqualizerSettings.bandCount)
    }
}

/// Everything the user can set for one app.
public struct AppAudioSettings: Codable, Sendable, Equatable, Hashable {
    /// Slider position, 0...1. Mapped to a gain through `VolumeCurve`.
    public private(set) var volume: Double
    /// Extra amplification in decibels on top of the slider, 0...12 dB.
    public private(set) var boostDecibels: Double
    public var isMuted: Bool
    public var mode: ControlMode
    public var equalizer: EqualizerSettings

    public static let boostRange: ClosedRange<Double> = 0...12

    public static let `default` = AppAudioSettings()

    public init(
        volume: Double = 1,
        boostDecibels: Double = 0,
        isMuted: Bool = false,
        mode: ControlMode = .muteOnly,
        equalizer: EqualizerSettings = .flat
    ) {
        self.volume = AppAudioSettings.clampVolume(volume)
        self.boostDecibels = AppAudioSettings.clampBoost(boostDecibels)
        self.isMuted = isMuted
        self.mode = mode
        self.equalizer = equalizer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = AppAudioSettings.clampVolume(try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1)
        boostDecibels = AppAudioSettings.clampBoost(try container.decodeIfPresent(Double.self, forKey: .boostDecibels) ?? 0)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        mode = try container.decodeIfPresent(ControlMode.self, forKey: .mode) ?? .muteOnly
        equalizer = try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer) ?? .flat
    }

    private static func clampVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    private static func clampBoost(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, boostRange.lowerBound), boostRange.upperBound)
    }

    public mutating func setVolume(_ value: Double) {
        volume = AppAudioSettings.clampVolume(value)
    }

    public mutating func setBoost(decibels: Double) {
        boostDecibels = AppAudioSettings.clampBoost(decibels)
    }

    /// Whether these settings need the rendering path, or whether a plain source mute
    /// (or doing nothing at all) achieves the same result.
    public var needsRendering: Bool {
        guard mode == .fullControl else { return false }
        if isMuted { return false }
        return volume < 1 || boostDecibels > 0 || !equalizer.isFlat
    }
}
