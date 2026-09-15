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
