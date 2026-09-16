import Accelerate
import AudioDomain
import CoreAudio
import Foundation
import Synchronization

/// Plain-old-data view of everything the audio thread needs.
///
/// Deliberately free of class references: the IOProc block captures one raw pointer to
/// this struct, so a render callback performs no retain/release, no allocation and no
/// Swift runtime calls. Every buffer it points at is allocated once when the graph is
/// built and freed only after the IOProc has been destroyed.
struct RenderContext {
    var streamCount: Int32
    var bandCount: Int32
    /// Channels per tap. `CATapDescription(stereoMixdownOfProcesses:)` always gives 2.
    var channelsPerStream: Int32

    /// `RenderGraph.coefficientSlotCount` slots of `streamCount * bandCount`
    /// coefficients; the audio thread reads the slot named by `slot`, the control
    /// thread fills a different one.
    var coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// The same number of slots of `streamCount` flags: 1 means "this stream's EQ is
    /// flat, skip it".
    var equalizerBypass: UnsafeMutablePointer<UInt8>
    /// Filter memory: `streamCount * channelsPerStream * bandCount`, audio thread only.
    var states: UnsafeMutablePointer<BiquadState>
    /// Gain the audio thread is currently at, ramped toward `targetGains`.
    var currentGains: UnsafeMutablePointer<Float>
    /// Gain the control thread wants. A single aligned 32-bit store, no tearing.
    var targetGains: UnsafeMutablePointer<Float>
    /// Published coefficient slot, flipped with release ordering after a write.
    var slot: UnsafeMutablePointer<Atomic<UInt32>>
    /// Most recent peak level per stream, for the panel's meters.
    var peaks: UnsafeMutablePointer<Float>
}

/// The whole per-buffer audio computation, in one place.
///
/// Real-time safe: no allocation, no locks, no logging, no Swift runtime calls that can
/// allocate. Work is skipped per buffer wherever the settings make it a no-op, and the
/// per-sample work that is left is handed to `vDSP` rather than written as a Swift
/// loop — mixing, gain and the safety clip are all one pass each over the buffer.
@inline(__always)
func renderTappedAudio(
    context: UnsafeMutablePointer<RenderContext>,
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    frameCount: Int
) {
    let context = context.pointee
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    guard outputBuffers.count > 0, frameCount > 0 else { return }

    let outputBuffer = outputBuffers[0]
    guard let outputData = outputBuffer.mData else { return }
    let outputChannels = Int(outputBuffer.mNumberChannels)
    // A channel count of zero would turn the downmix index below negative; the HAL
    // should never hand us one, but a stale format during a device change must not
    // become a write outside the buffer.
    guard outputChannels > 0 else { return }
    let outputSamples = outputData.assumingMemoryBound(to: Float.self)
    let outputSampleCount = frameCount * outputChannels

    // Start from silence: the aggregate device hands us whatever was in the buffer.
    vDSP_vclr(outputSamples, 1, vDSP_Length(outputSampleCount))

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let slot = Int(context.slot.pointee.load(ordering: .acquiring))
    let bandCount = Int(context.bandCount)
    let channelsPerStream = Int(context.channelsPerStream)
    let declaredStreams = Int(context.streamCount)
    let streamCount = min(declaredStreams, inputBuffers.count)
    let slotBase = slot * declaredStreams

    for stream in 0..<streamCount {
        // A silenced app is the cheapest case there is: its tap has to exist and be
        // read for the mute to hold, but none of its audio is worth a single multiply.
        if context.targetGains[stream] == 0, context.currentGains[stream] == 0 {
            context.peaks[stream] = 0
            continue
        }

        let buffer = inputBuffers[stream]
        guard let data = buffer.mData else { continue }
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }

        let samples = data.assumingMemoryBound(to: Float.self)
        let availableFrames = min(frameCount, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        guard availableFrames > 0 else { continue }

        // Equalizer, unless this stream is flat or on its way to silence.
        //
        // Still a scalar cascade on purpose: ten stereo biquads at 48 kHz are a few
        // million multiply-adds a second, and profiling puts the render callback's
        // whole cost at a fraction of the audio thread. Vectorising this would mean
        // de-interleaving into scratch buffers, which costs two more passes over the
        // audio to save arithmetic that was never the bottleneck.
        if context.targetGains[stream] != 0, context.equalizerBypass[slotBase + stream] == 0 {
            for channel in 0..<min(channels, channelsPerStream) {
                let stateBase = (stream * channelsPerStream + channel) * bandCount
                for band in 0..<bandCount {
                    let section = context.coefficients[(slotBase + stream) * bandCount + band]
                    if section.b0 == 1, section.b1 == 0, section.b2 == 0, section.a1 == 0, section.a2 == 0 {
                        continue
                    }
                    var state = context.states[stateBase + band]
                    var index = channel
                    for _ in 0..<availableFrames {
                        let sample = samples[index]
                        let filtered = section.b0 * sample + state.z1
                        state.z1 = section.b1 * sample - section.a1 * filtered + state.z2
                        state.z2 = section.b2 * sample - section.a2 * filtered
                        samples[index] = filtered
                        index += channels
                    }
                    context.states[stateBase + band] = state
                }
            }
        }

        let target = context.targetGains[stream]
        let gain = context.currentGains[stream]
        let sampleCount = availableFrames * channels

        // The meter wants the level the user hears, but measuring the input and scaling
        // is exact for a steady gain and a safe upper bound while ramping — one pass
        // instead of a compare per sample in the mix loop.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(sampleCount))

        if channels == outputChannels {
            // The common case by far: a stereo tap into a stereo device. Channels line
            // up one for one, so the whole interleaved block is a single vDSP call.
            if gain == target {
                if gain == 1 {
                    // Unity and steady: a plain accumulate, no multiply at all.
                    vDSP_vadd(samples, 1, outputSamples, 1, outputSamples, 1, vDSP_Length(sampleCount))
                } else {
                    var scalar = gain
                    vDSP_vsma(samples, 1, &scalar, outputSamples, 1, outputSamples, 1, vDSP_Length(sampleCount))
                    peak *= gain
                }
            } else {
                // Volume, ramped across the buffer so slider moves do not click. The
                // ramp advances once per frame, so both channels of a frame share a
                // gain and the stereo image does not shift while it glides.
                var step = (target - gain) / Float(availableFrames)
                if channels == 2 {
                    var start = gain
                    vDSP_vrampmuladd2(
                        samples, samples + 1, 2,
                        &start, &step,
                        outputSamples, outputSamples + 1, 2,
                        vDSP_Length(availableFrames)
                    )
                } else {
                    for channel in 0..<channels {
                        var start = gain
                        vDSP_vrampmuladd(
                            samples + channel, vDSP_Stride(channels),
                            &start, &step,
                            outputSamples + channel, vDSP_Stride(channels),
                            vDSP_Length(availableFrames)
                        )
                    }
                }
                peak *= max(gain, target)
                context.currentGains[stream] = target
            }
        } else {
            // Channel counts differ — a mono tap, or a device with more outputs than we
            // captured. Fold by hand; rare enough not to be worth its own vDSP path.
            var rampedGain = gain
            let step = (target - gain) / Float(availableFrames)
            for frame in 0..<availableFrames {
                for channel in 0..<channels {
                    let sample = samples[frame * channels + channel] * rampedGain
                    let outputIndex = frame * outputChannels + min(channel, outputChannels - 1)
                    outputSamples[outputIndex] += sample
                }
                rampedGain += step
            }
            peak *= max(gain, target)
            context.currentGains[stream] = target
        }

        context.peaks[stream] = peak
    }

    // Hard safety clip. Summing several apps can exceed full scale; clipping here is
    // ugly but it is the last line of defence against a painfully loud burst.
    var low: Float = -1
    var high: Float = 1
    vDSP_vclip(outputSamples, 1, &low, &high, outputSamples, 1, vDSP_Length(outputSampleCount))
}

/// Owns the memory the audio thread uses and the aggregate device that drives it.
///
/// Everything is allocated up front in `init` and released in `tearDown`, after the
/// IOProc is destroyed, so the audio thread can never touch freed memory.
final class RenderGraph: @unchecked Sendable {
    // @unchecked Sendable: the buffers are reached only through `context`, which the
    // audio thread reads and the control thread writes under the documented protocol
    // (coefficients published into a rotating slot named by an atomic index).

    /// How many coefficient slots the publish ring holds.
    ///
    /// Two would be the obvious choice, but two is not actually safe: the audio thread
    /// reads the slot index once at the top of a callback and keeps using it for the
    /// rest of that buffer, so a writer that alternates between two slots can land back
    /// on the slot an in-flight callback is still reading. Four means the writer has to
    /// publish four times inside a single buffer — about 10.6 ms at 512 frames — before
    /// it can catch a reader, which no UI gesture can do. Coefficients only change when
    /// an equalizer band moves, so the ring barely turns at all in practice.
    static let coefficientSlotCount = 4

    let streamKeys: [AppKey]
    /// Where each app sits in the stream arrays. Built once so pushing new parameters
    /// for every controlled app is a lookup per app rather than a scan per app.
    let streamIndices: [AppKey: Int]
    private(set) var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private let bandCount = EqualizerSettings.bandCount
    private let channelsPerStream = 2

    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let equalizerBypass: UnsafeMutablePointer<UInt8>
    private let states: UnsafeMutablePointer<BiquadState>
    private let currentGains: UnsafeMutablePointer<Float>
    private let targetGains: UnsafeMutablePointer<Float>
    private let slot: UnsafeMutablePointer<Atomic<UInt32>>
    private let peaks: UnsafeMutablePointer<Float>
    private let context: UnsafeMutablePointer<RenderContext>

    /// The control thread's own copy of what every stream's filter should be, so
    /// publishing one stream never has to read back a slot the audio thread may be
    /// using. Control thread only.
    private var masterCoefficients: [BiquadCoefficients]
    private var masterBypass: [UInt8]
    /// What each stream's equalizer was last set to, so a volume change — by far the
    /// most common update — recomputes nothing and publishes nothing.
    private var publishedEqualizers: [EqualizerSettings?]

    let sampleRate: Double

    init(streamKeys: [AppKey], sampleRate: Double) {
        self.streamKeys = streamKeys
        self.streamIndices = Dictionary(
            streamKeys.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        self.sampleRate = sampleRate

        let streamCount = max(streamKeys.count, 1)
        let slotCount = RenderGraph.coefficientSlotCount
        let coefficientCount = streamCount * bandCount * slotCount
        let stateCount = streamCount * channelsPerStream * bandCount

        coefficients = .allocate(capacity: coefficientCount)
        coefficients.initialize(repeating: .identity, count: coefficientCount)

        equalizerBypass = .allocate(capacity: streamCount * slotCount)
        equalizerBypass.initialize(repeating: 1, count: streamCount * slotCount)

        states = .allocate(capacity: stateCount)
        states.initialize(repeating: BiquadState(), count: stateCount)

        currentGains = .allocate(capacity: streamCount)
        currentGains.initialize(repeating: 1, count: streamCount)

        targetGains = .allocate(capacity: streamCount)
        targetGains.initialize(repeating: 1, count: streamCount)

        peaks = .allocate(capacity: streamCount)
        peaks.initialize(repeating: 0, count: streamCount)

        slot = .allocate(capacity: 1)
        slot.initialize(to: Atomic<UInt32>(0))

        masterCoefficients = Array(repeating: .identity, count: streamCount * bandCount)
        masterBypass = Array(repeating: 1, count: streamCount)
        publishedEqualizers = Array(repeating: nil, count: streamCount)

        context = .allocate(capacity: 1)
        context.initialize(
            to: RenderContext(
                streamCount: Int32(streamKeys.count),
                bandCount: Int32(bandCount),
                channelsPerStream: Int32(channelsPerStream),
                coefficients: coefficients,
                equalizerBypass: equalizerBypass,
                states: states,
                currentGains: currentGains,
                targetGains: targetGains,
                slot: slot,
                peaks: peaks
            )
        )
    }

    deinit {
        releaseBuffers()
    }

    /// Publishes new settings for one stream. Control thread only.
    ///
    /// `ramped` is false only before the IOProc starts, where there is no previous gain
    /// to glide from and starting at the wrong one would leak a buffer of audio from an
    /// app the user just muted.
    func update(streamIndex: Int, gain: Double, equalizer: EqualizerSettings, ramped: Bool = true) {
        guard streamIndex >= 0, streamIndex < streamKeys.count else { return }

        // The gain is a lone aligned 32-bit store the render thread picks up and ramps,
        // so a slider drag costs exactly this and nothing else.
        targetGains[streamIndex] = Float(max(0, gain))
        if !ramped {
            currentGains[streamIndex] = Float(max(0, gain))
        }

        guard publishedEqualizers[streamIndex] != equalizer else { return }
        publishedEqualizers[streamIndex] = equalizer

        var allIdentity = true
        for band in 0..<bandCount {
            let frequency = EqualizerSettings.bandFrequencies[band]
            let decibels = equalizer.isEnabled ? equalizer.gain(at: band) : 0
            let section = PeakingEQ.coefficients(
                frequency: frequency,
                gainDecibels: decibels,
                sampleRate: sampleRate
            )
            masterCoefficients[streamIndex * bandCount + band] = section
            if !section.isIdentity { allIdentity = false }
        }
        masterBypass[streamIndex] = allIdentity ? 1 : 0

        publishCoefficients()
    }

    /// Copies the control thread's master set into the next slot of the ring and names
    /// it as the one to read.
    private func publishCoefficients() {
        let streamCount = max(streamKeys.count, 1)
        let current = Int(slot.pointee.load(ordering: .acquiring))
        let writeSlot = (current + 1) % RenderGraph.coefficientSlotCount

        masterCoefficients.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            (coefficients + writeSlot * streamCount * bandCount)
                .update(from: base, count: streamCount * bandCount)
        }
        masterBypass.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            (equalizerBypass + writeSlot * streamCount).update(from: base, count: streamCount)
        }

        slot.pointee.store(UInt32(writeSlot), ordering: .releasing)
    }

    // MARK: - Test hooks

    /// The slot the audio thread would read right now.
    ///
    /// Exposed so the tests can assert the thing that actually matters about
    /// publishing — that a gain change does not turn the ring — which is invisible from
    /// the rendered audio alone.
    var publishedSlotForTesting: UInt32 {
        slot.pointee.load(ordering: .acquiring)
    }

    /// The live bypass flag for one stream, from the slot that is published now.
    func bypassForTesting(streamIndex: Int) -> UInt8 {
        let streamCount = max(streamKeys.count, 1)
        guard streamIndex >= 0, streamIndex < streamKeys.count else { return 1 }
        return equalizerBypass[Int(publishedSlotForTesting) * streamCount + streamIndex]
    }

    /// Peak level of a stream since the last read, for the meters.
    func peak(atStreamIndex index: Int) -> Float {
        guard index >= 0, index < streamKeys.count else { return 0 }
        return peaks[index]
    }

    /// Starts the IOProc on an aggregate device that was already created.
    func start(aggregateDeviceID: AudioObjectID) throws {
        self.aggregateDeviceID = aggregateDeviceID

        let contextPointer = context
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inputData, _, outputData, _ in
            renderTappedAudio(
                context: contextPointer,
                input: inputData,
                output: outputData,
                frameCount: Int(outputData.pointee.mBuffers.mDataByteSize)
                    / max(1, Int(outputData.pointee.mBuffers.mNumberChannels) * MemoryLayout<Float>.size)
            )
        }
        try CoreAudioError.check(status, "AudioDeviceCreateIOProcIDWithBlock")
        guard let procID else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "IOProc was nil")
        }
        ioProcID = procID

        try CoreAudioError.check(
            AudioDeviceStart(aggregateDeviceID, procID),
            "AudioDeviceStart"
        )
        isRunning = true
    }

    /// Stops and destroys the IOProc. Must happen before the buffers are released.
    func tearDown() {
        if let ioProcID {
            if isRunning {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                isRunning = false
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
    }

    private func releaseBuffers() {
        let streamCount = max(streamKeys.count, 1)
        let slotCount = RenderGraph.coefficientSlotCount
        coefficients.deinitialize(count: streamCount * bandCount * slotCount)
        coefficients.deallocate()
        equalizerBypass.deinitialize(count: streamCount * slotCount)
        equalizerBypass.deallocate()
        states.deinitialize(count: streamCount * channelsPerStream * bandCount)
        states.deallocate()
        currentGains.deinitialize(count: streamCount)
        currentGains.deallocate()
        targetGains.deinitialize(count: streamCount)
        targetGains.deallocate()
        peaks.deinitialize(count: streamCount)
        peaks.deallocate()
        slot.deinitialize(count: 1)
        slot.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
    }
}
