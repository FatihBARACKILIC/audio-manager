import AVFoundation
import AudioDomain
import CoreAudio
import Foundation
import Synchronization

/// Drives Core Audio process taps: the real implementation of `AudioEngineControlling`.
///
/// Every app the user is controlling — muted or processed — is tapped, and all of those
/// taps feed one shared aggregate device and one IOProc. That is not an optimisation
/// but a requirement: a process tap silences its process only while something is
/// actually reading the tap, so a tap created and left alone changes nothing. Muting is
/// therefore "render this app as silence", and it costs one IOProc, not zero.
///
/// The difference between the two modes is what happens to the captured audio:
///
/// - **Mute only** — the stream is dropped before a single sample is touched.
/// - **Full control** — the stream runs through gain and the equalizer on the way out.
///
/// When no app needs either, the engine holds no Core Audio objects whatsoever. That
/// resting state is the point: an idle Audio Manager costs nothing.
///
/// Every Core Audio call runs on `queue`, never on the main thread — creating an IOProc
/// blocks until the system resolves the audio-capture permission, and blocking the main
/// thread there would freeze the UI with no way out.
public final class TapEngine: AudioEngineControlling, @unchecked Sendable {
    // @unchecked Sendable: all mutable state is touched only on `queue`, a serial
    // dispatch queue; the public API hops onto it before reading or writing anything.

    private struct TapHandle {
        var objectID: AudioObjectID
        var uuid: UUID
        /// Audio object ids of the processes the tap covers, to detect churn.
        var processObjectIDs: [UInt32]
    }

    private let queue = DispatchQueue(label: "com.barackilic.AudioManager.tap-engine", qos: .userInitiated)

    /// Taps feeding the shared render graph, one per controlled app.
    private var renderTaps: [AppKey: TapHandle] = [:]
    private var graph: RenderGraph?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: ListenerBox?
    private var lastAppliedStates: [AppKey: EffectiveAppState] = [:]
    private var lastApps: [AudioApp] = []

    private let statusContinuation: AsyncStream<EngineStatus>.Continuation
    public let statusUpdates: AsyncStream<EngineStatus>

    private final class ListenerBox: @unchecked Sendable {
        let block: AudioObjectPropertyListenerBlock

        init(_ block: @escaping AudioObjectPropertyListenerBlock) {
            self.block = block
        }
    }

    public init() {
        var escaped: AsyncStream<EngineStatus>.Continuation!
        statusUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { escaped = $0 }
        statusContinuation = escaped
    }

    deinit {
        statusContinuation.finish()
    }

    // MARK: - Permission

    public func permissionStatus() async -> AudioPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    @discardableResult
    public func requestPermission() async -> AudioPermissionStatus {
        if case .granted = await permissionStatus() {
            return .granted
        }
        await AVCaptureDevice.requestAccess(for: .audio)
        return await permissionStatus()
    }

    // MARK: - Applying state

    public func apply(states: [EffectiveAppState], for apps: [AudioApp]) async throws {
        // Without permission the system blocks inside Core Audio rather than returning
        // an error, so refuse up front and let the UI ask for access instead.
        let permission = await permissionStatus()
        let needsWork = states.contains { !$0.isPassthrough }
        if permission != .granted, needsWork {
            statusContinuation.yield(.degraded(.permissionDenied))
            throw EngineError.permissionRequired
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try applyOnQueue(states: states, apps: apps)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateParameters(states: [EffectiveAppState]) {
        queue.async { [self] in
            guard let graph else { return }
            for state in states {
                guard let index = graph.streamIndices[state.key] else { continue }
                graph.update(
                    streamIndex: index,
                    gain: state.isMuted ? 0 : state.gain,
                    equalizer: state.isMuted ? .flat : state.equalizer
                )
                // Keep the remembered state in step, so rebuilding after a device
                // change does not resurrect the value the slider started from.
                lastAppliedStates[state.key] = state
            }
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                tearDownEverything()
                continuation.resume()
            }
        }
    }

    /// Peak levels for the panel's meters, empty while nothing is rendering.
    public func peakLevels() async -> [AppKey: Float] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[AppKey: Float], Never>) in
            queue.async { [self] in
                guard let graph else {
                    continuation.resume(returning: [:])
                    return
                }
                var levels: [AppKey: Float] = [:]
                for (index, key) in graph.streamKeys.enumerated() {
                    levels[key] = graph.peak(atStreamIndex: index)
                }
                continuation.resume(returning: levels)
            }
        }
    }

    // MARK: - Queue-confined work

    private func applyOnQueue(states: [EffectiveAppState], apps: [AudioApp]) throws {
        lastApps = apps
        // Non-trapping on purpose: grouping gives one entry per app today, but a
        // duplicate key must degrade to "the first one wins", never to a crash that
        // takes the user's audio with it.
        lastAppliedStates = Dictionary(states.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        let processIDs = Dictionary(
            apps.map { ($0.key, $0.audioObjectIDs) },
            uniquingKeysWith: { first, _ in first }
        )
        // Muted and processed apps share one path: both need their tap to be read for
        // the source to stay silent.
        let controlled = states.filter { !$0.isPassthrough }

        try syncRenderGraph(states: controlled, keys: controlled.map(\.key), processIDs: processIDs)

        statusContinuation.yield(graph == nil ? .idle : .running)
    }

    private func syncRenderGraph(
        states: [EffectiveAppState],
        keys: [AppKey],
        processIDs: [AppKey: [UInt32]]
    ) throws {
        guard !keys.isEmpty else {
            tearDownRenderGraph()
            return
        }

        let currentKeys = graph?.streamKeys ?? []
        let processesChanged = keys.contains { key in
            renderTaps[key]?.processObjectIDs != (processIDs[key] ?? [])
        }

        if currentKeys != keys || processesChanged {
            tearDownRenderGraph()
            try buildRenderGraph(states: states, keys: keys, processIDs: processIDs)
        }

        // Cheap path: the graph already covers these apps, so only push new numbers.
        guard let graph else { return }
        for state in states {
            guard let index = graph.streamIndices[state.key] else { continue }
            // Muting is gain zero, ramped like any other change so it does not click.
            graph.update(
                streamIndex: index,
                gain: state.isMuted ? 0 : state.gain,
                equalizer: state.isMuted ? .flat : state.equalizer
            )
        }
    }

    private func buildRenderGraph(
        states: [EffectiveAppState],
        keys: [AppKey],
        processIDs: [AppKey: [UInt32]]
    ) throws {
        var handles: [TapHandle] = []
        var usableKeys: [AppKey] = []

        for key in keys {
            guard let objectIDs = processIDs[key], !objectIDs.isEmpty else { continue }
            do {
                let handle = try createTap(processObjectIDs: objectIDs, name: "Control \(key.rawValue)")
                handles.append(handle)
                usableKeys.append(key)
                renderTaps[key] = handle
            } catch {
                statusContinuation.yield(.degraded(.tapCreationFailed))
            }
        }

        guard !handles.isEmpty else { return }

        let output: (deviceID: AudioObjectID, uid: String, sampleRate: Double)
        do {
            output = try defaultOutputDevice()
        } catch {
            handles.forEach(destroyTap)
            renderTaps.removeAll()
            statusContinuation.yield(.degraded(.deviceUnavailable))
            throw error
        }

        do {
            aggregateDeviceID = try createAggregateDevice(outputUID: output.uid, taps: handles)
            let newGraph = RenderGraph(streamKeys: usableKeys, sampleRate: output.sampleRate)
            // Set every stream before the first buffer is rendered, or a muted app is
            // briefly audible while its gain ramps down from the default of one.
            for state in states {
                guard let index = usableKeys.firstIndex(of: state.key) else { continue }
                newGraph.update(
                    streamIndex: index,
                    gain: state.isMuted ? 0 : state.gain,
                    equalizer: state.isMuted ? .flat : state.equalizer,
                    ramped: false
                )
            }
            try newGraph.start(aggregateDeviceID: aggregateDeviceID)
            graph = newGraph
            installDefaultDeviceListener()
        } catch {
            tearDownRenderGraph()
            statusContinuation.yield(.degraded(.deviceUnavailable))
            throw error
        }
    }

    // MARK: - Core Audio objects

    /// Creates a tap over every process of one app.
    ///
    /// Always `.mutedWhenTapped`: the app is silenced exactly while our IOProc is
    /// reading it, which is both what makes muting work at all and the safety net we
    /// want — if the graph ever stops, the user's audio comes back by itself instead of
    /// going missing. `.muted` sounds like the better fit for "mute this app", but a tap
    /// nobody reads does not silence anything, so it would be a mute that never happens.
    private func createTap(processObjectIDs: [UInt32], name: String) throws -> TapHandle {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = name
        description.uuid = UUID()
        // Private so the tap never shows up as a capture device for other apps.
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "AudioHardwareCreateProcessTap"
        )
        guard tapID != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "tap id was unknown")
        }

        return TapHandle(objectID: tapID, uuid: description.uuid, processObjectIDs: processObjectIDs)
    }

    private func destroyTap(_ handle: TapHandle) {
        // Nothing useful to do on failure; the object is gone either way and audio must
        // keep working.
        AudioHardwareDestroyProcessTap(handle.objectID)
    }

    private func defaultOutputDevice() throws -> (deviceID: AudioObjectID, uid: String, sampleRate: Double) {
        let deviceID = try AudioObjectProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObjectProperty.address(AudioSelectors.defaultOutputDevice),
            of: AudioObjectID.self
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "default output device")
        }
        guard
            let uid = AudioObjectProperty.string(deviceID, AudioObjectProperty.address(AudioSelectors.deviceUID))
        else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "default output device UID")
        }
        let sampleRate = AudioObjectProperty.optionalValue(
            deviceID,
            AudioObjectProperty.address(AudioSelectors.deviceNominalSampleRate),
            of: Float64.self
        ) ?? 48000

        return (deviceID, uid, sampleRate)
    }

    private func createAggregateDevice(outputUID: String, taps: [TapHandle]) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Manager",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private: the device belongs to this process and never appears in Sound
            // settings or in other apps' device pickers.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            },
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "aggregate id was unknown")
        }
        return deviceID
    }

    /// Rebuilds the graph when the user switches output device (headphones in or out).
    private func installDefaultDeviceListener() {
        guard deviceListener == nil else { return }

        let listener = ListenerBox { [weak self] _, _ in
            guard let self else { return }
            queue.async {
                let states = Array(self.lastAppliedStates.values)
                let apps = self.lastApps
                self.tearDownRenderGraph()
                try? self.applyOnQueue(states: states, apps: apps)
            }
        }
        deviceListener = listener

        var address = AudioObjectProperty.address(AudioSelectors.defaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
        if status != noErr {
            deviceListener = nil
        }
    }

    private func removeDefaultDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectProperty.address(AudioSelectors.defaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            deviceListener.block
        )
        self.deviceListener = nil
    }

    // MARK: - Teardown

    private func tearDownRenderGraph() {
        graph?.tearDown()
        graph = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        for handle in renderTaps.values {
            destroyTap(handle)
        }
        renderTaps.removeAll()
    }

    private func tearDownEverything() {
        removeDefaultDeviceListener()
        tearDownRenderGraph()
        statusContinuation.yield(.idle)
    }
}

public enum EngineError: Error, Equatable, Sendable {
    case permissionRequired
}
