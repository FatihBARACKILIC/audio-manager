import AudioDomain
import CoreAudio
import Foundation
import Synchronization

/// Watches the system's audio processes and publishes them as they change.
///
/// Entirely event-driven: Core Audio calls us when the process list changes and when a
/// process starts or stops producing output. There is no timer and no polling, so an
/// idle Audio Manager produces no wake-ups at all.
public final class AudioProcessObserver: AudioProcessObserving, @unchecked Sendable {
    // @unchecked Sendable: all mutable state lives behind `state`, a Mutex; the Core
    // Audio listener blocks run on `queue` and touch nothing else.

    private struct State {
        var snapshots: [AudioProcessSnapshot] = []
        /// Audio objects we currently hold a per-process listener on.
        var observedProcesses: Set<AudioObjectID> = []
        var isStarted = false
        /// Bumped by every request to re-read; a scheduled read that is no longer the
        /// newest request drops itself instead of doing the work twice.
        var refreshGeneration = 0
    }

    /// How long a burst of notifications is allowed to gather before we re-read.
    ///
    /// Core Audio tells us about the process list and about each process starting or
    /// stopping output, and those arrive together: opening three browser tabs fires a
    /// handful of callbacks inside a few milliseconds, and each one would otherwise
    /// cost a full workspace snapshot plus a path lookup per audio process. Waiting a
    /// moment turns that burst into one read. This is not a timer — nothing is
    /// scheduled unless the system just told us something changed — so an idle app
    /// still wakes up zero times.
    private static let coalescingInterval = DispatchTimeInterval.milliseconds(120)

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.barackilic.AudioManager.process-observer", qos: .utility)
    private let continuation: AsyncStream<[AudioProcessSnapshot]>.Continuation

    public let processUpdates: AsyncStream<[AudioProcessSnapshot]>

    /// Core Audio removes a listener by matching the exact block, so every block we add
    /// has to be kept. The block itself is not `Sendable`, hence the box: it captures
    /// only `self` and is ever only invoked on `queue`.
    private final class ListenerBox: @unchecked Sendable {
        let block: AudioObjectPropertyListenerBlock

        init(_ block: @escaping AudioObjectPropertyListenerBlock) {
            self.block = block
        }
    }

    private let listListener = Mutex<ListenerBox?>(nil)
    private let runningListeners = Mutex<[AudioObjectID: ListenerBox]>([:])

    public init() {
        var escapedContinuation: AsyncStream<[AudioProcessSnapshot]>.Continuation!
        processUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            escapedContinuation = continuation
        }
        continuation = escapedContinuation
    }

    deinit {
        stop()
        continuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts listening. Safe to call more than once.
    public func start() {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.isStarted else { return false }
            state.isStarted = true
            return true
        }
        guard shouldStart else { return }

        let listener = ListenerBox { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        listListener.withLock { $0 = listener }

        var address = AudioObjectProperty.address(AudioSelectors.processList)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener.block
        )
        if status != noErr {
            // Without the listener we would silently stop noticing new apps, which is
            // worse than showing a stale list: mark ourselves unstarted so a later
            // start() can try again.
            state.withLock { $0.isStarted = false }
            return
        }

        refresh()
    }

    /// Removes every listener. Safe to call when not started.
    public func stop() {
        let wasStarted = state.withLock { state -> Bool in
            defer {
                state.isStarted = false
                // Outdates any read already queued, so a listener that fired just
                // before we stopped cannot re-add listeners behind our back.
                state.refreshGeneration += 1
            }
            return state.isStarted
        }
        guard wasStarted else { return }

        if let listener = listListener.withLock({ box -> ListenerBox? in
            let previous = box
            box = nil
            return previous
        }) {
            var address = AudioObjectProperty.address(AudioSelectors.processList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener.block
            )
        }

        let listeners = runningListeners.withLock { boxes -> [AudioObjectID: ListenerBox] in
            let previous = boxes
            boxes = [:]
            return previous
        }
        var runningAddress = AudioObjectProperty.address(AudioSelectors.processIsRunningOutput)
        for (objectID, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, queue, listener.block)
        }

        state.withLock { $0.observedProcesses = [] }
    }

    // MARK: - AudioProcessObserving

    public func currentProcesses() async -> [AudioProcessSnapshot] {
        let cached = state.withLock { $0.snapshots }
        if !cached.isEmpty {
            return cached
        }
        return readProcesses()
    }

    // MARK: - Reading

    /// Asks for a re-read, collapsing a burst of notifications into one.
    private func scheduleRefresh() {
        let generation = state.withLock { state -> Int in
            state.refreshGeneration += 1
            return state.refreshGeneration
        }

        queue.asyncAfter(deadline: .now() + AudioProcessObserver.coalescingInterval) { [weak self] in
            guard let self else { return }
            let isNewest = state.withLock { $0.refreshGeneration == generation && $0.isStarted }
            guard isNewest else { return }
            refresh()
        }
    }

    /// Re-reads the process list, re-syncs per-process listeners and publishes.
    private func refresh() {
        let snapshots = readProcesses()
        let changed = state.withLock { state -> Bool in
            guard state.snapshots != snapshots else { return false }
            state.snapshots = snapshots
            return true
        }
        syncRunningListeners(for: snapshots)
        if changed {
            continuation.yield(snapshots)
        }
    }

    private func readProcesses() -> [AudioProcessSnapshot] {
        // One workspace snapshot per refresh, shared by every process below.
        let index = RunningAppIndex()
        let address = AudioObjectProperty.address(AudioSelectors.processList)
        guard let objectIDs = try? AudioObjectProperty.objectIDs(AudioObjectID(kAudioObjectSystemObject), address) else {
            return []
        }

        return objectIDs.compactMap { objectID in
            guard
                let pid = AudioObjectProperty.optionalValue(
                    objectID,
                    AudioObjectProperty.address(AudioSelectors.processPID),
                    of: pid_t.self
                )
            else { return nil }

            let bundleIdentifier = AudioObjectProperty.string(
                objectID,
                AudioObjectProperty.address(AudioSelectors.processBundleID)
            )
            let isRunningOutput = (AudioObjectProperty.optionalValue(
                objectID,
                AudioObjectProperty.address(AudioSelectors.processIsRunningOutput),
                of: UInt32.self
            ) ?? 0) != 0

            let identity = ProcessIdentity.describe(
                processID: pid,
                coreAudioBundleIdentifier: bundleIdentifier,
                index: index
            )

            return AudioProcessSnapshot(
                audioObjectID: objectID,
                processID: pid,
                bundleIdentifier: bundleIdentifier,
                containerBundlePath: identity.bundlePath,
                containerBundleIdentifier: identity.bundleIdentifier,
                displayName: identity.displayName,
                isRunningOutput: isRunningOutput,
                isRegularApp: identity.isRegularApp
            )
        }
    }

    /// Adds listeners for processes that appeared and removes them for processes that
    /// went away, so the number of live listeners tracks the number of processes.
    private func syncRunningListeners(for snapshots: [AudioProcessSnapshot]) {
        let current = Set(snapshots.map { AudioObjectID($0.audioObjectID) })
        let previous = state.withLock { $0.observedProcesses }

        var address = AudioObjectProperty.address(AudioSelectors.processIsRunningOutput)

        for objectID in current.subtracting(previous) {
            let listener = ListenerBox { [weak self] _, _ in
                self?.scheduleRefresh()
            }
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener.block)
            if status == noErr {
                runningListeners.withLock { $0[objectID] = listener }
            }
        }

        for objectID in previous.subtracting(current) {
            if let listener = runningListeners.withLock({ $0.removeValue(forKey: objectID) }) {
                AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener.block)
            }
        }

        state.withLock { $0.observedProcesses = current }
    }
}
