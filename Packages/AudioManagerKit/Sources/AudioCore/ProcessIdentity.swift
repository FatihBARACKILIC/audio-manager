import AppKit
import AudioDomain
import Darwin
import Foundation

/// Snapshot of the running applications, built once per refresh.
///
/// Looking an app up per process would rescan the workspace list for every audio
/// process; building two dictionaries once keeps a refresh at a few microseconds even
/// with dozens of apps open.
public struct RunningAppIndex: Sendable {
    private let byProcessID: [pid_t: AppInfo]
    private let byBundleIdentifier: [String: AppInfo]

    struct AppInfo: Sendable {
        var bundleIdentifier: String?
        var bundlePath: String?
        var name: String?
        var isRegular: Bool
    }

    /// `NSRunningApplication` and `NSWorkspace.runningApplications` are documented as
    /// thread safe, so this is built on the observer's own queue rather than hopping to
    /// the main thread for every refresh.
    public init() {
        var byProcessID: [pid_t: AppInfo] = [:]
        var byBundleIdentifier: [String: AppInfo] = [:]

        for application in NSWorkspace.shared.runningApplications {
            let info = AppInfo(
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: application.bundleURL?.path,
                name: application.localizedName,
                isRegular: application.activationPolicy == .regular
            )
            byProcessID[application.processIdentifier] = info
            if let identifier = application.bundleIdentifier {
                byBundleIdentifier[identifier] = info
            }
        }

        self.byProcessID = byProcessID
        self.byBundleIdentifier = byBundleIdentifier
    }

    /// Empty index, for call sites that have no workspace access.
    public init(empty: Bool) {
        byProcessID = [:]
        byBundleIdentifier = [:]
    }

    func info(forProcessID pid: pid_t) -> AppInfo? {
        byProcessID[pid]
    }

    func info(forBundleIdentifier identifier: String?) -> AppInfo? {
        guard let identifier else { return nil }
        return byBundleIdentifier[identifier]
    }
}

/// Works out which app a process belongs to.
///
/// Core Audio reports the process that opened the stream, which for Chromium and
/// Electron apps is a short-lived helper buried inside the parent bundle. Walking from
/// the executable path up to the *outermost* `.app` gives the identity the user
/// recognises, with public API only.
public enum ProcessIdentity {

    public struct Description: Sendable {
        public var bundlePath: String?
        public var bundleIdentifier: String?
        public var displayName: String?
        public var isRegularApp: Bool
    }

    /// The outermost `.app` bundle containing an executable path.
    ///
    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper (Renderer).app/Contents/MacOS/…`
    /// resolves to `/Applications/Google Chrome.app`, not to the helper bundle, which
    /// is what collapses a browser's many processes into a single row.
    public static func outermostAppBundlePath(forExecutablePath path: String) -> String? {
        guard !path.isEmpty else { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.count > 4 && $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }

    /// Executable path for a pid, or `nil` when the system will not tell us.
    ///
    /// Sandboxed apps can be refused here; every caller has a fallback, so a `nil` only
    /// costs us a nicer display name.
    public static func executablePath(forProcessID pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// Everything we can find out about one audio process.
    public static func describe(
        processID: pid_t,
        coreAudioBundleIdentifier: String?,
        index: RunningAppIndex
    ) -> Description {
        // A regular foreground app answers directly and gives us its localized name.
        if let info = index.info(forProcessID: processID) {
            return Description(
                bundlePath: info.bundlePath,
                bundleIdentifier: info.bundleIdentifier ?? coreAudioBundleIdentifier,
                displayName: info.name,
                isRegularApp: info.isRegular
            )
        }

        // Helpers are not "running applications", so resolve them through their path and
        // then look the parent app up by its identifier.
        if
            let executable = executablePath(forProcessID: processID),
            let bundlePath = outermostAppBundlePath(forExecutablePath: executable)
        {
            let bundle = Bundle(path: bundlePath)
            let identifier = bundle?.bundleIdentifier ?? coreAudioBundleIdentifier
            let parent = index.info(forBundleIdentifier: identifier)
            let name = parent?.name
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

            return Description(
                bundlePath: bundlePath,
                bundleIdentifier: identifier,
                displayName: name,
                isRegularApp: parent?.isRegular ?? false
            )
        }

        // A plain command line tool: no bundle at all, so name it after its executable
        // rather than showing a raw process id.
        let executableName = executablePath(forProcessID: processID)
            .map { ($0 as NSString).lastPathComponent }

        return Description(
            bundlePath: nil,
            bundleIdentifier: coreAudioBundleIdentifier,
            displayName: executableName,
            isRegularApp: false
        )
    }
}
