import Foundation
import Testing

@testable import AudioCore

@Suite("Process identity")
struct ProcessIdentityTests {

    @Test("A Chrome renderer helper resolves to Chrome itself")
    func chromeHelperResolvesToParent() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/120.0.1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

        #expect(
            ProcessIdentity.outermostAppBundlePath(forExecutablePath: path)
                == "/Applications/Google Chrome.app"
        )
    }

    @Test("An Electron helper resolves to its host app")
    func electronHelperResolvesToParent() {
        let path = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer)"

        #expect(
            ProcessIdentity.outermostAppBundlePath(forExecutablePath: path)
                == "/Applications/Visual Studio Code.app"
        )
    }

    @Test("A plain app resolves to itself")
    func plainApp() {
        let path = "/Applications/Music.app/Contents/MacOS/Music"

        #expect(ProcessIdentity.outermostAppBundlePath(forExecutablePath: path) == "/Applications/Music.app")
    }

    @Test("An app in a user folder keeps its full path")
    func nestedUserPath() {
        let path = "/Users/someone/Applications/My Player.app/Contents/MacOS/My Player"

        #expect(
            ProcessIdentity.outermostAppBundlePath(forExecutablePath: path)
                == "/Users/someone/Applications/My Player.app"
        )
    }

    @Test("A command line tool has no app bundle")
    func commandLineTool() {
        #expect(ProcessIdentity.outermostAppBundlePath(forExecutablePath: "/usr/bin/afplay") == nil)
        #expect(ProcessIdentity.outermostAppBundlePath(forExecutablePath: "") == nil)
        #expect(ProcessIdentity.outermostAppBundlePath(forExecutablePath: "/") == nil)
    }

    @Test("A directory merely containing .app in its name is not treated as a bundle")
    func similarlyNamedDirectory() {
        let path = "/Users/someone/myapps/tool/bin/tool"

        #expect(ProcessIdentity.outermostAppBundlePath(forExecutablePath: path) == nil)
    }

    @Test("This test process resolves its own executable path")
    func ownExecutablePath() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = ProcessIdentity.executablePath(forProcessID: pid)

        #expect(path != nil)
        #expect(path?.isEmpty == false)
    }
}

/// The cache in front of `Bundle(path:)`, built because reading an app's `Info.plist`
/// is disk work that used to repeat for every helper process on every refresh.
@Suite("Bundle description cache", .serialized)
struct BundleDescriptionCacheTests {

    /// Writes the smallest thing `Bundle(path:)` will accept as an app.
    private func makeBundle(at directory: URL, name: String) throws -> String {
        let bundle = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(name)",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle.path
    }

    @Test("A bundle reports the name it declares, and keeps reporting it")
    func readsAndRepeatsABundlesName() throws {
        ProcessIdentity.forgetCachedBundles()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = try makeBundle(at: directory, name: "Parent")
        #expect(ProcessIdentity.displayNameForCachedBundle(atPath: path) == "Parent")
        #expect(ProcessIdentity.displayNameForCachedBundle(atPath: path) == "Parent")
    }

    @Test("Something that is not a bundle answers nothing rather than guessing")
    func unknownPathsAreNil() {
        ProcessIdentity.forgetCachedBundles()
        let path = URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app").path
        #expect(ProcessIdentity.displayNameForCachedBundle(atPath: path) == nil)
    }

    @Test("Passing the cache's limit keeps every answer correct")
    func evictionDoesNotCorruptAnswers() throws {
        ProcessIdentity.forgetCachedBundles()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Comfortably past the cache limit, so the wholesale drop happens at least once.
        let paths = try (0..<80).map { try makeBundle(at: directory, name: "App\($0)") }

        for (index, path) in paths.enumerated() {
            #expect(ProcessIdentity.displayNameForCachedBundle(atPath: path) == "App\(index)")
        }
        // And again, now that some of them have been evicted and must be re-read.
        for (index, path) in paths.enumerated() {
            #expect(ProcessIdentity.displayNameForCachedBundle(atPath: path) == "App\(index)")
        }
    }
}
