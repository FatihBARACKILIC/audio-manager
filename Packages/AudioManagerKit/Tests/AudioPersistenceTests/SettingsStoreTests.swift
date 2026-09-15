import AudioDomain
import Foundation
import Testing

@testable import AudioPersistence

@Suite("Settings store")
struct SettingsStoreTests {

    /// Every test gets its own directory; nothing here can touch real user settings.
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleState() -> PersistedState {
        var equalizer = EqualizerSettings(isEnabled: true)
        equalizer.setGain(4, at: 1)

        let profile = AudioProfile(
            name: "Work",
            settings: [.bundle("com.tinyspeck.slackmacgap"): AppAudioSettings(isMuted: true)],
            unlistedApps: AppAudioSettings(volume: 0.3, mode: .fullControl)
        )

        return PersistedState(
            appSettings: [
                .bundle("com.spotify.client"): AppAudioSettings(
                    volume: 0.6,
                    boostDecibels: 3,
                    mode: .fullControl,
                    equalizer: equalizer
                )
            ],
            profiles: [profile],
            activeProfileID: profile.id,
            scheduleRules: [
                ScheduleRule(
                    name: "Work hours",
                    weekdays: Weekday.weekdays,
                    start: TimeOfDay(hour: 9, minute: 0),
                    end: TimeOfDay(hour: 17, minute: 30),
                    action: .applyProfile(profile.id)
                )
            ],
            focus: FocusMode(isActive: true, allowedApps: [.bundle("us.zoom.xos")]),
            outputLimit: OutputLimit(maximumGain: 0.8),
            preferences: Preferences(launchAtLogin: true, panelShortcut: "cmd+shift+v")
        )
    }

    @Test("A fresh install loads defaults instead of failing")
    func loadsDefaultsWhenMissing() async {
        let store = SettingsStore(directory: temporaryDirectory())
        let result = await store.load()

        #expect(result.outcome == .noFileYet)
        #expect(result.state == .empty)
    }

    @Test("State survives a save and load round-trip")
    func roundTrip() async throws {
        let store = SettingsStore(directory: temporaryDirectory())
        let original = sampleState()

        try await store.save(original)
        let result = await store.load()

        #expect(result.outcome == .loaded)
        #expect(result.state == original)
    }

    @Test("Saving creates the container directory if it does not exist")
    func createsDirectory() async throws {
        let directory = temporaryDirectory().appendingPathComponent("nested/deeper", isDirectory: true)
        let store = SettingsStore(directory: directory)

        try await store.save(sampleState())
        let result = await store.load()

        #expect(result.outcome == .loaded)
    }

    @Test("A corrupted file falls back to defaults and says so")
    func recoversFromCorruption() async throws {
        let directory = temporaryDirectory()
        let store = SettingsStore(directory: directory)
        try await store.save(sampleState())

        let url = directory.appendingPathComponent(SettingsStore.fileName)
        try Data("this is not json".utf8).write(to: url)

        let result = await store.load()

        #expect(result.state == .empty)
        if case .recoveredFromCorruptFile = result.outcome {
            // Expected.
        } else {
            Issue.record("expected a corruption outcome, got \(result.outcome)")
        }
    }

    @Test("Unknown fields and missing fields both decode safely")
    func toleratesUnexpectedJSON() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent(SettingsStore.fileName)
        let json = #"{"schemaVersion":1,"somethingNew":42}"#
        try Data(json.utf8).write(to: url)

        let result = await SettingsStore(directory: directory).load()

        #expect(result.outcome == .loaded)
        #expect(result.state.profiles.isEmpty)
        #expect(result.state.preferences.panelShortcut == "cmd+shift+v")
    }

    @Test("An older schema version is migrated, not discarded")
    func migratesOldSchema() async throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent(SettingsStore.fileName)
        let json = #"{"schemaVersion":0,"profiles":[{"id":"\#(UUID().uuidString)","name":"Legacy","settings":{}}]}"#
        try Data(json.utf8).write(to: url)

        let result = await SettingsStore(directory: directory).load()

        #expect(result.outcome == .migrated(fromVersion: 0))
        #expect(result.state.profiles.map(\.name) == ["Legacy"])
        #expect(result.state.schemaVersion == PersistedState.currentSchemaVersion)
    }

    @Test("Saving always stamps the current schema version")
    func stampsSchemaVersion() async throws {
        let directory = temporaryDirectory()
        let store = SettingsStore(directory: directory)

        var state = sampleState()
        state.schemaVersion = 0
        try await store.save(state)

        let result = await store.load()
        #expect(result.state.schemaVersion == PersistedState.currentSchemaVersion)
    }

    @Test("The active profile resolves, and a deleted one does not crash")
    func activeProfileLookup() {
        var state = sampleState()
        #expect(state.activeProfile?.name == "Work")

        state.profiles = []
        #expect(state.activeProfile == nil)
    }
}
