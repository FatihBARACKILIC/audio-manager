import AudioCore
import AudioDomain
import AudioPersistence
import Foundation
import Observation

/// The app's single source of truth: it owns persisted settings, the live app list and
/// the audio engine, and keeps the three in agreement.
///
/// Everything here is main-actor isolated because it feeds SwiftUI directly. The
/// expensive work it triggers is not: Core Audio lives behind `AudioEngineControlling`
/// on its own queue, and persistence behind an actor.
@Observable
@MainActor
final class AppModel {

    // MARK: - Published state

    private(set) var apps: [AudioApp] = []
    private(set) var permission: AudioPermissionStatus = .notDetermined
    private(set) var engineStatus: EngineStatus = .idle
    private(set) var levels: [AppKey: Float] = [:]
    /// Set when the stored settings could not be read, so the UI can say so once.
    private(set) var loadWarning: String?

    var appSettings: [AppKey: AppAudioSettings] = [:]
    var profiles: [AudioProfile] = []
    var activeProfileID: UUID?
    var scheduleRules: [ScheduleRule] = []
    var focus: FocusMode = .off
    var outputLimit = OutputLimit()
    var preferences = Preferences()

    /// Apps muted right now because of a schedule rule.
    private(set) var scheduleMutedApps: Set<AppKey> = []
    private(set) var scheduleFocus: FocusMode?
    private(set) var activeScheduleRuleNames: [String] = []

    /// True while the panel is on screen. Metering only runs in that window.
    var isPanelVisible = false {
        didSet { panelVisibilityChanged() }
    }

    // MARK: - Collaborators

    private let engine: any AudioEngineControlling
    private let observer: AudioProcessObserver
    private let store: SettingsStore
    private let calendar: Calendar
    private let notifications = NotificationService()

    /// What the engine was last told, so automatic changes can be announced.
    private var lastStates: [AppKey: EffectiveAppState] = [:]

    /// Set by diagnostics runs. Nothing is written to disk while it is on, so a
    /// throwaway test configuration can never end up in the user's real settings.
    private var isPersistenceSuspended = false

    /// Our own bundle identifier, so the panel never offers to mute Audio Manager.
    private let ownBundleIdentifier: Set<String>

    private var observationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(
        engine: any AudioEngineControlling = TapEngine(),
        observer: AudioProcessObserver = AudioProcessObserver(),
        store: SettingsStore,
        calendar: Calendar = .current
    ) {
        self.engine = engine
        self.observer = observer
        self.store = store
        self.calendar = calendar
        self.ownBundleIdentifier = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    /// Convenience initialiser using the app's real Application Support directory.
    static func makeDefault() -> AppModel {
        let identifier = Bundle.main.bundleIdentifier ?? "com.barackilic.AudioManager"
        let directory = (try? SettingsStore.defaultDirectory(bundleIdentifier: identifier))
            ?? URL.applicationSupportDirectory.appendingPathComponent(identifier, isDirectory: true)
        return AppModel(store: SettingsStore(directory: directory))
    }

    // MARK: - Lifecycle

    func start() async {
        await loadSettings()
        permission = await engine.permissionStatus()

        observer.start()
        apps = AppGrouping.group(await observer.currentProcesses(), excluding: ownBundleIdentifier)

        observationTask = Task { [weak self] in
            guard let self else { return }
            for await processes in observer.processUpdates {
                self.processesChanged(processes)
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            for await status in engine.statusUpdates {
                await MainActor.run { self.engineStatus = status }
            }
        }

        recomputeSchedule()
        scheduleNextScheduleWakeUp()
        applySoon()

        await notifications.prepare(enabled: preferences.showNotifications)
    }

    func stop() async {
        observationTask?.cancel()
        statusTask?.cancel()
        scheduleTask?.cancel()
        meterTask?.cancel()
        applyTask?.cancel()
        saveTask?.cancel()
        observer.stop()
        await engine.shutdown()
        await persist()
    }

    // MARK: - Permission

    func requestPermission() async {
        permission = await engine.requestPermission()
        if permission == .granted {
            applySoon()
        }
    }

    // MARK: - Reading state

    var policy: AudioPolicy {
        AudioPolicy(
            manual: appSettings,
            defaults: .default,
            activeProfile: activeProfile,
            focus: focus,
            limit: outputLimit,
            scheduleMutedApps: scheduleMutedApps,
            scheduleFocus: scheduleFocus
        )
    }

    var activeProfile: AudioProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    func settings(for key: AppKey) -> AppAudioSettings {
        appSettings[key] ?? activeProfile?.settings(for: key) ?? .default
    }

    func state(for key: AppKey) -> EffectiveAppState {
        policy.state(for: key)
    }

    /// True when at least one app is muted or processed right now.
    var isControllingAnything: Bool {
        !policy.activeStates(for: apps).isEmpty
    }

    // MARK: - Editing

    func setVolume(_ volume: Double, for key: AppKey) {
        var settings = settings(for: key)
        settings.setVolume(volume)
        // Touching the volume implies wanting it to take effect, which needs the
        // rendering path; staying in mute-only would silently do nothing.
        if volume < 1, settings.mode == .muteOnly {
            settings.mode = .fullControl
        }
        update(settings, for: key)
    }

    func setMuted(_ isMuted: Bool, for key: AppKey) {
        var settings = settings(for: key)
        settings.isMuted = isMuted
        update(settings, for: key)
    }

    func toggleMute(for key: AppKey) {
        setMuted(!state(for: key).isMuted, for: key)
    }

    func setMode(_ mode: ControlMode, for key: AppKey) {
        var settings = settings(for: key)
        settings.mode = mode
        update(settings, for: key)
    }

    func setBoost(decibels: Double, for key: AppKey) {
        var settings = settings(for: key)
        settings.setBoost(decibels: decibels)
        if decibels > 0 { settings.mode = .fullControl }
        update(settings, for: key)
    }

    func setEqualizer(_ equalizer: EqualizerSettings, for key: AppKey) {
        var settings = settings(for: key)
        settings.equalizer = equalizer
        if !equalizer.isFlat { settings.mode = .fullControl }
        update(settings, for: key)
    }

    func resetSettings(for key: AppKey) {
        appSettings.removeValue(forKey: key)
        applySoon()
        saveSoon()
    }

    private func update(_ settings: AppAudioSettings, for key: AppKey) {
        appSettings[key] = settings
        applySoon()
        saveSoon()
    }

    // MARK: - Focus and profiles

    func toggleFocusMode() {
        focus.isActive.toggle()
        applySoon()
        saveSoon()
    }

    func toggleFocusMembership(for key: AppKey) {
        focus.toggle(key)
        applySoon()
        saveSoon()
    }

    func activateProfile(_ profile: AudioProfile?) {
        activeProfileID = profile?.id
        // A profile describes a whole state, so per-app overrides are cleared: leaving
        // them would make the profile look broken.
        if profile != nil {
            appSettings.removeAll()
        }
        applySoon()
        saveSoon()
    }

    /// Every per-app setting in force right now, as a profile would store it.
    ///
    /// Deliberately not `appSettings`: that holds only the overrides layered on top of
    /// the active profile, so saving it would quietly drop everything the profile
    /// itself decided. What the user means by "save this" is what they can hear.
    ///
    /// Apps that are not running keep their entry, so switching profiles while Slack
    /// happens to be closed does not forget what Slack should do.
    private var currentSettingsSnapshot: [AppKey: AppAudioSettings] {
        var keys = Set(appSettings.keys)
        keys.formUnion(apps.map(\.key))
        if let activeProfile {
            keys.formUnion(activeProfile.settings.keys)
        }
        return policy.settingsSnapshot(for: keys)
    }

    func saveCurrentAsProfile(named name: String) {
        let profile = AudioProfile(
            name: name,
            settings: currentSettingsSnapshot,
            focus: focus.isActive ? focus : nil
        )
        profiles.append(profile)
        activeProfileID = profile.id
        // The profile now carries these settings, so the overrides that produced them
        // would only shadow it.
        appSettings.removeAll()
        saveSoon()
    }

    /// Replaces a profile's contents with what the user can hear right now.
    ///
    /// The only way to edit a saved profile: activate it, change what you want in the
    /// panel, then fold those changes back in.
    func updateProfile(_ profile: AudioProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].settings = currentSettingsSnapshot
        profiles[index].focus = focus.isActive ? focus : nil
        if activeProfileID == profile.id {
            appSettings.removeAll()
        }
        applySoon()
        saveSoon()
    }

    func renameProfile(_ profile: AudioProfile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id })
        else { return }
        profiles[index].name = trimmed
        saveSoon()
    }

    func deleteProfile(_ profile: AudioProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = nil
        }
        applySoon()
        saveSoon()
    }

    func setOutputLimit(_ limit: OutputLimit) {
        outputLimit = limit
        applySoon()
        saveSoon()
    }

    /// Puts every running app into full control at half volume with a shaped EQ,
    /// without touching stored settings.
    ///
    /// Used by `--dump-state --simulate-control` to prove the capture, processing and
    /// playback path end to end on a real machine, which no unit test can do.
    func simulateFullControlForDiagnostics() {
        isPersistenceSuspended = true
        let profile = AudioProfile(
            name: "Diagnostics",
            unlistedApps: AppAudioSettings(
                volume: 0.5,
                mode: .fullControl,
                equalizer: EqualizerSettings(isEnabled: true, gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, -6])
            )
        )
        profiles.append(profile)
        activeProfileID = profile.id
        appSettings.removeAll()
        applySoon()
    }

    /// Mutes every running app for the life of the process, without touching stored
    /// settings.
    ///
    /// Used by `--dump-state --simulate-mute` to exercise the real mute-only path on a
    /// machine where muting is not behaving, so the tap state can be inspected while
    /// the user listens.
    func simulateMuteForDiagnostics() {
        isPersistenceSuspended = true
        let profile = AudioProfile(
            name: "Diagnostics mute",
            unlistedApps: AppAudioSettings(isMuted: true, mode: .muteOnly)
        )
        profiles.append(profile)
        activeProfileID = profile.id
        appSettings.removeAll()
        applySoon()
    }

    // MARK: - Schedule

    func addScheduleRule(_ rule: ScheduleRule) {
        scheduleRules.append(rule)
        recomputeSchedule()
        scheduleNextScheduleWakeUp()
        applySoon()
        saveSoon()
    }

    func updateScheduleRule(_ rule: ScheduleRule) {
        guard let index = scheduleRules.firstIndex(where: { $0.id == rule.id }) else { return }
        scheduleRules[index] = rule
        recomputeSchedule()
        scheduleNextScheduleWakeUp()
        applySoon()
        saveSoon()
    }

    func deleteScheduleRule(_ rule: ScheduleRule) {
        scheduleRules.removeAll { $0.id == rule.id }
        recomputeSchedule()
        scheduleNextScheduleWakeUp()
        applySoon()
        saveSoon()
    }

    /// Works out what the currently active rules mean for the policy.
    private func recomputeSchedule() {
        let active = ScheduleEngine.activeRules(scheduleRules, at: Date(), calendar: calendar)
        activeScheduleRuleNames = active.map(\.name)

        var muted: Set<AppKey> = []
        var focusOverride: FocusMode?
        var profileOverride: UUID?

        for rule in active {
            switch rule.action {
            case .muteApps(let keys):
                muted.formUnion(keys)
            case .focusOn(let keys):
                focusOverride = FocusMode(isActive: true, allowedApps: keys)
            case .applyProfile(let id):
                profileOverride = id
            }
        }

        scheduleMutedApps = muted
        scheduleFocus = focusOverride
        if let profileOverride, profiles.contains(where: { $0.id == profileOverride }) {
            activeProfileID = profileOverride
        }
    }

    /// Sleeps exactly until the next rule boundary — no repeating timer anywhere.
    private func scheduleNextScheduleWakeUp() {
        scheduleTask?.cancel()

        guard
            let next = ScheduleEngine.nextTransition(for: scheduleRules, after: Date(), calendar: calendar)
        else {
            scheduleTask = nil
            return
        }

        let interval = max(next.timeIntervalSinceNow, 1)
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            recomputeSchedule()
            applySoon()
            scheduleNextScheduleWakeUp()
        }
    }

    // MARK: - Process updates

    private func processesChanged(_ processes: [AudioProcessSnapshot]) {
        let grouped = AppGrouping.group(processes, excluding: ownBundleIdentifier)
        guard grouped != apps else { return }
        apps = grouped
        applySoon()
    }

    // MARK: - Applying to the engine

    /// Coalesces rapid changes (a slider drag) into one engine update.
    private func applySoon() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            await applyNow()
        }
    }

    private func applyNow() async {
        let policy = policy
        let apps = apps
        let states = policy.activeStates(for: apps)

        announce(states: states, apps: apps)

        guard !states.isEmpty else {
            // Nothing to control: release every Core Audio object we hold.
            await engine.shutdown()
            return
        }

        guard permission == .granted else { return }

        do {
            try await engine.apply(states: states, for: apps)
        } catch EngineError.permissionRequired {
            permission = await engine.permissionStatus()
        } catch {
            // Applying failed; audio keeps playing untouched, which is the safe outcome.
            engineStatus = .degraded(.tapCreationFailed)
        }
    }

    /// Notifies about changes the user did not make themselves.
    private func announce(states: [EffectiveAppState], apps: [AudioApp]) {
        let byKey = Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0) })
        notifications.reportAutomaticChanges(
            previous: lastStates,
            current: byKey,
            apps: apps,
            enabled: preferences.showNotifications
        )
        notifications.reportLoudApps(
            states: byKey,
            apps: apps,
            enabled: preferences.warnOnHighVolume
        )
        lastStates = byKey
    }

    // MARK: - Metering

    private func panelVisibilityChanged() {
        meterTask?.cancel()
        meterTask = nil
        guard isPanelVisible else {
            levels = [:]
            return
        }

        meterTask = Task { [weak self] in
            // 15 Hz is enough for a level meter to look alive and keeps the redraw cost
            // in the noise. Nothing runs at all while the panel is closed.
            while !Task.isCancelled {
                guard let self else { return }
                if let tapEngine = engine as? TapEngine {
                    let peaks = await tapEngine.peakLevels()
                    if !Task.isCancelled {
                        levels = peaks
                    }
                }
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    /// Throws away every stored setting and writes defaults back.
    ///
    /// Exposed through `--reset-settings` so a bad state can always be recovered
    /// without hunting through the container by hand.
    func resetAllSettings() async {
        appSettings = [:]
        profiles = []
        activeProfileID = nil
        scheduleRules = []
        focus = .off
        outputLimit = OutputLimit()
        preferences = Preferences()
        isPersistenceSuspended = false
        await persist()
        await applyNow()
    }

    // MARK: - Persistence

    private func loadSettings() async {
        let result = await store.load()
        let state = result.state

        appSettings = state.appSettings
        profiles = state.profiles
        activeProfileID = state.activeProfileID
        scheduleRules = state.scheduleRules
        focus = state.focus
        outputLimit = state.outputLimit
        preferences = state.preferences

        switch result.outcome {
        case .recoveredFromCorruptFile:
            loadWarning = String(localized: "Your settings could not be read and have been reset.")
        case .loaded, .noFileYet, .migrated:
            loadWarning = nil
        }
    }

    /// Debounced so dragging a slider does not write the file on every frame.
    private func saveSoon() {
        guard !isPersistenceSuspended else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await persist()
        }
    }

    private func persist() async {
        guard !isPersistenceSuspended else { return }

        let state = PersistedState(
            appSettings: appSettings,
            profiles: profiles,
            activeProfileID: activeProfileID,
            scheduleRules: scheduleRules,
            focus: focus,
            outputLimit: outputLimit,
            preferences: preferences
        )
        try? await store.save(state)
    }
}
