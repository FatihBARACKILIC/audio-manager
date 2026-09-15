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

    /// A tap is needed to silence the source, but nothing is re-rendered.
    public var needsMuteOnlyTap: Bool {
        isMuted
    }

    /// The full capture → process → play path is needed.
    ///
    /// This is the expensive case, so it is deliberately narrow: an unmuted
    /// full-control app whose settings actually change the signal. An app sitting at
    /// 100% with a flat EQ is left completely alone.
    public var needsRendering: Bool {
        guard !isMuted, mode == .fullControl else { return false }
        return abs(gain - 1) > 0.0001 || !equalizer.isFlat
    }

    /// True when the engine can ignore this app entirely.
    public var isPassthrough: Bool {
        !needsMuteOnlyTap && !needsRendering
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
