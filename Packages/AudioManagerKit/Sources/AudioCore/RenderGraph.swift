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

    /// Two slots of `streamCount * bandCount` coefficients; the audio thread reads the
    /// slot named by `slot`, the control thread fills the other one.
    var coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// Two slots of `streamCount` flags: 1 means "this stream's EQ is flat, skip it".
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
/// allocate. Work is skipped per buffer wherever the settings make it a no-op.
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
    let outputSamples = outputData.assumingMemoryBound(to: Float.self)
    let outputSampleCount = frameCount * outputChannels

    // Start from silence: the aggregate device hands us whatever was in the buffer.
    for index in 0..<outputSampleCount {
        outputSamples[index] = 0
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let slot = Int(context.slot.pointee.load(ordering: .acquiring))
    let bandCount = Int(context.bandCount)
    let channelsPerStream = Int(context.channelsPerStream)
    let streamCount = min(Int(context.streamCount), inputBuffers.count)

    for stream in 0..<streamCount {
        let buffer = inputBuffers[stream]
        guard let data = buffer.mData else { continue }
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }

        let samples = data.assumingMemoryBound(to: Float.self)
        let availableFrames = min(frameCount, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        guard availableFrames > 0 else { continue }

        // Equalizer, unless this stream is flat.
        if context.equalizerBypass[slot * Int(context.streamCount) + stream] == 0 {
            for channel in 0..<min(channels, channelsPerStream) {
                let stateBase = (stream * channelsPerStream + channel) * bandCount
                for band in 0..<bandCount {
                    let section = context.coefficients[(slot * Int(context.streamCount) + stream) * bandCount + band]
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

        // Volume, ramped across the buffer so slider moves do not click.
        let target = context.targetGains[stream]
        var gain = context.currentGains[stream]
        let step = (target - gain) / Float(availableFrames)
        var peak: Float = 0

        if gain == target, gain == 1 {
            // Unity and steady: mix straight through, no multiply at all.
            for frame in 0..<availableFrames {
                for channel in 0..<channels {
                    let sample = samples[frame * channels + channel]
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    let outputIndex = frame * outputChannels + min(channel, outputChannels - 1)
                    outputSamples[outputIndex] += sample
                }
            }
        } else {
            for frame in 0..<availableFrames {
                for channel in 0..<channels {
                    let sample = samples[frame * channels + channel] * gain
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    let outputIndex = frame * outputChannels + min(channel, outputChannels - 1)
                    outputSamples[outputIndex] += sample
                }
                gain += step
            }
            context.currentGains[stream] = target
        }

        context.peaks[stream] = peak
    }

    // Hard safety clip. Summing several apps can exceed full scale; clipping here is
    // ugly but it is the last line of defence against a painfully loud burst.
    for index in 0..<outputSampleCount {
        let sample = outputSamples[index]
        if sample > 1 {
            outputSamples[index] = 1
        } else if sample < -1 {
            outputSamples[index] = -1
        }
    }
}

/// Owns the memory the audio thread uses and the aggregate device that drives it.
///
/// Everything is allocated up front in `init` and released in `tearDown`, after the
/// IOProc is destroyed, so the audio thread can never touch freed memory.
final class RenderGraph: @unchecked Sendable {
    // @unchecked Sendable: the buffers are reached only through `context`, which the
    // audio thread reads and the control thread writes under the documented protocol
    // (double-buffered coefficients published through an atomic slot index).

    let streamKeys: [AppKey]
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

    let sampleRate: Double

    init(streamKeys: [AppKey], sampleRate: Double) {
        self.streamKeys = streamKeys
        self.sampleRate = sampleRate

        let streamCount = max(streamKeys.count, 1)
        let coefficientCount = streamCount * bandCount * 2
        let stateCount = streamCount * channelsPerStream * bandCount

        coefficients = .allocate(capacity: coefficientCount)
        coefficients.initialize(repeating: .identity, count: coefficientCount)

        equalizerBypass = .allocate(capacity: streamCount * 2)
        equalizerBypass.initialize(repeating: 1, count: streamCount * 2)

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
    func update(streamIndex: Int, gain: Double, equalizer: EqualizerSettings) {
        guard streamIndex >= 0, streamIndex < streamKeys.count else { return }

        targetGains[streamIndex] = Float(max(0, gain))

        let streamCount = max(streamKeys.count, 1)
        let writeSlot = Int(1 - slot.pointee.load(ordering: .acquiring))
        var allIdentity = true

        for band in 0..<bandCount {
            let frequency = EqualizerSettings.bandFrequencies[band]
            let decibels = equalizer.isEnabled ? equalizer.gain(at: band) : 0
            let section = PeakingEQ.coefficients(
                frequency: frequency,
                gainDecibels: decibels,
                sampleRate: sampleRate
            )
            coefficients[(writeSlot * streamCount + streamIndex) * bandCount + band] = section
            if !section.isIdentity { allIdentity = false }
        }

        // Carry the other streams' flags into the slot we are about to publish.
        for stream in 0..<streamKeys.count where stream != streamIndex {
            let readSlot = Int(slot.pointee.load(ordering: .acquiring))
            equalizerBypass[writeSlot * streamCount + stream] = equalizerBypass[readSlot * streamCount + stream]
            for band in 0..<bandCount {
                coefficients[(writeSlot * streamCount + stream) * bandCount + band] =
                    coefficients[(readSlot * streamCount + stream) * bandCount + band]
            }
        }

        equalizerBypass[writeSlot * streamCount + streamIndex] = allIdentity ? 1 : 0
        slot.pointee.store(UInt32(writeSlot), ordering: .releasing)
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
        coefficients.deinitialize(count: streamCount * bandCount * 2)
        coefficients.deallocate()
        equalizerBypass.deinitialize(count: streamCount * 2)
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
