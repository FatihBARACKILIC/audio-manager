import AppKit
import AudioDomain
import AudioPersistence
import Observation
import SwiftUI

/// Owns the menu bar item, the panel popover and the settings window.
///
/// The app is built around AppKit at this one level on purpose: a global shortcut has
/// to be able to open the panel, and SwiftUI's `MenuBarExtra` offers no way to do that.
/// Everything inside the popover and the settings window is still SwiftUI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.makeDefault()
    private let hotkeys = GlobalHotkeyCenter()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        Task {
            await model.start()

            if CommandLine.arguments.contains("--reset-settings") {
                await model.resetAllSettings()
                print("settings reset")
                await model.stop()
                NSApp.terminate(nil)
                return
            }

            if Diagnostics.isRequested {
                if CommandLine.arguments.contains("--simulate-control") {
                    model.simulateFullControlForDiagnostics()
                }
                if CommandLine.arguments.contains("--simulate-mute") {
                    model.simulateMuteForDiagnostics()
                }
                if let seconds = Diagnostics.watchSeconds {
                    // Metering only runs while the panel is visible, so pretend it is —
                    // but only where there is something to meter. Muted apps report
                    // silence by definition, and leaving the meters on would make a
                    // mute-only measurement look busier than the app really is.
                    model.isPanelVisible = CommandLine.arguments.contains("--simulate-control")
                    try? await Task.sleep(for: .seconds(seconds))
                }
                Diagnostics.dump(model)
                await model.stop()
                NSApp.terminate(nil)
                return
            }

            registerShortcuts()
            LoginItem.synchronize(enabled: model.preferences.launchAtLogin)
        }

        observeMenuBarIcon()

        // Opens the panel straight away, so the UI can be exercised from a script or a
        // test run without clicking the menu bar.
        if CommandLine.arguments.contains("--show-panel") {
            showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        // Taps must be released before we exit, or the muted app stays muted.
        let model = model
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await model.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "speaker.wave.2.circle",
            accessibilityDescription: String(localized: "Audio Manager")
        )
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }

        let popover = popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        return popover
    }

    /// Keeps the menu bar symbol in step with what the app is actually doing.
    ///
    /// `withObservationTracking` fires once per change and is re-armed afterwards, so
    /// there is no polling and no work at all while nothing changes.
    private func observeMenuBarIcon() {
        withObservationTracking {
            updateMenuBarIcon()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeMenuBarIcon()
            }
        }
    }

    private func updateMenuBarIcon() {
        let symbol: String
        if model.focus.isActive {
            symbol = "moon.circle.fill"
        } else if model.isControllingAnything {
            symbol = "speaker.wave.2.circle.fill"
        } else {
            symbol = "speaker.wave.2.circle"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: String(localized: "Audio Manager")
        )
    }

    // MARK: - Settings window

    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Audio Manager Settings")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Shortcuts

    func registerShortcuts() {
        hotkeys.unregisterAll()

        hotkeys.register(KeyboardShortcut.parse(model.preferences.panelShortcut)) { [weak self] in
            self?.togglePanel()
        }

        hotkeys.register(KeyboardShortcut.parse(model.preferences.focusShortcut)) { [weak self] in
            self?.model.toggleFocusMode()
        }
    }
}

/// Bridges SwiftUI views to the delegate for the few things that need AppKit.
@MainActor
enum AppCommands {
    static var delegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    static func openSettings() {
        delegate?.showSettings()
    }

    static func closePanel() {
        delegate?.togglePanel()
    }

    static func shortcutsChanged() {
        delegate?.registerShortcuts()
    }
}
