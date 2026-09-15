import Foundation

/// A named set of per-app settings the user can switch to in one click.
///
/// "Work": Slack and Mail muted, IDEs audible. "Music": Spotify loud, everything else
/// quiet. Apps the profile does not mention fall back to `unlistedApps`, which is what
/// makes "mute everything except Zoom" expressible without listing every app.
public struct AudioProfile: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// Explicit settings per app.
    public var settings: [AppKey: AppAudioSettings]
    /// Applied to any running app the profile does not name. `nil` leaves them alone.
    public var unlistedApps: AppAudioSettings?
    /// Optional focus restriction carried by the profile.
    public var focus: FocusMode?

    public init(
        id: UUID = UUID(),
        name: String,
        settings: [AppKey: AppAudioSettings] = [:],
        unlistedApps: AppAudioSettings? = nil,
        focus: FocusMode? = nil
    ) {
        self.id = id
        self.name = name
        self.settings = settings
        self.unlistedApps = unlistedApps
        self.focus = focus
    }

    /// Settings this profile dictates for an app, or `nil` when it has no opinion.
    public func settings(for key: AppKey) -> AppAudioSettings? {
        settings[key] ?? unlistedApps
    }
}

/// "Only these apps may make sound." Everything else is muted while focus is on.
public struct FocusMode: Codable, Sendable, Equatable, Hashable {
    public var isActive: Bool
    public var allowedApps: Set<AppKey>

    public static let off = FocusMode(isActive: false, allowedApps: [])

    public init(isActive: Bool = false, allowedApps: Set<AppKey> = []) {
        self.isActive = isActive
        self.allowedApps = allowedApps
    }

    public func allows(_ key: AppKey) -> Bool {
        guard isActive else { return true }
        return allowedApps.contains(key)
    }

    public mutating func toggle(_ key: AppKey) {
        if allowedApps.contains(key) {
            allowedApps.remove(key)
        } else {
            allowedApps.insert(key)
        }
    }
}
