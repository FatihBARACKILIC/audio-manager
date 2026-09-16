import AppKit

/// Removes Audio Manager from the machine, as far as a sandboxed app is allowed to.
///
/// The app can delete everything it created — its settings, its login item, its taps —
/// but it cannot delete **itself**. The sandbox refuses to move the app's own bundle to
/// the Trash: both `FileManager.trashItem` and `NSWorkspace.recycle` fail with a
/// permissions error, measured on macOS 15 with this app's entitlements. Turning the
/// sandbox off would allow it and is not worth giving up the App Store for, so the last
/// step is handed to the user with the bundle already selected in Finder.
@MainActor
enum Uninstaller {

    /// Shows the app's own bundle in Finder, selected and ready to be dragged out.
    static func revealAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    /// Where the app is installed, for the confirmation text.
    static var installedPath: String {
        Bundle.main.bundleURL.path
    }

    /// True when the app was installed by Homebrew, which has its own uninstall command
    /// and would be left with a dangling record if the bundle were dragged out by hand.
    static var looksLikeHomebrewInstall: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.contains("/Caskroom/") || path.contains("/homebrew/")
    }
}
