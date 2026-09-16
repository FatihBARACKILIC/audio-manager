import AudioDomain
import Foundation
import Testing

@testable import AudioPersistence

@Suite("Settings export and import")
struct SettingsTransferTests {

    private func sampleState() -> PersistedState {
        var equalizer = EqualizerSettings(isEnabled: true)
        equalizer.setGain(6, at: 2)

        let profile = AudioProfile(
            name: "Work",
            settings: [.bundle("com.tinyspeck.slackmacgap"): AppAudioSettings(isMuted: true)]
        )
        let rule = ScheduleRule(
            name: "Quiet mornings",
            weekdays: Weekday.weekdays,
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 12, minute: 0),
            action: .muteApps([.bundle("com.tinyspeck.slackmacgap")])
        )

        return PersistedState(
            appSettings: [
                .bundle("com.spotify.client"): AppAudioSettings(
                    volume: 0.4,
                    boostDecibels: 3,
                    mode: .fullControl,
                    equalizer: equalizer
                )
            ],
            profiles: [profile],
            activeProfileID: profile.id,
            scheduleRules: [rule],
            focus: FocusMode(isActive: true, allowedApps: [.bundle("us.zoom.xos")]),
            outputLimit: OutputLimit(maximumGain: 1.5, isEnabled: true),
            preferences: Preferences(launchAtLogin: true, panelShortcut: "cmd+shift+a")
        )
    }

    @Test("A settings file survives a round trip unchanged")
    func roundTripKeepsEverything() throws {
        let original = sampleState()

        let data = try SettingsTransfer.data(for: original)
        let restored = try SettingsTransfer.state(from: data)

        #expect(restored == original)
    }

    @Test("The export is readable JSON carrying its format and version")
    func exportIsPlainJSON() throws {
        let data = try SettingsTransfer.data(for: sampleState())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["format"] as? String == SettingsDocument.formatIdentifier)
        #expect(object["exportedAt"] is String)
        let settings = try #require(object["settings"] as? [String: Any])
        #expect(settings["schemaVersion"] as? Int == PersistedState.currentSchemaVersion)
    }

    // MARK: - Refusing the wrong file

    @Test("Some other JSON file is refused instead of wiping the settings")
    func foreignJSONIsRefused() throws {
        // Every field of `PersistedState` decodes with a default, so without the format
        // marker this would import as a perfectly valid empty document.
        let data = try #require(#"{"hello":"world"}"#.data(using: .utf8))

        #expect(throws: SettingsTransferError.unreadable) {
            try SettingsTransfer.state(from: data)
        }
    }

    @Test("A bare settings document without the envelope is refused")
    func bareStateIsRefused() throws {
        let data = try JSONEncoder().encode(sampleState())

        #expect(throws: SettingsTransferError.unreadable) {
            try SettingsTransfer.state(from: data)
        }
    }

    @Test("Something that is not JSON at all is refused")
    func rubbishIsRefused() throws {
        let data = try #require("not a settings file".data(using: .utf8))

        #expect(throws: SettingsTransferError.unreadable) {
            try SettingsTransfer.state(from: data)
        }
    }

    @Test("A file from a newer version is refused rather than half-understood")
    func newerSchemaIsRefused() throws {
        var state = sampleState()
        state.schemaVersion = PersistedState.currentSchemaVersion + 5
        let document = SettingsDocument(exportedAt: Date(), settings: state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        #expect(throws: SettingsTransferError.newerThanThisApp(version: state.schemaVersion)) {
            try SettingsTransfer.state(from: data)
        }
    }

    // MARK: - Older files

    @Test("A file without an export date still imports")
    func missingDateIsFine() throws {
        let document = SettingsDocument(exportedAt: nil, settings: sampleState())
        let data = try JSONEncoder().encode(document)

        let restored = try SettingsTransfer.state(from: data)

        #expect(restored.profiles.count == 1)
    }

    @Test("An older file is migrated on the way in")
    func olderSchemaIsMigrated() throws {
        var state = sampleState()
        state.schemaVersion = 0
        let data = try JSONEncoder().encode(SettingsDocument(settings: state))

        let restored = try SettingsTransfer.state(from: data)

        #expect(restored.schemaVersion == PersistedState.currentSchemaVersion)
        #expect(restored.profiles.count == 1)
    }
}
