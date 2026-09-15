import Foundation
import Testing

@testable import AudioDomain

@Suite("Volume curve and output limit")
struct VolumeCurveTests {

    @Test("Slider endpoints map to silence and unity")
    func endpoints() {
        #expect(VolumeCurve.gain(forSlider: 0) == 0)
        #expect(VolumeCurve.gain(forSlider: 1) == 1)
    }

    @Test("The curve is monotonic across its range")
    func monotonic() {
        var previous = -1.0
        for step in 0...100 {
            let gain = VolumeCurve.gain(forSlider: Double(step) / 100)
            #expect(gain >= previous)
            previous = gain
        }
    }

    @Test("Gain and slider are inverses")
    func roundTrip() {
        for step in 1...100 {
            let slider = Double(step) / 100
            let roundTripped = VolumeCurve.slider(forGain: VolumeCurve.gain(forSlider: slider))
            #expect(abs(roundTripped - slider) < 0.0001)
        }
    }

    @Test("Values outside the range are clamped and garbage input falls silent")
    func clampsInput() {
        #expect(VolumeCurve.gain(forSlider: -5) == 0)
        #expect(VolumeCurve.gain(forSlider: 5) == 1)
        // Non-finite input is a bug somewhere upstream. Silence is the safe answer for
        // a volume control; guessing "full volume" could hurt someone wearing headphones.
        #expect(VolumeCurve.gain(forSlider: .nan) == 0)
        #expect(VolumeCurve.gain(forSlider: .infinity) == 0)
    }

    @Test("Decibel conversions round-trip")
    func decibelRoundTrip() {
        for decibels in stride(from: -24.0, through: 12.0, by: 1.5) {
            let linear = VolumeCurve.linearGain(fromDecibels: decibels)
            #expect(abs(VolumeCurve.decibels(fromLinearGain: linear) - decibels) < 0.0001)
        }
        #expect(VolumeCurve.linearGain(fromDecibels: 0) == 1)
        #expect(abs(VolumeCurve.linearGain(fromDecibels: 6) - 1.995) < 0.01)
    }

    @Test("Silence is exactly silence, not a very small number")
    func silenceIsSilent() {
        #expect(VolumeCurve.gain(forSlider: VolumeCurve.silenceThreshold) == 0)
        #expect(VolumeCurve.decibels(forSlider: 0) == -.infinity)
    }

    @Test("The output limit caps the final gain and cannot be exceeded by boost")
    func limitCaps() {
        let limit = OutputLimit(maximumGain: 0.5)
        #expect(limit.apply(to: 1) == 0.5)
        #expect(limit.apply(to: 0.25) == 0.25)
        #expect(limit.apply(to: 4) == 0.5)
    }

    @Test("A disabled limit passes gain through untouched")
    func disabledLimit() {
        #expect(OutputLimit.disabled.apply(to: 3) == 3)
    }

    @Test("The limit clamps its own configuration to a sane range")
    func limitClampsConfiguration() {
        #expect(OutputLimit(maximumGain: 99).maximumGain == OutputLimit.range.upperBound)
        #expect(OutputLimit(maximumGain: -1).maximumGain == OutputLimit.range.lowerBound)
        #expect(OutputLimit(maximumGain: .nan).maximumGain == 1)
    }
}
