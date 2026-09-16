import Foundation

/// TCC state for capturing other apps' audio. Without this permission no per-app
/// control is possible at all, so the UI treats it as a first-class state rather than
/// an error case.
public enum AudioPermissionStatus: String, Sendable, Hashable, Codable {
    case notDetermined
    case denied
    case granted
}

/// What the engine is doing right now.
public enum EngineStatus: Sendable, Hashable {
    /// Nothing is tapped and nothing is running — the resting state, and the one the
    /// app must return to whenever no app needs control.
    case idle
    /// At least one tap is active.
    case running
    /// Something went wrong (device disappeared, tap refused, protected content).
    /// Audio keeps playing normally; we simply stopped interfering.
    case degraded(EngineFailure)
}

/// Why the engine gave up on an app or on the whole graph.
public enum EngineFailure: String, Sendable, Hashable, Codable {
    case permissionDenied
    case tapCreationFailed
    case deviceUnavailable
    case protectedContent
    case formatUnsupported
}

/// The boundary between the app and Core Audio.
///
/// The UI and all policy logic depend on this protocol, never on the Core Audio
/// implementation, which is what allows the entire domain to be tested with a fake
/// engine and no hardware.
public protocol AudioEngineControlling: Sendable {
    /// Current permission state, cheap to read.
    func permissionStatus() async -> AudioPermissionStatus

    /// Triggers the system permission prompt. Returns the resulting status.
    @discardableResult
    func requestPermission() async -> AudioPermissionStatus

    /// Applies the desired state for every app that needs anything.
    ///
    /// Implementations must treat this as the complete set: apps missing from
    /// `states` are released, and when `states` is empty the engine tears everything
    /// down and returns to `.idle`.
    func apply(states: [EffectiveAppState], for apps: [AudioApp]) async throws

    /// Pushes new gains and equalizer settings for apps the engine is already running.
    ///
    /// The live path for a slider drag. It never creates or destroys a tap, a device or
    /// an IOProc, so it is cheap enough to call on every frame of a drag, and apps it
    /// does not already know about are ignored — `apply(states:for:)` is what changes
    /// the shape of the graph. Values arrive ramped, not stepped, so dragging a slider
    /// cannot produce zipper noise.
    ///
    /// Deliberately not `async`: a drag must arrive in the order the user made it, and
    /// spawning a task per change gives up that ordering, so a stale value could land
    /// last and stick. Implementations hand the values straight to their own serial
    /// queue and return.
    func updateParameters(states: [EffectiveAppState])

    /// Peak level per app since the last read, for the panel's meters.
    ///
    /// Polled by the UI at a low rate only while the panel is on screen, never pushed
    /// from the render thread. Empty while nothing is rendering, which is also the
    /// answer an implementation without metering gives.
    func peakLevels() async -> [AppKey: Float]

    /// Releases every tap and device. Safe to call repeatedly.
    func shutdown() async

    /// Engine status changes, for the UI's health indicator.
    var statusUpdates: AsyncStream<EngineStatus> { get }
}

extension AudioEngineControlling {
    /// An engine with nothing to meter reports nothing, so a fake does not have to.
    public func peakLevels() async -> [AppKey: Float] { [:] }
}

/// Publishes the set of audio processes as the system reports it.
///
/// Implementations are event-driven (Core Audio property listeners), never polling,
/// so an idle app produces no wake-ups.
public protocol AudioProcessObserving: Sendable {
    /// Current snapshot, for the first paint of the panel.
    func currentProcesses() async -> [AudioProcessSnapshot]

    /// Updates pushed whenever the process list or a process's playing state changes.
    var processUpdates: AsyncStream<[AudioProcessSnapshot]> { get }
}
