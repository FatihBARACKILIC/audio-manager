import AudioDomain
import Foundation

/// Everything the app remembers between launches.
///
/// One versioned document, written atomically. Adding a field means giving it a
/// default here and a migration test — an existing user's profiles must survive every
/// update.
public struct PersistedState: Codable, Sendable, Equatable {
    /// Bumped only when a migration is required, never for additive changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var appSettings: [AppKey: AppAudioSettings]
    public var profiles: [AudioProfile]
    public var activeProfileID: UUID?
    public var scheduleRules: [ScheduleRule]
    public var focus: FocusMode
    public var outputLimit: OutputLimit
    public var preferences: Preferences

    public static let empty = PersistedState()

    public init(
        schemaVersion: Int = PersistedState.currentSchemaVersion,
        appSettings: [AppKey: AppAudioSettings] = [:],
        profiles: [AudioProfile] = [],
        activeProfileID: UUID? = nil,
        scheduleRules: [ScheduleRule] = [],
        focus: FocusMode = .off,
        outputLimit: OutputLimit = OutputLimit(),
        preferences: Preferences = Preferences()
    ) {
        self.schemaVersion = schemaVersion
        self.appSettings = appSettings
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.scheduleRules = scheduleRules
        self.focus = focus
        self.outputLimit = outputLimit
        self.preferences = preferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appSettings = try container.decodeIfPresent([AppKey: AppAudioSettings].self, forKey: .appSettings) ?? [:]
        profiles = try container.decodeIfPresent([AudioProfile].self, forKey: .profiles) ?? []
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        scheduleRules = try container.decodeIfPresent([ScheduleRule].self, forKey: .scheduleRules) ?? []
        focus = try container.decodeIfPresent(FocusMode.self, forKey: .focus) ?? .off
        outputLimit = try container.decodeIfPresent(OutputLimit.self, forKey: .outputLimit) ?? OutputLimit()
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
    }

    /// The profile currently applied, if it still exists.
    public var activeProfile: AudioProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }
}

/// Small, user-visible app preferences.
public struct Preferences: Codable, Sendable, Equatable, Hashable {
    public var launchAtLogin: Bool
    public var showNotifications: Bool
    public var warnOnHighVolume: Bool
    /// Key equivalent for the menu bar panel, stored as a printable shortcut string.
    public var panelShortcut: String?
    public var focusShortcut: String?

    public init(
        launchAtLogin: Bool = false,
        showNotifications: Bool = true,
        warnOnHighVolume: Bool = true,
        panelShortcut: String? = "cmd+shift+v",
        focusShortcut: String? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.warnOnHighVolume = warnOnHighVolume
        self.panelShortcut = panelShortcut
        self.focusShortcut = focusShortcut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
        warnOnHighVolume = try container.decodeIfPresent(Bool.self, forKey: .warnOnHighVolume) ?? true
        panelShortcut = try container.decodeIfPresent(String.self, forKey: .panelShortcut) ?? "cmd+shift+v"
        focusShortcut = try container.decodeIfPresent(String.self, forKey: .focusShortcut)
    }
}
