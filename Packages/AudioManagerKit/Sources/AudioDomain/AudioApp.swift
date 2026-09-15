import Foundation

/// Stable identity for an app whose audio we control.
///
/// Apps are identified by bundle identifier so that settings survive relaunches and
/// so that the many helper processes of a Chromium or Electron app collapse into one
/// row. Processes without a bundle identifier (command line tools, for example) fall
/// back to an executable-path identity, which is still stable across a single run.
public struct AppKey: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func bundle(_ bundleIdentifier: String) -> AppKey {
        AppKey(rawValue: bundleIdentifier)
    }

    public static func executable(_ path: String) -> AppKey {
        AppKey(rawValue: "path:\(path)")
    }

    public static func process(_ pid: Int32) -> AppKey {
        AppKey(rawValue: "pid:\(pid)")
    }

    public var description: String { rawValue }
}

/// Encoded as a plain string so profiles stay readable and so dictionaries keyed by
/// `AppKey` become JSON objects instead of flattened key/value arrays.
extension AppKey: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AppKey: CodingKeyRepresentable {
    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    public var codingKey: any CodingKey {
        AppKeyCodingKey(stringValue: rawValue)
    }
}

private struct AppKeyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// One audio-producing process as Core Audio reports it.
///
/// This is the raw, ungrouped input to `AppGrouping`. `audioObjectID` is the Core
/// Audio object, not the process id; both are needed because taps are created against
/// the audio object while identity resolution works from the pid.
public struct AudioProcessSnapshot: Hashable, Sendable, Identifiable {
    public var audioObjectID: UInt32
    public var processID: Int32
    public var bundleIdentifier: String?
    /// Path of the enclosing `.app` bundle, resolved by walking up from the executable.
    /// For a Chrome renderer helper this is Chrome itself.
    public var containerBundlePath: String?
    public var containerBundleIdentifier: String?
    public var displayName: String?
    public var isRunningOutput: Bool
    /// True when this process belongs to an app the user can see and switch to, as
    /// opposed to a daemon or a background agent.
    public var isRegularApp: Bool

    public var id: UInt32 { audioObjectID }

    public init(
        audioObjectID: UInt32,
        processID: Int32,
        bundleIdentifier: String? = nil,
        containerBundlePath: String? = nil,
        containerBundleIdentifier: String? = nil,
        displayName: String? = nil,
        isRunningOutput: Bool = false,
        isRegularApp: Bool = false
    ) {
        self.audioObjectID = audioObjectID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.containerBundlePath = containerBundlePath
        self.containerBundleIdentifier = containerBundleIdentifier
        self.displayName = displayName
        self.isRunningOutput = isRunningOutput
        self.isRegularApp = isRegularApp
    }
}

/// An app as the user sees it in the panel: one row, however many processes it runs.
public struct AudioApp: Identifiable, Hashable, Sendable {
    public var key: AppKey
    public var name: String
    public var bundleIdentifier: String?
    public var bundlePath: String?
    /// Every audio process that belongs to this app, helpers included.
    public var processes: [AudioProcessSnapshot]

    public var id: AppKey { key }

    /// True when at least one of the app's processes is producing output right now.
    public var isPlaying: Bool {
        processes.contains { $0.isRunningOutput }
    }

    public var audioObjectIDs: [UInt32] {
        processes.map(\.audioObjectID)
    }

    public init(
        key: AppKey,
        name: String,
        bundleIdentifier: String? = nil,
        bundlePath: String? = nil,
        processes: [AudioProcessSnapshot] = []
    ) {
        self.key = key
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.processes = processes
    }
}
