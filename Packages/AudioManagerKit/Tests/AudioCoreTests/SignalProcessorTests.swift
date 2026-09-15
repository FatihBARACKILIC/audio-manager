import AudioDomain
import Foundation
import Testing

@testable import AudioCore

@Suite("Signal processing")
struct SignalProcessorTests {

    private let sampleRate = 48000.0

    private func sine(frequency: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// RMS of the second half only, so the filter's start-up transient is excluded.
    private func settledRMS(_ samples: [Float]) -> Double {
        let tail = samples[(samples.count / 2)...]
        let sum = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(tail.count)).squareRoot()
    }

    // MARK: - Coefficients

    @Test("A peaking band hits its requested gain at its centre frequency")
    func peakingGainAtCentre() {
        for decibels in [-12.0, -6.0, 3.0, 12.0] {
            let coefficients = PeakingEQ.coefficients(
                frequency: 1000,
                gainDecibels: decibels,
                sampleRate: sampleRate
            )
            let magnitude = coefficients.magnitude(atFrequency: 1000, sampleRate: sampleRate)
            let expected = pow(10, decibels / 20)

            #expect(abs(magnitude - expected) < expected * 0.02)
        }
    }

    @Test("A peaking band leaves distant frequencies alone")
    func peakingIsLocal() {
        let coefficients = PeakingEQ.coefficients(frequency: 1000, gainDecibels: 12, sampleRate: sampleRate)

        #expect(abs(coefficients.magnitude(atFrequency: 50, sampleRate: sampleRate) - 1) < 0.05)
        #expect(abs(coefficients.magnitude(atFrequency: 16000, sampleRate: sampleRate) - 1) < 0.05)
    }

    @Test("Degenerate configurations become a pass-through instead of an unstable filter")
    func degenerateCoefficients() {
        #expect(PeakingEQ.coefficients(frequency: 1000, gainDecibels: 0, sampleRate: sampleRate).isIdentity)
        #expect(PeakingEQ.coefficients(frequency: 30000, gainDecibels: 6, sampleRate: sampleRate).isIdentity)
        #expect(PeakingEQ.coefficients(frequency: 0, gainDecibels: 6, sampleRate: sampleRate).isIdentity)
        #expect(PeakingEQ.coefficients(frequency: 1000, gainDecibels: 6, sampleRate: 0).isIdentity)
        #expect(PeakingEQ.coefficients(frequency: 1000, gainDecibels: 6, sampleRate: sampleRate, q: 0).isIdentity)
    }

    // MARK: - Equalizer bank

    @Test("A flat equalizer is bypassed and leaves the signal untouched")
    func flatIsBypassed() {
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 2)
        bank.update(with: .flat)

        #expect(bank.isBypassed)

        var samples = sine(frequency: 1000, frames: 512)
        let original = samples
        samples.withUnsafeMutableBufferPointer { buffer in
            bank.process(buffer.baseAddress!, frameCount: buffer.count, channel: 0)
        }

        #expect(samples == original)
    }

    @Test("An enabled band with zero gain is still a bypass")
    func enabledButZeroIsBypassed() {
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 2)
        bank.update(with: EqualizerSettings(isEnabled: true))

        #expect(bank.isBypassed)
    }

    @Test("Boosting the 1 kHz band raises a 1 kHz tone by the requested amount")
    func boostsTargetBand() {
        var settings = EqualizerSettings(isEnabled: true)
        settings.setGain(12, at: 5) // 1000 Hz
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 1)
        bank.update(with: settings)

        #expect(!bank.isBypassed)

        var samples = sine(frequency: 1000, frames: 24000)
        let inputRMS = settledRMS(samples)
        samples.withUnsafeMutableBufferPointer { buffer in
            bank.process(buffer.baseAddress!, frameCount: buffer.count, channel: 0)
        }
        let outputRMS = settledRMS(samples)

        let ratio = outputRMS / inputRMS
        #expect(abs(ratio - pow(10, 12.0 / 20)) < 0.2)
    }

    @Test("Cutting a band lowers only that band")
    func cutsTargetBand() {
        var settings = EqualizerSettings(isEnabled: true)
        settings.setGain(-12, at: 5) // 1000 Hz
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 1)
        bank.update(with: settings)

        var atBand = sine(frequency: 1000, frames: 24000)
        var farAway = sine(frequency: 60, frames: 24000)
        let farAwayInput = settledRMS(farAway)

        atBand.withUnsafeMutableBufferPointer { bank.process($0.baseAddress!, frameCount: $0.count, channel: 0) }
        bank.reset()
        farAway.withUnsafeMutableBufferPointer { bank.process($0.baseAddress!, frameCount: $0.count, channel: 0) }

        #expect(settledRMS(atBand) < 0.2)
        #expect(abs(settledRMS(farAway) - farAwayInput) < farAwayInput * 0.15)
    }

    @Test("The filter stays stable over a long signal at extreme settings")
    func staysStable() {
        var settings = EqualizerSettings(isEnabled: true)
        for band in 0..<EqualizerSettings.bandCount {
            settings.setGain(band.isMultiple(of: 2) ? 12 : -12, at: band)
        }
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 1)
        bank.update(with: settings)

        var samples = sine(frequency: 440, frames: 48000, amplitude: 0.9)
        samples.withUnsafeMutableBufferPointer { bank.process($0.baseAddress!, frameCount: $0.count, channel: 0) }

        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.allSatisfy { abs($0) < 20 })
    }

    @Test("Channels keep separate filter memory")
    func channelsAreIndependent() {
        var settings = EqualizerSettings(isEnabled: true)
        settings.setGain(12, at: 5)
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 2)
        bank.update(with: settings)

        var left = sine(frequency: 1000, frames: 4096)
        var right = left
        left.withUnsafeMutableBufferPointer { bank.process($0.baseAddress!, frameCount: $0.count, channel: 0) }
        right.withUnsafeMutableBufferPointer { bank.process($0.baseAddress!, frameCount: $0.count, channel: 1) }

        #expect(left == right)
    }

    @Test("Interleaved buffers are filtered per channel using the stride")
    func respectsStride() {
        var settings = EqualizerSettings(isEnabled: true)
        settings.setGain(12, at: 5)
        let bank = EqualizerBank(sampleRate: sampleRate, channelCount: 2)
        bank.update(with: settings)

        let mono = sine(frequency: 1000, frames: 4096)
        var interleaved = [Float](repeating: 0, count: mono.count * 2)
        for index in 0..<mono.count {
            interleaved[index * 2] = mono[index]      // left gets the tone
            interleaved[index * 2 + 1] = 0             // right stays silent
        }

        interleaved.withUnsafeMutableBufferPointer { buffer in
            bank.process(buffer.baseAddress!, frameCount: mono.count, channel: 0, stride: 2)
        }

        let right = stride(from: 1, to: interleaved.count, by: 2).map { interleaved[$0] }
        #expect(right.allSatisfy { $0 == 0 })
        #expect(settledRMS(stride(from: 0, to: interleaved.count, by: 2).map { interleaved[$0] }) > settledRMS(mono))
    }

    // MARK: - Gain ramp

    @Test("Unity gain does not touch the buffer")
    func unityIsNoOp() {
        var ramp = GainRamp(gain: 1)
        var samples = sine(frequency: 440, frames: 64)
        let original = samples

        samples.withUnsafeMutableBufferPointer { ramp.apply(to: $0.baseAddress!, frameCount: $0.count) }

        #expect(samples == original)
    }

    @Test("Zero gain silences the buffer exactly")
    func zeroIsSilence() {
        var ramp = GainRamp(gain: 0)
        var samples = sine(frequency: 440, frames: 64)

        samples.withUnsafeMutableBufferPointer { ramp.apply(to: $0.baseAddress!, frameCount: $0.count) }

        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test("A gain change ramps across the buffer instead of stepping")
    func rampsSmoothly() {
        var ramp = GainRamp(gain: 1)
        ramp.setTarget(0)

        var samples = [Float](repeating: 1, count: 128)
        samples.withUnsafeMutableBufferPointer { ramp.apply(to: $0.baseAddress!, frameCount: $0.count) }

        #expect(samples.first == 1)
        #expect(samples.last! < 0.05)
        // Strictly decreasing: no step, no overshoot.
        for index in 1..<samples.count {
            #expect(samples[index] < samples[index - 1])
        }
        #expect(ramp.isAtTarget)
    }

    @Test("Ramping finishes within one buffer and holds afterwards")
    func rampCompletes() {
        var ramp = GainRamp(gain: 0)
        ramp.setTarget(0.5)

        var first = [Float](repeating: 1, count: 32)
        first.withUnsafeMutableBufferPointer { ramp.apply(to: $0.baseAddress!, frameCount: $0.count) }

        var second = [Float](repeating: 1, count: 32)
        second.withUnsafeMutableBufferPointer { ramp.apply(to: $0.baseAddress!, frameCount: $0.count) }

        #expect(second.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("An empty buffer is handled without touching memory")
    func emptyBuffer() {
        var ramp = GainRamp(gain: 0.5)
        var samples: [Float] = []
        samples.withUnsafeMutableBufferPointer { buffer in
            ramp.apply(to: buffer.baseAddress ?? UnsafeMutablePointer<Float>.allocate(capacity: 1), frameCount: 0)
        }
        #expect(samples.isEmpty)
    }

    // MARK: - Combined processor

    @Test("The processor applies gain and reports transparency correctly")
    func processorAppliesGain() {
        let processor = AppSignalProcessor(sampleRate: sampleRate, channelCount: 1)
        processor.update(gain: 0.5, equalizerSettings: .flat)
        processor.prepareForStart()

        #expect(!processor.isTransparent)

        var samples = [Float](repeating: 1, count: 64)
        samples.withUnsafeMutableBufferPointer {
            processor.process($0.baseAddress!, frameCount: $0.count, channel: 0)
        }

        #expect(samples.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("Unity gain with a flat equalizer is reported as transparent")
    func transparentWhenIdle() {
        let processor = AppSignalProcessor(sampleRate: sampleRate, channelCount: 2)
        processor.update(gain: 1, equalizerSettings: .flat)

        #expect(processor.isTransparent)
    }
}
