import AudioDomain
import Foundation
import Synchronization

/// Smoothly moves a gain value toward its target across one buffer.
///
/// Applying a new gain instantly produces a step in the waveform, which is audible as
/// a click ("zipper noise") every time the user nudges a slider. Ramping across the
/// buffer costs one multiply-add per sample and removes the artefact entirely.
struct GainRamp {
    private(set) var current: Float
    private(set) var target: Float

    init(gain: Float = 1) {
        current = gain
        target = gain
    }

    mutating func setTarget(_ value: Float) {
        target = value
    }

    /// Jumps straight to the target. Used when starting a stream, where there is no
    /// previous audio to click against.
    mutating func snap() {
        current = target
    }

    var isAtTarget: Bool {
        current == target
    }

    /// Applies the ramp in place. Real-time safe: no allocation, no branching per sample
    /// beyond the ramp itself.
    mutating func apply(
        to buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        stride: Int = 1
    ) {
        guard frameCount > 0 else { return }

        if current == target {
            // Two cheap special cases worth taking: unity gain is a no-op, and silence
            // does not need a multiply per sample.
            if current == 1 { return }
            if current == 0 {
                for frame in 0..<frameCount {
                    buffer[frame * stride] = 0
                }
                return
            }
            let gain = current
            for frame in 0..<frameCount {
                buffer[frame * stride] *= gain
            }
            return
        }

        let step = (target - current) / Float(frameCount)
        var gain = current
        for frame in 0..<frameCount {
            buffer[frame * stride] *= gain
            gain += step
        }
        current = target
    }
}

/// Ten-band graphic equalizer for one stream, safe to run on the audio thread.
///
/// Coefficients are computed off the real-time thread and published through a double
/// buffer: the writer fills the slot the audio thread is not reading, then flips an
/// atomic index. The audio thread never allocates, never locks and never waits.
final class EqualizerBank: @unchecked Sendable {
    // @unchecked Sendable: the mutable state below is either written only from the
    // audio thread (filter memory) or published through `activeSlot`, an atomic index
    // that gives the audio thread a consistent coefficient set without locking.

    private let bandCount: Int
    private let channelCount: Int
    private let sampleRate: Double

    /// Two coefficient slots, `bandCount` entries each, allocated once.
    private let coefficients: UnsafeMutableBufferPointer<BiquadCoefficients>
    /// Filter memory, one state per band per channel, allocated once.
    private let states: UnsafeMutableBufferPointer<BiquadState>

    private let activeSlot = Atomic<Int>(0)
    /// Set when every band is identity, so the audio thread can skip the whole stage.
    private let bypassed = Atomic<Bool>(true)

    init(sampleRate: Double, channelCount: Int, bandCount: Int = EqualizerSettings.bandCount) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.bandCount = max(0, bandCount)

        coefficients = UnsafeMutableBufferPointer<BiquadCoefficients>.allocate(capacity: self.bandCount * 2)
        coefficients.initialize(repeating: .identity)

        states = UnsafeMutableBufferPointer<BiquadState>.allocate(capacity: self.bandCount * self.channelCount)
        states.initialize(repeating: BiquadState())
    }

    deinit {
        coefficients.deinitialize()
        coefficients.deallocate()
        states.deinitialize()
        states.deallocate()
    }

    /// Recomputes coefficients and publishes them. Never call from the audio thread.
    func update(with settings: EqualizerSettings) {
        let writeSlot = 1 - activeSlot.load(ordering: .acquiring)
        var allIdentity = true

        for band in 0..<bandCount {
            let frequency = band < EqualizerSettings.bandFrequencies.count
                ? EqualizerSettings.bandFrequencies[band]
                : 0
            let gain = settings.isEnabled ? settings.gain(at: band) : 0
            let section = PeakingEQ.coefficients(
                frequency: frequency,
                gainDecibels: gain,
                sampleRate: sampleRate
            )
            coefficients[writeSlot * bandCount + band] = section
            if !section.isIdentity {
                allIdentity = false
            }
        }

        activeSlot.store(writeSlot, ordering: .releasing)
        bypassed.store(allIdentity, ordering: .releasing)
    }

    var isBypassed: Bool {
        bypassed.load(ordering: .acquiring)
    }

    /// Clears filter memory. Call when a stream starts, so old audio cannot ring into
    /// the new one.
    func reset() {
        for index in 0..<states.count {
            states[index].reset()
        }
    }

    /// Filters one channel in place. Real-time safe.
    func process(
        _ buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channel: Int,
        stride: Int = 1
    ) {
        guard frameCount > 0, channel >= 0, channel < channelCount else { return }
        guard !bypassed.load(ordering: .acquiring) else { return }

        let slot = activeSlot.load(ordering: .acquiring)

        for band in 0..<bandCount {
            let section = coefficients[slot * bandCount + band]
            if section.isIdentity { continue }

            let stateIndex = channel * bandCount + band
            var state = states[stateIndex]

            for frame in 0..<frameCount {
                let input = buffer[frame * stride]
                let output = section.b0 * input + state.z1
                state.z1 = section.b1 * input - section.a1 * output + state.z2
                state.z2 = section.b2 * input - section.a2 * output
                buffer[frame * stride] = output
            }

            states[stateIndex] = state
        }
    }
}

/// Everything applied to one app's captured audio before it goes back out.
///
/// Order matters and is fixed: equalizer, then volume and boost, then the hearing
/// safety ceiling. The ceiling is last precisely so no earlier stage can defeat it.
final class AppSignalProcessor: @unchecked Sendable {
    // @unchecked Sendable: `equalizer` is internally synchronised and `pendingGain` is
    // an atomic; the ramp itself is touched only from the audio thread.

    private let equalizer: EqualizerBank
    private let pendingGain = Atomic<UInt32>(UInt32(1.0.bitPattern32))
    private var ramp = GainRamp()

    let channelCount: Int

    init(sampleRate: Double, channelCount: Int) {
        self.channelCount = max(1, channelCount)
        equalizer = EqualizerBank(sampleRate: sampleRate, channelCount: self.channelCount)
    }

    /// Applies new settings. Never call from the audio thread.
    func update(gain: Double, equalizerSettings: EqualizerSettings) {
        let clamped = Float(max(0, min(gain, Double(Float.greatestFiniteMagnitude))))
        pendingGain.store(clamped.bitPattern, ordering: .releasing)
        equalizer.update(with: equalizerSettings)
    }

    /// Prepares for a fresh stream: clear filter memory, take the gain without ramping.
    func prepareForStart() {
        equalizer.reset()
        ramp.setTarget(Float(bitPattern: pendingGain.load(ordering: .acquiring)))
        ramp.snap()
    }

    /// Processes one interleaved or deinterleaved channel in place. Real-time safe.
    func process(
        _ buffer: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channel: Int,
        stride: Int = 1
    ) {
        equalizer.process(buffer, frameCount: frameCount, channel: channel, stride: stride)

        // The gain target is read once per buffer, not per sample, so a slider drag
        // costs one atomic load per callback.
        if channel == 0 {
            ramp.setTarget(Float(bitPattern: pendingGain.load(ordering: .acquiring)))
        }
        var channelRamp = ramp
        channelRamp.apply(to: buffer, frameCount: frameCount, stride: stride)
        if channel == channelCount - 1 {
            ramp = channelRamp
        }
    }

    var isTransparent: Bool {
        equalizer.isBypassed && Float(bitPattern: pendingGain.load(ordering: .acquiring)) == 1
    }
}

extension Double {
    /// Single-precision bit pattern, for storing a gain in an atomic.
    fileprivate var bitPattern32: UInt32 {
        Float(self).bitPattern
    }
}
