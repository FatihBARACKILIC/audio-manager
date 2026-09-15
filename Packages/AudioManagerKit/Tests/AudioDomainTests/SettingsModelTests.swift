import Foundation
import Testing

@testable import AudioDomain

@Suite("Settings models")
struct SettingsModelTests {

    @Test("Volume and boost are clamped on the way in")
    func clampsValues() {
        var settings = AppAudioSettings(volume: 5, boostDecibels: 99)
        #expect(settings.volume == 1)
        #expect(settings.boostDecibels == AppAudioSettings.boostRange.upperBound)

        settings.setVolume(-3)
        #expect(settings.volume == 0)

        settings.setBoost(decibels: .nan)
        #expect(settings.boostDecibels == 0)
    }

    @Test("The equalizer always has exactly ten clamped bands")
    func equalizerShape() {
        let tooFew = EqualizerSettings(gains: [1, 2, 3])
        #expect(tooFew.gains.count == EqualizerSettings.bandCount)
        #expect(tooFew.gains[3] == 0)

        let tooMany = EqualizerSettings(gains: Array(repeating: 99, count: 40))
        #expect(tooMany.gains.count == EqualizerSettings.bandCount)
        #expect(tooMany.gains.allSatisfy { $0 == EqualizerSettings.gainRange.upperBound })
    }

    @Test("A disabled or zeroed equalizer reports itself flat so the DSP can be skipped")
    func flatness() {
        #expect(EqualizerSettings.flat.isFlat)

        var enabled = EqualizerSettings(isEnabled: true)
        #expect(enabled.isFlat)

        enabled.setGain(3, at: 4)
        #expect(!enabled.isFlat)

        enabled.isEnabled = false
        #expect(enabled.isFlat)
    }

    @Test("Out-of-range band indices are ignored rather than crashing")
    func bandBounds() {
        var equalizer = EqualizerSettings(isEnabled: true)
        equalizer.setGain(6, at: -1)
        equalizer.setGain(6, at: 99)

        #expect(equalizer.isFlat)
        #expect(equalizer.gain(at: 99) == 0)
    }

    @Test("Settings round-trip through JSON")
    func codableRoundTrip() throws {
        var equalizer = EqualizerSettings(isEnabled: true)
        equalizer.setGain(-4.5, at: 2)
        let original = AppAudioSettings(
            volume: 0.42,
            boostDecibels: 3,
            isMuted: true,
            mode: .fullControl,
            equalizer: equalizer
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppAudioSettings.self, from: data)

        #expect(decoded == original)
    }

    @Test("A corrupted stored equalizer decodes into a safe one")
    func decodesCorruptEqualizer() throws {
        let json = #"{"isEnabled":true,"gains":[99,-99,0]}"#
        let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: Data(json.utf8))

        #expect(decoded.gains.count == EqualizerSettings.bandCount)
        #expect(decoded.gains[0] == EqualizerSettings.gainRange.upperBound)
        #expect(decoded.gains[1] == EqualizerSettings.gainRange.lowerBound)
    }

    @Test("App keys encode as plain strings and work as dictionary keys")
    func appKeyCoding() throws {
        let settings: [AppKey: AppAudioSettings] = [.bundle("com.spotify.client"): AppAudioSettings(volume: 0.5)]
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("com.spotify.client"))

        let decoded = try JSONDecoder().decode([AppKey: AppAudioSettings].self, from: data)
        #expect(decoded[.bundle("com.spotify.client")]?.volume == 0.5)
    }

    @Test("Focus mode toggling adds and removes apps")
    func focusToggle() {
        var focus = FocusMode(isActive: true)
        let zoom = AppKey.bundle("us.zoom.xos")

        #expect(!focus.allows(zoom))
        focus.toggle(zoom)
        #expect(focus.allows(zoom))
        focus.toggle(zoom)
        #expect(!focus.allows(zoom))
    }

    @Test("An inactive focus mode allows everything")
    func inactiveFocusAllowsAll() {
        #expect(FocusMode.off.allows(.bundle("anything")))
    }

    @Test("Profiles fall back to their unlisted-app settings")
    func profileFallback() {
        let profile = AudioProfile(
            name: "Music",
            settings: [.bundle("com.spotify.client"): AppAudioSettings(volume: 0.7)],
            unlistedApps: AppAudioSettings(volume: 0.1)
        )

        #expect(profile.settings(for: .bundle("com.spotify.client"))?.volume == 0.7)
        #expect(profile.settings(for: .bundle("com.other.app"))?.volume == 0.1)
    }

    @Test("A profile without a fallback has no opinion on unlisted apps")
    func profileWithoutFallback() {
        let profile = AudioProfile(name: "Sparse")
        #expect(profile.settings(for: .bundle("com.other.app")) == nil)
    }
}
