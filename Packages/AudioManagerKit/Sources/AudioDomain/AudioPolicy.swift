import Foundation

/// What the audio engine should actually do for one app, after every layer of
/// configuration has been folded together.
public struct EffectiveAppState: Sendable, Equatable, Hashable {
    public var key: AppKey
    public var isMuted: Bool
    /// Final linear gain, limiter already applied. Meaningless while muted.
    public var gain: Double
    public var equalizer: EqualizerSettings
    public var mode: ControlMode
    /// Why this state is what it is — shown in the panel so the user understands why a
    /// slider is not doing anything.
    public var reason: Reason

    public enum Reason: String, Sendable, Hashable, Codable {
        case manual
        case focusMode
        case schedule
        case profile
    }

    public init(
        key: AppKey,
        isMuted: Bool,
        gain: Double,
        equalizer: EqualizerSettings,
        mode: ControlMode,
        reason: Reason = .manual
    ) {
        self.key = key
        self.isMuted = isMuted
        self.gain = gain
        self.equalizer = equalizer
        self.mode = mode
        self.reason = reason
    }

    /// The app must be silenced.
    ///
    /// A tap only silences its process while something is actually reading it, so this
    /// still goes through the shared render path — the app simply contributes silence
    /// instead of processed audio. Nothing of its signal is computed.
    public var needsSilencing: Bool {
        isMuted
    }

    /// The app's signal has to be altered on the way out.
    ///
    /// Deliberately narrow: an unmuted full-control app whose settings actually change
    /// something. An app sitting at 100% with a flat EQ is left completely alone.
    public var needsRendering: Bool {
        guard !isMuted, mode == .fullControl else { return false }
        return abs(gain - 1) > 0.0001 || !equalizer.isFlat
    }

    /// True when the engine can ignore this app entirely.
    public var isPassthrough: Bool {
        !needsSilencing && !needsRendering
    }
}

/// Folds manual settings, the active profile, focus mode, schedule rules and the
/// hearing-safety limit into one answer per app.
///
/// Everything here is pure so the whole policy surface is unit-tested without audio
/// hardware. Precedence, highest first: schedule > focus > profile > manual.
public struct AudioPolicy: Sendable, Equatable {
    public var manual: [AppKey: AppAudioSettings]
    public var defaults: AppAudioSettings
    public var activeProfile: AudioProfile?
    public var focus: FocusMode
    public var limit: OutputLimit
    /// Apps muted by an active schedule rule.
    public var scheduleMutedApps: Set<AppKey>
    /// Focus restriction imposed by an active schedule rule.
    public var scheduleFocus: FocusMode?

    public init(
        manual: [AppKey: AppAudioSettings] = [:],
        defaults: AppAudioSettings = .default,
        activeProfile: AudioProfile? = nil,
        focus: FocusMode = .off,
        limit: OutputLimit = OutputLimit(),
        scheduleMutedApps: Set<AppKey> = [],
        scheduleFocus: FocusMode? = nil
    ) {
        self.manual = manual
        self.defaults = defaults
        self.activeProfile = activeProfile
        self.focus = focus
        self.limit = limit
        self.scheduleMutedApps = scheduleMutedApps
        self.scheduleFocus = scheduleFocus
    }

    /// Settings in force for an app before schedule and focus override them.
    public func baseSettings(for key: AppKey) -> (settings: AppAudioSettings, reason: EffectiveAppState.Reason) {
        if let manualSettings = manual[key] {
            return (manualSettings, .manual)
        }
        if let profileSettings = activeProfile?.settings(for: key) {
            return (profileSettings, .profile)
        }
        return (defaults, .manual)
    }

    public func state(for key: AppKey) -> EffectiveAppState {
        let (settings, baseReason) = baseSettings(for: key)

        var isMuted = settings.isMuted
        var reason = baseReason

        // Focus restrictions are stronger than anything the user set per app: the whole
        // point of "only Zoom" is that a stale per-app setting cannot leak sound.
        let effectiveFocus = scheduleFocus ?? (focus.isActive ? focus : activeProfile?.focus ?? .off)
        if effectiveFocus.isActive, !effectiveFocus.allows(key) {
            isMuted = true
            reason = scheduleFocus != nil ? .schedule : .focusMode
        }

        if scheduleMutedApps.contains(key) {
            isMuted = true
            reason = .schedule
        }

        let rawGain = VolumeCurve.gain(forSlider: settings.volume)
            * VolumeCurve.linearGain(fromDecibels: settings.boostDecibels)

        return EffectiveAppState(
            key: key,
            isMuted: isMuted,
            gain: limit.apply(to: rawGain),
            equalizer: settings.equalizer,
            mode: settings.mode,
            reason: reason
        )
    }

    /// The per-app settings in force right now, in the shape a profile stores them.
    ///
    /// This is what "save what I am hearing" means, and it is deliberately built from
    /// `baseSettings` rather than from the manual overrides alone: those hold only the
    /// layer on top of the active profile, so saving them would silently drop whatever
    /// the profile itself decided.
    ///
    /// Schedule rules and focus mode are left out on purpose. They describe what is
    /// happening at this moment, not what the user wants the profile to mean — a
    /// profile saved at 10:00 on a weekday should not bake in the rule that happens to
    /// be running.
    ///
    /// Apps sitting exactly at their defaults are omitted, which is what keeps
    /// `unlistedApps` meaningful.
    public func settingsSnapshot(for keys: some Sequence<AppKey>) -> [AppKey: AppAudioSettings] {
        var snapshot: [AppKey: AppAudioSettings] = [:]
        for key in keys {
            let settings = baseSettings(for: key).settings
            guard settings != defaults else { continue }
            snapshot[key] = settings
        }
        return snapshot
    }

    public func states(for apps: [AudioApp]) -> [AppKey: EffectiveAppState] {
        var result: [AppKey: EffectiveAppState] = [:]
        result.reserveCapacity(apps.count)
        for app in apps {
            result[app.key] = state(for: app.key)
        }
        return result
    }

    /// Apps the engine must act on. Everything else costs nothing at runtime, which is
    /// what keeps the app at zero CPU when the user is not changing anything.
    public func activeStates(for apps: [AudioApp]) -> [EffectiveAppState] {
        apps.map { state(for: $0.key) }.filter { !$0.isPassthrough }
    }
}
