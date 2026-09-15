import AudioDomain
import Foundation

/// Prints what the app currently sees and would do, then exits.
///
/// Run with `--dump-state`. Useful when something looks wrong on a user's machine:
/// it shows the grouped app list and the effective decision per app without needing
/// the UI, and it reads state only — it never changes anything.
@MainActor
enum Diagnostics {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--dump-state")
    }

    static func dump(_ model: AppModel) {
        setvbuf(stdout, nil, _IONBF, 0)

        print("permission: \(model.permission.rawValue)")
        print("focus: \(model.focus.isActive ? "on" : "off"), profile: \(model.activeProfile?.name ?? "none")")
        print("apps: \(model.apps.count)")

        for app in model.apps {
            let state = model.state(for: app.key)
            let settings = model.settings(for: app.key)
            let flags = [
                app.isPlaying ? "playing" : nil,
                state.isMuted ? "muted" : nil,
                state.needsRendering ? "rendering" : nil,
                state.isPassthrough ? "untouched" : nil,
            ].compactMap { $0 }.joined(separator: ",")

            print("""
                  - \(app.name)
                      key: \(app.key.rawValue)
                      processes: \(app.processes.count) \(app.audioObjectIDs)
                      mode: \(settings.mode.rawValue) volume: \(String(format: "%.2f", settings.volume)) gain: \(String(format: "%.3f", state.gain))
                      flags: \(flags)
                  """)
        }
    }
}
