import AudioDomain
import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import AudioCore

/// Exercises the real-time render function directly with hand-built buffer lists.
///
/// This is the code that runs on the audio thread, so it is worth testing without any
/// hardware: mixing, gain ramping, equalizer bypass and the safety clip are all pure
/// functions of the buffers handed in.
@Suite("Render graph")
struct RenderGraphTests {

    /// Owns the unmanaged memory a `RenderContext` points at for the duration of a test.
    private final class Fixture {
        let streamCount: Int
        let bandCount = EqualizerSettings.bandCount
        let channelsPerStream = 2

        let coefficients: UnsafeMutablePointer<BiquadCoefficients>
        let bypass: UnsafeMutablePointer<UInt8>
        let states: UnsafeMutablePointer<BiquadState>
        let currentGains: UnsafeMutablePointer<Float>
        let targetGains: UnsafeMutablePointer<Float>
        let slot: UnsafeMutablePointer<Atomic<UInt32>>
        let peaks: UnsafeMutablePointer<Float>
        let context: UnsafeMutablePointer<RenderContext>

        /// Mirrors the graph's publish ring, so the fixture indexes exactly as the
        /// render function does.
        let slotCount = RenderGraph.coefficientSlotCount

        init(streamCount: Int) {
            self.streamCount = streamCount

            coefficients = .allocate(capacity: streamCount * bandCount * slotCount)
            coefficients.initialize(repeating: .identity, count: streamCount * bandCount * slotCount)
            bypass = .allocate(capacity: streamCount * slotCount)
            bypass.initialize(repeating: 1, count: streamCount * slotCount)
            states = .allocate(capacity: streamCount * channelsPerStream * bandCount)
            states.initialize(repeating: BiquadState(), count: streamCount * channelsPerStream * bandCount)
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
                    streamCount: Int32(streamCount),
                    bandCount: Int32(bandCount),
                    channelsPerStream: Int32(channelsPerStream),
                    coefficients: coefficients,
                    equalizerBypass: bypass,
                    states: states,
                    currentGains: currentGains,
                    targetGains: targetGains,
                    slot: slot,
                    peaks: peaks
                )
            )
        }

        deinit {
            coefficients.deallocate()
            bypass.deallocate()
            states.deallocate()
            currentGains.deallocate()
            targetGains.deallocate()
            peaks.deallocate()
            slot.deinitialize(count: 1)
            slot.deallocate()
            context.deallocate()
        }

        func setGain(_ gain: Float, stream: Int, ramp: Bool = false) {
            targetGains[stream] = gain
            if !ramp { currentGains[stream] = gain }
        }
    }

    /// Builds an `AudioBufferList` over caller-owned storage.
    private func bufferList(
        from storage: inout [[Float]],
        channels: Int
    ) -> (list: UnsafeMutableAudioBufferListPointer, release: () -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: storage.count)
        for index in storage.indices {
            storage[index].withUnsafeMutableBufferPointer { buffer in
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            }
        }
        return (list, { free(list.unsafeMutablePointer) })
    }

    @Test("A single stream at unity gain is copied through unchanged")
    func passesThroughAtUnity() {
        let fixture = Fixture(streamCount: 1)
        let frames = 8

        var inputStorage: [[Float]] = [Array(repeating: 0.25, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 99, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { abs($0 - 0.25) < 0.0001 })
    }

    @Test("Two streams are summed into one output")
    func mixesStreams() {
        let fixture = Fixture(streamCount: 2)
        let frames = 4

        var inputStorage: [[Float]] = [
            Array(repeating: 0.2, count: frames * 2),
            Array(repeating: 0.3, count: frames * 2),
        ]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("Gain is applied per stream")
    func appliesGain() {
        let fixture = Fixture(streamCount: 1)
        fixture.setGain(0.5, stream: 0)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 1, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("A gain change ramps within the buffer and lands on the target")
    func rampsGain() {
        let fixture = Fixture(streamCount: 1)
        fixture.currentGains[0] = 1
        fixture.targetGains[0] = 0
        let frames = 16

        var inputStorage: [[Float]] = [Array(repeating: 1, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result[0] == 1)
        #expect(result[result.count - 1] < 0.1)
        #expect(fixture.currentGains[0] == 0)
    }

    @Test("Muted streams contribute nothing")
    func zeroGainIsSilent() {
        let fixture = Fixture(streamCount: 1)
        fixture.setGain(0, stream: 0)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 1, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { $0 == 0 })
    }

    @Test("Stale output contents are cleared before mixing")
    func clearsOutputFirst() {
        let fixture = Fixture(streamCount: 1)
        fixture.setGain(0, stream: 0)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0.7, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { $0 == 0 })
    }

    @Test("A loud sum is clipped instead of wrapping or exploding")
    func clipsSafely() {
        let fixture = Fixture(streamCount: 3)
        let frames = 4

        var inputStorage: [[Float]] = Array(repeating: Array(repeating: 0.9, count: frames * 2), count: 3)
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { $0 == 1 })
    }

    @Test("Peak levels are reported per stream")
    func reportsPeaks() {
        let fixture = Fixture(streamCount: 2)
        let frames = 8

        var inputStorage: [[Float]] = [
            Array(repeating: 0.4, count: frames * 2),
            Array(repeating: 0.1, count: frames * 2),
        ]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        #expect(abs(fixture.peaks[0] - 0.4) < 0.0001)
        #expect(abs(fixture.peaks[1] - 0.1) < 0.0001)
    }

    @Test("An empty buffer is a no-op rather than a crash")
    func handlesZeroFrames() {
        let fixture = Fixture(streamCount: 1)

        var inputStorage: [[Float]] = [Array(repeating: 1, count: 8)]
        var outputStorage: [[Float]] = [Array(repeating: 0.5, count: 8)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: 0
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: 8
        ))
        #expect(result.allSatisfy { $0 == 0.5 })
    }

    @Test("A zero-channel output buffer is refused rather than indexed backwards")
    func rejectsZeroChannelOutput() {
        let fixture = Fixture(streamCount: 1)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 0.5, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0.25, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 0)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        // Nothing was written at all, rather than at a negative offset.
        #expect(outputStorage[0].allSatisfy { $0 == 0.25 })
    }

    @Test("A mono tap is folded into a stereo output")
    func foldsMismatchedChannelCounts() {
        let fixture = Fixture(streamCount: 1)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 0.5, count: frames)]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 1)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        // Every frame's left channel carries the mono signal, the right stays silent.
        for frame in 0..<frames {
            #expect(abs(result[frame * 2] - 0.5) < 0.0001)
            #expect(result[frame * 2 + 1] == 0)
        }
    }

    @Test("Fewer input buffers than streams is handled without reading past the end")
    func toleratesMissingStreams() {
        let fixture = Fixture(streamCount: 4)
        let frames = 4

        var inputStorage: [[Float]] = [Array(repeating: 0.5, count: frames * 2)]
        var outputStorage: [[Float]] = [Array(repeating: 0, count: frames * 2)]
        let input = bufferList(from: &inputStorage, channels: 2)
        let output = bufferList(from: &outputStorage, channels: 2)
        defer { input.release(); output.release() }

        renderTappedAudio(
            context: fixture.context,
            input: UnsafePointer(input.list.unsafeMutablePointer),
            output: output.list.unsafeMutablePointer,
            frameCount: frames
        )

        let result = Array(UnsafeBufferPointer(
            start: output.list[0].mData!.assumingMemoryBound(to: Float.self),
            count: frames * 2
        ))
        #expect(result.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }
}

/// The control-thread half of the graph: what it publishes, and — just as important —
/// what it declines to publish, because every publish is a window in which the audio
/// thread could be reading the slot being written.
@Suite("Render graph publishing")
struct RenderGraphPublishingTests {

    @Test("Changing only the gain publishes no coefficients at all")
    func gainChangeDoesNotRepublish() {
        let graph = RenderGraph(streamKeys: [.bundle("a"), .bundle("b")], sampleRate: 48000)
        let equalizer = EqualizerSettings(isEnabled: true, gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0])

        graph.update(streamIndex: 0, gain: 1, equalizer: equalizer)
        let afterEqualizer = graph.publishedSlotForTesting

        // A slider drag: many gain changes, same equalizer.
        for step in 0..<20 {
            graph.update(streamIndex: 0, gain: Double(step) / 20, equalizer: equalizer)
        }

        #expect(graph.publishedSlotForTesting == afterEqualizer)
    }

    @Test("Each equalizer change lands in a different slot than the last")
    func equalizerChangesRotateTheRing() {
        let graph = RenderGraph(streamKeys: [.bundle("a")], sampleRate: 48000)
        var seen: [UInt32] = []

        for decibels in stride(from: 1.0, through: 6.0, by: 1.0) {
            var equalizer = EqualizerSettings(isEnabled: true)
            equalizer.setGain(decibels, at: 4)
            graph.update(streamIndex: 0, gain: 1, equalizer: equalizer)
            seen.append(graph.publishedSlotForTesting)
        }

        #expect(seen.count == 6)
        for (previous, next) in zip(seen, seen.dropFirst()) {
            #expect(previous != next)
        }
        #expect(seen.allSatisfy { $0 < UInt32(RenderGraph.coefficientSlotCount) })
    }

    @Test("Publishing one stream leaves the other streams' coefficients intact")
    func publishingOneStreamKeepsTheOthers() {
        let graph = RenderGraph(streamKeys: [.bundle("a"), .bundle("b")], sampleRate: 48000)

        var first = EqualizerSettings(isEnabled: true)
        first.setGain(9, at: 0)
        graph.update(streamIndex: 0, gain: 1, equalizer: first)

        var second = EqualizerSettings(isEnabled: true)
        second.setGain(-9, at: 9)
        graph.update(streamIndex: 1, gain: 1, equalizer: second)

        // Both streams must be non-bypassed in the slot that is live now.
        #expect(graph.bypassForTesting(streamIndex: 0) == 0)
        #expect(graph.bypassForTesting(streamIndex: 1) == 0)
    }

    @Test("A stream index outside the graph is ignored")
    func ignoresOutOfRangeStreams() {
        let graph = RenderGraph(streamKeys: [.bundle("a")], sampleRate: 48000)
        graph.update(streamIndex: 5, gain: 0.5, equalizer: .flat)
        graph.update(streamIndex: -1, gain: 0.5, equalizer: .flat)
        #expect(graph.peak(atStreamIndex: 5) == 0)
    }
}
