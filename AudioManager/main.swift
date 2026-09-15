import AppKit

// A pure AppKit entry point rather than a SwiftUI `App`: the menu bar item, the panel
// popover and the settings window are managed directly so a global shortcut can open
// them, which `MenuBarExtra` does not allow. Every view inside them is SwiftUI.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Accessory: no Dock icon, no menu bar menus — the app lives in the status bar.
application.setActivationPolicy(.accessory)
application.run()
