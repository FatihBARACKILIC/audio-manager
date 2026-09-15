import AppKit
import AudioDomain
import Darwin
import Foundation

/// Works out which app a process belongs to.
///
/// Core Audio reports the process that opened the stream, which for Chromium and
/// Electron apps is a short-lived helper buried inside the parent bundle. Walking from
/// the executable path up to the *outermost* `.app` gives the identity the user
/// recognises, with public API only.
public enum ProcessIdentity {

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
        coreAudioBundleIdentifier: String?
    ) -> (bundlePath: String?, bundleIdentifier: String?, displayName: String?) {
        // A regular foreground app answers directly and gives us its localized name.
        if let running = NSRunningApplication(processIdentifier: processID) {
            return (
                running.bundleURL?.path,
                running.bundleIdentifier ?? coreAudioBundleIdentifier,
                running.localizedName
            )
        }

        // Helpers are not "running applications", so resolve them through their path.
        if
            let executable = executablePath(forProcessID: processID),
            let bundlePath = outermostAppBundlePath(forExecutablePath: executable)
        {
            let bundle = Bundle(path: bundlePath)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (bundlePath, bundle?.bundleIdentifier ?? coreAudioBundleIdentifier, name)
        }

        return (nil, coreAudioBundleIdentifier, nil)
    }
}
