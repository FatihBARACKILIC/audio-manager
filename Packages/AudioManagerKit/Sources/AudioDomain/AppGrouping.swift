import Foundation

/// Collapses the raw Core Audio process list into the app rows shown in the panel.
///
/// Chromium and Electron apps play their audio from short-lived helper processes
/// ("Google Chrome Helper (Renderer)"), which appear and disappear constantly. Showing
/// them directly would make the list unusable, so every process is attributed to the
/// `.app` bundle that contains it and grouped under that one identity.
public enum AppGrouping {

    /// Bundle identifiers that are part of the audio system itself rather than
    /// something the user thinks of as "an app playing sound".
    public static let systemProcessIdentifiers: Set<String> = [
        "com.apple.audiomxd",
        "com.apple.mediaremoted",
        "com.apple.controlcenter",
        "com.apple.PowerChime",
        "com.apple.cmio.ContinuityCaptureAgent",
        "com.apple.avconferenced",
        "com.apple.CoreSpeech",
        "com.apple.accessibility.heard",
        "com.apple.universalaccessd",
        "com.apple.TelephonyUtilities",
        "com.apple.cloudpaird",
        "com.apple.coreaudiod",
    ]

    /// Suffixes Chromium/Electron append to a helper's bundle identifier.
    private static let helperSuffixes = [
        ".helper.renderer",
        ".helper.gpu",
        ".helper.plugin",
        ".helper.alerts",
        ".helper",
    ]

    /// Strips a helper suffix so `com.google.Chrome.helper.renderer` becomes
    /// `com.google.Chrome`. Returns the identifier unchanged when it is not a helper.
    public static func normalizedBundleIdentifier(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        for suffix in helperSuffixes where lowercased.hasSuffix(suffix) {
            return String(identifier.dropLast(suffix.count))
        }
        return identifier
    }

    /// The identity a single process belongs to, most reliable source first.
    public static func key(for process: AudioProcessSnapshot) -> AppKey {
        if let container = process.containerBundleIdentifier, !container.isEmpty {
            return .bundle(normalizedBundleIdentifier(container))
        }
        if let bundle = process.bundleIdentifier, !bundle.isEmpty {
            return .bundle(normalizedBundleIdentifier(bundle))
        }
        if let path = process.containerBundlePath, !path.isEmpty {
            return .executable(path)
        }
        return .process(process.processID)
    }

    /// Whether a process should ever be offered to the user for control.
    public static func isUserFacing(_ process: AudioProcessSnapshot) -> Bool {
        let identifiers = [process.containerBundleIdentifier, process.bundleIdentifier]
            .compactMap { $0 }
            .map(normalizedBundleIdentifier)
        if identifiers.contains(where: systemProcessIdentifiers.contains) {
            return false
        }
        // A real app bundle is always listed, even when it is silent, so the user can
        // pre-mute it. Anything else only shows up while it is actually playing.
        if process.containerBundlePath != nil {
            return true
        }
        return process.isRunningOutput
    }

    /// Human readable name for a group, preferring the container app's name.
    public static func displayName(for processes: [AudioProcessSnapshot], key: AppKey) -> String {
        if let named = processes.compactMap(\.displayName).first(where: { !$0.isEmpty }) {
            return named
        }
        if let path = processes.compactMap(\.containerBundlePath).first {
            let name = (path as NSString).lastPathComponent
            if name.hasSuffix(".app") {
                return String(name.dropLast(4))
            }
            return name
        }
        if let bundle = processes.compactMap(\.bundleIdentifier).first(where: { !$0.isEmpty }) {
            return bundle.split(separator: ".").last.map(String.init) ?? bundle
        }
        return key.rawValue
    }

    /// Groups processes into apps, dropping system audio plumbing, and orders them the
    /// way the panel shows them: apps that are playing first, then alphabetically.
    public static func group(_ processes: [AudioProcessSnapshot]) -> [AudioApp] {
        var grouped: [AppKey: [AudioProcessSnapshot]] = [:]
        var order: [AppKey] = []

        for process in processes where isUserFacing(process) {
            let key = key(for: process)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(process)
        }

        let apps = order.map { key -> AudioApp in
            let members = grouped[key] ?? []
            return AudioApp(
                key: key,
                name: displayName(for: members, key: key),
                bundleIdentifier: members.compactMap(\.containerBundleIdentifier).first
                    ?? members.compactMap(\.bundleIdentifier).first.map(normalizedBundleIdentifier),
                bundlePath: members.compactMap(\.containerBundlePath).first,
                processes: members.sorted { $0.audioObjectID < $1.audioObjectID }
            )
        }

        return sorted(apps)
    }

    /// Playing apps first, then case-insensitive name, then key for a stable order.
    public static func sorted(_ apps: [AudioApp]) -> [AudioApp] {
        apps.sorted { left, right in
            if left.isPlaying != right.isPlaying {
                return left.isPlaying
            }
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return left.key.rawValue < right.key.rawValue
        }
    }
}
