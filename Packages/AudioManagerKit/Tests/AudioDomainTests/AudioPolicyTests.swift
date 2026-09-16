import Foundation
import Testing

@testable import AudioDomain

@Suite("Policy resolution")
struct AudioPolicyTests {

    private let slack = AppKey.bundle("com.tinyspeck.slackmacgap")
    private let spotify = AppKey.bundle("com.spotify.client")
    private let zoom = AppKey.bundle("us.zoom.xos")

    private func app(_ key: AppKey, name: String) -> AudioApp {
        AudioApp(key: key, name: name)
    }

    @Test("An untouched app needs no engine work at all")
    func defaultIsPassthrough() {
        let policy = AudioPolicy()
        let state = policy.state(for: spotify)

        #expect(state.isPassthrough)
        #expect(!state.needsRendering)
        #expect(!state.needsSilencing)
    }

    @Test("Muting needs a tap but never the rendering path")
    func muteUsesMuteOnlyTap() {
        let policy = AudioPolicy(manual: [slack: AppAudioSettings(isMuted: true)])
        let state = policy.state(for: slack)

        #expect(state.isMuted)
        #expect(state.needsSilencing)
        #expect(!state.needsRendering)
    }

    @Test("Volume below unity only renders in full-control mode")
    func volumeRequiresFullControl() {
        let muteOnly = AudioPolicy(manual: [spotify: AppAudioSettings(volume: 0.3, mode: .muteOnly)])
        #expect(!muteOnly.state(for: spotify).needsRendering)

        let fullControl = AudioPolicy(manual: [spotify: AppAudioSettings(volume: 0.3, mode: .fullControl)])
        let state = fullControl.state(for: spotify)
        #expect(state.needsRendering)
        #expect(abs(state.gain - 0.09) < 0.0001)
    }

    @Test("Full volume with a flat EQ stays out of the rendering path")
    func unityIsPassthrough() {
        let policy = AudioPolicy(manual: [spotify: AppAudioSettings(volume: 1, mode: .fullControl)])
        #expect(policy.state(for: spotify).isPassthrough)
    }

    @Test("An enabled non-flat EQ forces rendering even at full volume")
    func equalizerForcesRendering() {
        var equalizer = EqualizerSettings(isEnabled: true)
        equalizer.setGain(6, at: 0)
        let policy = AudioPolicy(manual: [spotify: AppAudioSettings(mode: .fullControl, equalizer: equalizer)])

        #expect(policy.state(for: spotify).needsRendering)
    }

    @Test("Focus mode mutes everything it does not allow")
    func focusModeMutesOthers() {
        let policy = AudioPolicy(
            manual: [spotify: AppAudioSettings(volume: 1), slack: AppAudioSettings(volume: 1)],
            focus: FocusMode(isActive: true, allowedApps: [zoom])
        )

        #expect(policy.state(for: spotify).isMuted)
        #expect(policy.state(for: slack).isMuted)
        #expect(!policy.state(for: zoom).isMuted)
        #expect(policy.state(for: spotify).reason == .focusMode)
    }

    @Test("Focus mode overrides a per-app setting that would unmute")
    func focusBeatsManual() {
        let policy = AudioPolicy(
            manual: [spotify: AppAudioSettings(volume: 1, isMuted: false)],
            focus: FocusMode(isActive: true, allowedApps: [zoom])
        )

        #expect(policy.state(for: spotify).isMuted)
    }

    @Test("A schedule mute beats focus and manual settings")
    func scheduleWins() {
        let policy = AudioPolicy(
            manual: [spotify: AppAudioSettings(isMuted: false)],
            focus: FocusMode(isActive: true, allowedApps: [spotify]),
            scheduleMutedApps: [spotify]
        )

        let state = policy.state(for: spotify)
        #expect(state.isMuted)
        #expect(state.reason == .schedule)
    }

    @Test("Profile settings apply to apps the user never touched")
    func profileAppliesToUnlisted() {
        let profile = AudioProfile(
            name: "Work",
            settings: [slack: AppAudioSettings(isMuted: true)],
            unlistedApps: AppAudioSettings(volume: 0.2, mode: .fullControl)
        )
        let policy = AudioPolicy(activeProfile: profile)

        #expect(policy.state(for: slack).isMuted)
        #expect(policy.state(for: spotify).needsRendering)
        #expect(policy.state(for: spotify).reason == .profile)
    }

    @Test("A manual override wins over the active profile")
    func manualBeatsProfile() {
        let profile = AudioProfile(name: "Work", settings: [slack: AppAudioSettings(isMuted: true)])
        let policy = AudioPolicy(
            manual: [slack: AppAudioSettings(isMuted: false)],
            activeProfile: profile
        )

        #expect(!policy.state(for: slack).isMuted)
        #expect(policy.state(for: slack).reason == .manual)
    }

    @Test("Boost raises gain but never past the hearing-safety limit")
    func limitBeatsBoost() {
        let policy = AudioPolicy(
            manual: [spotify: AppAudioSettings(volume: 1, boostDecibels: 12, mode: .fullControl)],
            limit: OutputLimit(maximumGain: 1)
        )

        #expect(policy.state(for: spotify).gain == 1)
    }

    @Test("Boost is audible when the limit allows it")
    func boostAppliesUnderLimit() {
        let policy = AudioPolicy(
            manual: [spotify: AppAudioSettings(volume: 1, boostDecibels: 6, mode: .fullControl)],
            limit: OutputLimit(maximumGain: 4)
        )

        #expect(abs(policy.state(for: spotify).gain - 1.995) < 0.01)
    }

    @Test("Only apps needing work are reported as active")
    func activeStatesAreNarrow() {
        let apps = [app(spotify, name: "Spotify"), app(slack, name: "Slack"), app(zoom, name: "Zoom")]
        let policy = AudioPolicy(
            manual: [
                slack: AppAudioSettings(isMuted: true),
                spotify: AppAudioSettings(volume: 0.5, mode: .fullControl),
            ]
        )

        let active = policy.activeStates(for: apps)

        #expect(active.count == 2)
        #expect(!active.contains { $0.key == zoom })
    }
}
